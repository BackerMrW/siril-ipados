// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func previewRegionSelfTest(file: FITSRecord, values: [Float], width: Int, height: Int) async throws -> [ProcessingJob] {
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw EngineError.failed("Preview ROI: " + message) } }
        let original = try Data(contentsOf: file.url)
        let area = ImageSelection(x: 13, y: 17, width: 37, height: 29)
        let session = NativeToolSession(); try await session.open(file)
        var jobs: [ProcessingJob] = []
        func transform(_ value: Double) -> Double { (-0.75 * value) / (-0.5 * value - 0.25) }
        func weight(_ value: Float, depth: Int) -> Double {
            if depth < 0 { return 1 }
            let scale = depth == 0 ? 255.0 : depth == 1 ? 65535.0 : 0
            return scale == 0 ? Double(value) : Double((value * Float(scale)).rounded()) / scale
        }
        func expected(_ c: Int, _ x: Int, _ y: Int, depth: Int) -> Double {
            let index = y * width + x, value = Double(values[c * width * height + index])
            let w = weight(values[index], depth: depth)
            return value * (1 - w) + transform(value) * w
        }
        func verify(_ url: URL, expectedPixel: (Int, Int, Int) -> Double, label: String) throws {
            let data = try Data(contentsOf: url)
            var end = 0
            while end + 80 <= data.count && String(data: data[end..<(end + 8)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) != "END" { end += 80 }
            let start = ((end + 80 + 2879) / 2880) * 2880
            try require(start + width * height * 3 * 4 <= data.count, "full result truncated")
            for c in 0..<3 { for row in 0..<height { for x in 0..<width {
                let offset = start + (c * width * height + row * width + x) * 4
                let actual = Float(bitPattern: data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                try require(abs(Double(actual) - expectedPixel(c, x, height - 1 - row)) < 3e-6, "full apply/replay pixels outside and inside ROI: " + label)
            } } }
        }
        for depth in -1...2 {
            var recipe = NativeToolRecipe(tool: .mtf, file: file)
            recipe.values["mid"] = 0.25; recipe.previewRegion = area
            if depth >= 0 { recipe.mask.values["mode"] = 2; recipe.mask.values["channel"] = 0; recipe.mask.values["depth"] = Double(depth) }
            try await session.compute(recipe, library: [file])
            let info = try await session.info(view: 1)
            try require(Int(info.width) == area.width && Int(info.height) == area.height && info.channels == 3, "preview dimensions")
            for y in 0..<area.height { for x in 0..<area.width {
                let pixel = try await session.pixel(view: 1, x: x, y: y)
                for c in 0..<3 { try require(abs(Double(pixel[c]) - expected(c, area.x + x, area.y + y, depth: depth)) < 3e-6, "selected RGB/quantized mask pixels, depth \(depth), (\(x),\(y)), channel \(c)") }
            } }
            if depth >= 0 {
                let mask = try await session.info(view: 2)
                try require(Int(mask.width) == area.width && Int(mask.height) == area.height, "preview mask dimensions")
            }
            let job = try prepareNativeToolJob(file: file, recipe: recipe, library: [file]); jobs.append(job)
            try require(!job.script.contains("preview-region") && !job.script.contains("crop "), "saved task applied only the preview region")
            let output = try await session.export(recipe, to: job)
            let complete = try await session.info(view: 1)
            try require(Int(complete.width) == width && Int(complete.height) == height, "apply retained cropped dimensions")
            try verify(output, expectedPixel: { expected($0, $1, $2, depth: depth) }, label: "MTF depth \(depth)")
            let replay = try run(job)
            guard let result = replay.first(where: { $0.lastPathComponent == "result.fits" }) else { throw EngineError.failed("ROI replay output missing") }
            try verify(result, expectedPixel: { expected($0, $1, $2, depth: depth) }, label: "MTF replay depth \(depth)")
            if depth >= 0 {
                let mask = try await session.info(view: 2)
                try require(Int(mask.width) == width && Int(mask.height) == height && FileManager.default.fileExists(atPath: output.appendingPathExtension("mask.fits").path), "apply retained a cropped or missing mask")
            }
            try require(try JSONDecoder().decode(NativeToolRecipe.self, from: Data(contentsOf: job.folder.appendingPathComponent("native-tool.json"))) == recipe, "ROI parameter snapshot")
        }
        // A retained red-channel stage precedes the current inverse RGB curve.
        // The range mask must be evaluated on that stage's selected pixels.
        for ranged in [false, true] {
            var curve = NativeToolRecipe(tool: .curves, file: file)
            curve.previewRegion = area
            var stage = CurveStage(); stage.algorithm = 1
            stage.channels[1].points = [CurveKnot(x: 0, y: 0), CurveKnot(x: 1, y: 0.8)]
            curve.curveSettings.stages = [stage]
            curve.curveSettings.current.algorithm = 1
            curve.curveSettings.current.channels[0].points = [CurveKnot(x: 0, y: 1), CurveKnot(x: 1, y: 0)]
            curve.curveSettings.current.channels[0].rangeEnabled = ranged
            curve.curveSettings.current.channels[0].low = 0.2
            curve.curveSettings.current.channels[0].high = 0.8
            curve.curveSettings.current.channels[0].feather = 0.1
            func staged(_ c: Int, _ x: Int, _ y: Int) -> Double {
                Double(values[c * width * height + y * width + x]) * (c == 0 ? 0.8 : 1)
            }
            func rangeWeight(_ x: Int, _ y: Int) -> Double {
                let lum = (staged(0, x, y) + staged(1, x, y) + staged(2, x, y)) / 3
                return min(1 / (1 + exp(-2.5 * (lum - 0.2) / 0.1)), 1 / (1 + exp(-2.5 * (0.8 - lum) / 0.1)))
            }
            func curvePixel(_ c: Int, _ x: Int, _ y: Int) -> Double {
                let value = staged(c, x, y), weight = ranged ? rangeWeight(x, y) : 1
                return value * (1 - weight) + (1 - value) * weight
            }
            try await session.compute(curve, library: [file])
            let info = try await session.info(view: 1)
            try require(Int(info.width) == area.width && Int(info.height) == area.height, "curve ROI dimensions")
            if ranged {
                let mask = try await session.info(view: 2)
                try require(Int(mask.width) == area.width && Int(mask.height) == area.height, "curve range display did not crop to ROI")
            }
            for y in 0..<area.height { for x in 0..<area.width {
                let pixel = try await session.pixel(view: 1, x: x, y: y)
                for c in 0..<3 { try require(abs(Double(pixel[c]) - curvePixel(c, area.x + x, area.y + y)) < 3e-6, "curve ROI staged/ranged pixels") }
                if ranged {
                    let mask = try await session.pixel(view: 2, x: x, y: y)
                    try require(mask.allSatisfy { abs(Double($0) - rangeWeight(area.x + x, area.y + y)) < 3e-6 }, "curve ROI range display ignored retained stage or source coordinates")
                }
            } }
            let job = try prepareNativeToolJob(file: file, recipe: curve, library: [file]); jobs.append(job)
            try require(!job.script.contains("preview-region"), "curve task retained preview-only crop")
            let output = try await session.export(curve, to: job)
            try verify(output, expectedPixel: curvePixel, label: "staged curve ranged=\(ranged)")
            try require(!FileManager.default.fileExists(atPath: output.appendingPathExtension("mask.fits").path), "curve range display leaked into attached mask")
            let replay = try run(job)
            guard let result = replay.first(where: { $0.lastPathComponent == "result.fits" }) else { throw EngineError.failed("Curve ROI replay missing") }
            try verify(result, expectedPixel: curvePixel, label: "staged curve replay ranged=\(ranged)")
            let history = NativeToolHistory(sourceID: file.id, width: width, height: height, current: curve)
            try saveNativeToolHistory(history, file: file)
            try require(try nativeToolHistory(file, tool: .curves).current == curve, "curve ROI history reopen")
        }
        // Real camera files use signed FITS storage plus BZERO for uint16.
        // Keep an odd CFA selection to catch geometry crop's Bayer rounding.
        let cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2", "NAXIS1  = \(width)", "NAXIS2  = \(height)", "BZERO   =                32768", "BSCALE  =                    1", "BAYERPAT= 'RGGB'", "END"]
        var raw = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
        func code(_ x: Int, _ y: Int) -> Int { 1000 + (113 * x + 71 * y) % 50000 }
        for row in 0..<height { for x in 0..<width {
            var encoded = UInt16(bitPattern: Int16(code(x, height - 1 - row) - 32768)).bigEndian
            withUnsafeBytes(of: &encoded) { raw.append(contentsOf: $0) }
        } }
        raw.append(contentsOf: repeatElement(UInt8(0), count: (2880 - raw.count % 2880) % 2880))
        let rawURL = documents.appendingPathComponent(UUID().uuidString + "-roi-raw16.fits")
        try raw.write(to: rawURL)
        let cfa = try importFile(rawURL)
        defer { try? FileManager.default.removeItem(at: rawURL); try? FileManager.default.removeItem(at: cfa.url) }
        let rawSession = NativeToolSession(); try await rawSession.open(cfa)
        var rawRecipe = NativeToolRecipe(tool: .mtf, file: cfa); rawRecipe.previewRegion = area; rawRecipe.values["mid"] = 0.25
        try await rawSession.compute(rawRecipe, library: [cfa])
        let rawInfo = try await rawSession.info(view: 1)
        try require(Int(rawInfo.width) == area.width && Int(rawInfo.height) == area.height && rawInfo.channels == 1, "odd CFA preview rounded the selection or changed channels")
        for y in 0..<area.height { for x in 0..<area.width {
            let pixel = try await rawSession.pixel(view: 1, x: x, y: y)[0]
            try require(abs(Double(pixel) - transform(Double(code(area.x + x, area.y + y)) / 65535)) < 3e-6, "uint16 CFA selected original pixels")
        } }
        let rawJob = try prepareNativeToolJob(file: cfa, recipe: rawRecipe, library: [cfa]); jobs.append(rawJob)
        let rawOutput = try await rawSession.export(rawRecipe, to: rawJob)
        func verifyRaw(_ url: URL) throws {
            let data = try Data(contentsOf: url)
            var end = 0
            while end + 80 <= data.count && String(data: data[end..<(end + 8)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) != "END" { end += 80 }
            let start = ((end + 80 + 2879) / 2880) * 2880
            try require(start + width * height * 4 <= data.count && String(data: data.prefix(start), encoding: .ascii)?.contains("RGGB") == true, "full CFA output lost size or sensor pattern")
            for row in 0..<height { for x in 0..<width {
                let offset = start + (row * width + x) * 4
                let pixel = Float(bitPattern: data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                try require(abs(Double(pixel) - transform(Double(code(x, height - 1 - row)) / 65535)) < 3e-6, "uint16 full CFA apply/replay conversion")
            } }
        }
        try verifyRaw(rawOutput)
        let rawReplay = try run(rawJob)
        guard let replay = rawReplay.first(where: { $0.lastPathComponent == "result.fits" }) else { throw EngineError.failed("RAW ROI replay missing") }
        try verifyRaw(replay)
        try require(try Data(contentsOf: cfa.url) == raw, "changed original integer/CFA source")
        var rawCurve = NativeToolRecipe(tool: .curves, file: cfa); rawCurve.previewRegion = area
        var rawStage = CurveStage(); rawStage.algorithm = 1
        rawStage.channels[0].points = [CurveKnot(x: 0, y: 0), CurveKnot(x: 1, y: 0.8)]
        rawCurve.curveSettings.stages = [rawStage]
        rawCurve.curveSettings.current.algorithm = 1
        rawCurve.curveSettings.current.channels[0].points = [CurveKnot(x: 0, y: 1), CurveKnot(x: 1, y: 0)]
        rawCurve.curveSettings.current.channels[0].rangeEnabled = true
        rawCurve.curveSettings.current.channels[0].low = 0.2
        rawCurve.curveSettings.current.channels[0].high = 0.8
        rawCurve.curveSettings.current.channels[0].feather = 0.1
        try await rawSession.compute(rawCurve, library: [cfa])
        let rawHistograms = try await rawSession.curveHistograms(view: 0)
        var expectedHistogram = [UInt64](repeating: 0, count: 256)
        for y in 0..<height { for x in 0..<width { expectedHistogram[min(255, Int(Float(code(x, y)) / 65535 * 256))] += 1 } }
        try require(rawHistograms.count == 7 && [0, 1, 2, 3].allSatisfy { rawHistograms[$0] == expectedHistogram }, "integer CFA curve RGB/gray histogram bins")
        let rawTone = try await rawSession.curvePipette(rawCurve.curveSettings, x: area.x, y: area.y)
        try require(abs(rawTone - Double(code(area.x, area.y)) / 65535 * 0.8) < 3e-6, "integer CFA staged pipette normalization/source coordinates")
        let rawRangeInfo = try await rawSession.info(view: 2)
        try require(Int(rawRangeInfo.width) == area.width && Int(rawRangeInfo.height) == area.height, "integer CFA curve range dimensions")
        for y in 0..<area.height { for x in 0..<area.width {
            let value = Double(code(area.x + x, area.y + y)) / 65535 * 0.8
            let weight = min(1 / (1 + exp(-2.5 * (value - 0.2) / 0.1)), 1 / (1 + exp(-2.5 * (0.8 - value) / 0.1)))
            let mask = try await rawSession.pixel(view: 2, x: x, y: y)[0]
            let pixel = try await rawSession.pixel(view: 1, x: x, y: y)[0]
            try require(abs(Double(mask) - weight) < 3e-6 && abs(Double(pixel) - (value * (1 - weight) + (1 - value) * weight)) < 3e-6, "integer CFA curve range or result was not normalized/cropped")
        } }
        var recipe = NativeToolRecipe(tool: .mtf, file: file); recipe.previewRegion = area
        var history = NativeToolHistory(sourceID: file.id, width: width, height: height, current: recipe)
        try saveNativeToolHistory(history, file: file)
        try require(try nativeToolHistory(file, tool: .mtf).current == recipe, "ROI history reopen")
        var cleared = recipe; cleared.previewRegion = nil
        history.record(cleared); history.step(redo: false); try require(history.current == recipe, "ROI undo")
        history.step(redo: true); try require(history.current == cleared, "ROI redo")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as! [String: Any]
        legacy.removeValue(forKey: "previewRegion")
        try require(try JSONDecoder().decode(NativeToolRecipe.self, from: JSONSerialization.data(withJSONObject: legacy)).previewRegion == nil, "legacy recipe without ROI")
        for invalid in [ImageSelection(x: -1, y: 0, width: 10, height: 10), ImageSelection(x: 0, y: 0, width: 0, height: 10), ImageSelection(x: width - 1, y: 0, width: 2, height: 10)] {
            var rejected = false; recipe.previewRegion = invalid
            do { try await session.compute(recipe, library: [file]) } catch { rejected = true }
            try require(rejected, "accepted out-of-bounds ROI")
        }
        var unsupported = NativeToolRecipe(tool: .rotate, file: file); unsupported.previewRegion = area
        var rejected = false
        do { try await session.compute(unsupported, library: [file]) } catch { rejected = true }
        try require(rejected, "unsupported geometry tool accepted preview ROI")
        try require(try Data(contentsOf: file.url) == original, "ROI preview or full apply changed source bytes")
        return jobs
    }
}
