// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func guidedPreviewSelfTest() async throws -> [ProcessingJob] {
        func require(_ ok: Bool, _ detail: String) throws { if !ok { throw EngineError.failed("Guided ROI: " + detail) } }
        let width = 41, height = 35, area = ImageSelection(x: 7, y: 9, width: 23, height: 19)
        var fixtures: [FITSRecord] = [], jobs: [ProcessingJob] = []
        defer { for file in fixtures { try? FileManager.default.removeItem(at: file.url) } }
        func target(_ x: Int, _ y: Int) -> Double { Double(1000 + (x * 113 + y * 71 + x * y * 17) % 40000) / 65536 }
        func guide(_ x: Int, _ y: Int, mode: Int) -> Double {
            mode == 0 ? 0.25 : Double(1 + ((x / 3 + y / 4) % 2)) * (mode == 1 ? 0.25 : 1)
        }
        func fixture(w: Int, h: Int, integer: Bool = false, value: (Int, Int) -> Double) throws -> FITSRecord {
            var cards = ["SIMPLE  =                    T", "BITPIX  = \(integer ? 16 : -32)", "NAXIS   =                    2", "NAXIS1  = \(w)", "NAXIS2  = \(h)"]
            if integer { cards += ["BZERO   =                32768", "BSCALE  =                    1", "BAYERPAT= 'RGGB'"] }
            cards.append("END")
            var data = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for row in 0..<h { for x in 0..<w {
                if integer {
                    var encoded = UInt16(bitPattern: Int16(Int(value(x, h - 1 - row)) - 32768)).bigEndian
                    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
                } else {
                    var encoded = Float(value(x, h - 1 - row)).bitPattern.bigEndian
                    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
                }
            } }
            data.append(contentsOf: repeatElement(UInt8(0), count: (2880 - data.count % 2880) % 2880))
            let url = documents.appendingPathComponent(UUID().uuidString + "-guided-roi.fits")
            try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
            let file = try importFile(url); fixtures.append(file); return file
        }
        func box(_ data: [Double], w: Int, h: Int) -> [Double] {
            (0..<(w * h)).map { index in
                var sum = 0.0
                for dy in -1...1 { for dx in -1...1 { sum += data[min(h - 1, max(0, index / w + dy)) * w + min(w - 1, max(0, index % w + dx))] } }
                return sum / 9
            }
        }
        // Original mono epsilon: (si / 100 / 25 / 10 / 5 * 2)^2.
        // Two replicated-border box means define the constant-guide case.
        func expected(w: Int, h: Int, ox: Int, oy: Int, mode: Int) -> [Double] {
            let p = (0..<(w * h)).map { target(ox + $0 % w, oy + $0 / w) }
            let i = (0..<(w * h)).map { guide(ox + $0 % w, oy + $0 / w, mode: mode) }
            let mp = box(p, w: w, h: h), mi = box(i, w: w, h: h)
            let mii = box(i.map { $0 * $0 }, w: w, h: h)
            let mip = box(zip(i, p).map { $0.0 * $0.1 }, w: w, h: h)
            let sigma: Double = 11.0 / 100.0 / 25.0 / 10.0 / 5.0 * 2.0
            let eps = sigma * sigma
            var a = [Double](repeating: 0, count: p.count), b = a
            for index in p.indices {
                let covariance = mip[index] - mi[index] * mp[index]
                let variance = mii[index] - mi[index] * mi[index]
                a[index] = covariance / (variance + eps)
                b[index] = mp[index] - a[index] * mi[index]
            }
            let ma = box(a, w: w, h: h), mb = box(b, w: w, h: h)
            return p.indices.map { index -> Double in
                let filtered = ma[index] * i[index] + mb[index]
                return filtered * 0.7 + p[index] * 0.3
            }
        }
        let file = try fixture(w: width, h: height, value: target)
        let sourceBytes = try Data(contentsOf: file.url)
        let session = NativeToolSession(); try await session.open(file)
        let analysis = ImageAnalysisEngine()
        for mode in 0...2 {
            let reference = try fixture(w: width, h: height, integer: mode == 2, value: { guide($0, $1, mode: mode) })
            let referenceBytes = try Data(contentsOf: reference.url)
            var recipe = NativeToolRecipe(tool: .guided, file: file)
            recipe.guideID = reference.id; recipe.previewRegion = area
            recipe.values["diameter"] = 3; recipe.values["amount"] = 0.7
            try await session.compute(recipe, library: [file, reference])
            let info = try await session.info(view: 1)
            try require(Int(info.width) == area.width && Int(info.height) == area.height, "external guide ROI dimensions")
            let selected = expected(w: area.width, h: area.height, ox: area.x, oy: area.y, mode: mode)
            for y in 0..<area.height { for x in 0..<area.width {
                let pixel = try await session.pixel(view: 1, x: x, y: y)[0]
                try require(abs(Double(pixel) - selected[y * area.width + x]) < 2e-5, "independent mono guide coordinates, bit depth, replicated border and modulation, mode \(mode), (\(x),\(y))")
            } }
            // A self guide must also work on the cropped science raster.
            if mode == 0 {
                var selfGuided = recipe; selfGuided.guideID = nil; selfGuided.values["amount"] = 0
                try await session.compute(selfGuided, library: [file])
                for y in 0..<area.height { for x in 0..<area.width {
                    let pixel = try await session.pixel(view: 1, x: x, y: y)[0]
                    try require(abs(Double(pixel) - target(area.x + x, area.y + y)) < 2e-6, "self-guided ROI zero modulation")
                } }
                try await session.compute(recipe, library: [file, reference])
            }
            let job = try prepareNativeToolJob(file: file, recipe: recipe, library: [file, reference]); jobs.append(job)
            try require(!job.script.contains("preview-region") && !job.script.contains("preview-guide"), "preview guide leaked into full task")
            let output = try await session.export(recipe, to: job)
            let full = expected(w: width, h: height, ox: 0, oy: 0, mode: mode)
            func verify(_ url: URL) async throws {
                let info = try await analysis.open(url)
                try require(Int(info.width) == width && Int(info.height) == height, "full apply/replay dimensions")
                for y in 0..<height { for x in 0..<width {
                    let pixel = try await analysis.pixel(x: x, y: y).values[0]
                    try require(abs(Double(pixel) - full[y * width + x]) < 2e-5, "independent full guide/filter pixels, mode \(mode)")
                } }
            }
            try await verify(output)
            let replay = try run(job)
            guard let result = replay.first(where: { $0.lastPathComponent == "result.fits" }) else { throw EngineError.failed("Guided ROI replay missing") }
            try await verify(result)
            try require(try Data(contentsOf: reference.url) == referenceBytes, "guide source modified")
        }
        try require(try Data(contentsOf: file.url) == sourceBytes, "science source modified")
        return jobs
    }
}
