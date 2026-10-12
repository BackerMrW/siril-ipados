// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func nativeToolSelfTest() async throws {
        func require(_ ok: Bool, _ text: String) throws { if !ok { throw EngineError.failed("Native tools: " + text) } }
        let fm = FileManager.default
        let folder = documents.appendingPathComponent("native-tools-test-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let width = 96, height = 96
        let header = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    3", "NAXIS1  =                   96", "NAXIS2  =                   96", "NAXIS3  =                    3", "ROWORDER= 'TOP-DOWN'", "END"].map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0)
        var bytes = Data(header.utf8)
        var values: [Float] = []
        for c in 0..<3 { for y in 0..<height { for x in 0..<width {
            let bases = [0.12, 0.32, 0.22]
            let centresX = [45, 60, 30], centresY = [48, 32, 64]
            let dx = Double(x - centresX[c]), dy = Double(y - centresY[c])
            let pixel = Float(bases[c] + 0.0002 * Double(x) + 0.0001 * Double(y) + 0.2 * exp(-(dx * dx + dy * dy) / 8))
            values.append(pixel)
        } } }
        // Siril's original FITS reader uses bottom-up storage even when the
        // sensor ROWORDER metadata says TOP-DOWN. Encode known displayed pixels
        // independently in FITS order rather than treating that tag as a flip.
        for c in 0..<3 { for row in 0..<height { for column in 0..<width {
            var encoded = values[c * width * height + (height - 1 - row) * width + column].bitPattern.bigEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        } } }
        bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
        let fixture = folder.appendingPathComponent("tools-rgb.fits"); try bytes.write(to: fixture)
        let file = try importFile(fixture)
        defer { try? fm.removeItem(at: file.url); try? fm.removeItem(at: file.url.appendingPathExtension("tools.json")) }
        let sourceBytes = try Data(contentsOf: file.url)
        let session = NativeToolSession(); try await session.open(file)
        let x = 21, y = 25
        let expected = (0..<3).map { values[$0 * width * height + y * width + x] }
        let original = try await session.pixel(view: 0, x: x, y: y)
        try require(original == expected, "independent FITS fixture did not read exact displayed planes: \(original) != \(expected)")
        var records = [file]
        var jobs: [ProcessingJob] = []
        var checks: [String] = [], failures: [String] = []
        func checkpoint(_ line: String) {
            checks.append(line)
            try? checks.joined(separator: "\n").write(to: documents.appendingPathComponent("native-tool-tests.log"), atomically: true, encoding: .utf8)
        }
        guard let certificates = Bundle.main.url(forResource: "cacert", withExtension: "pem") else { throw EngineError.failed("TLS certificates missing") }
        try require(try Data(contentsOf: certificates).count > 100000, "TLS certificate bundle incomplete")
        var solve = NativeToolRecipe(tool: .plateSolve, file: file)
        solve.values["headerPosition"] = 0; solve.values["ra"] = 120; solve.values["dec"] = -20
        solve.values["headerOptics"] = 0; solve.values["catalog"] = 3
        solve.values["magnitudeMode"] = 1; solve.values["magnitude"] = -2
        solve.values["force"] = 1; solve.values["flip"] = 0; solve.values["distortion"] = 1
        let solveCommands = try solve.commands(file: file, topDown: true)
        try require(solveCommands.contains("platesolve 120,-20 -focal=500 -pixelsize=3.76 -catalog=gaia -limitmag=-2 -order=1 -noflip -force -disto=process/distortion.fits"), "plate solve degree coordinates or options")
        let restoredSolve = try JSONDecoder().decode(NativeToolRecipe.self, from: JSONEncoder().encode(solve))
        try require(restoredSolve == solve, "plate solve parameter history")
        var solveRejected = false
        solve.values["magnitudeMode"] = 2
        do { try solve.validate(file: file) } catch { solveRejected = true }
        try require(solveRejected, "negative absolute magnitude parsed as offset")
        solve = NativeToolRecipe(tool: .plateSolve, file: file)
        solveRejected = false
        do { try await session.compute(solve, library: records) } catch { solveRejected = true }
        try require(solveRejected, "missing target metadata must fail before downloading a catalog")
        try require(try Data(contentsOf: file.url) == sourceBytes, "failed plate solve changed input")
        checkpoint("PASS: plate solve degree coordinates, option encoding, persisted parameters, bundled TLS certificates and missing-metadata failure preserve original input")
        var pcc = NativeToolRecipe(tool: .pcc, file: file)
        pcc.values["catalog"] = 3
        let pccCommands = try pcc.commands(file: file, topDown: true)
        try require(pccCommands.contains("pcc -bgtol=2.8,2 -catalog=apass"), "PCC background tolerance or catalog encoding")
        var spcc = NativeToolRecipe(tool: .spcc, file: file)
        var spectral = SpectralSettings()
        spectral.oscSensor = SpectralModels.names("OSC_SENSOR").first ?? ""
        spcc.spectralSettings = spectral
        let spccCommands = try spcc.commands(file: file, topDown: true)
        try require(spccCommands.contains("\"-oscsensor=\(spectral.oscSensor)\"") && spccCommands.contains("\"-whiteref=Average Spiral Galaxy\""), "SPCC whole option quoting or white reference")
        let savedSpectral = try JSONDecoder().decode(NativeToolRecipe.self, from: JSONEncoder().encode(spcc))
        try require(savedSpectral == spcc, "SPCC spectral selection history")
        spectral.oscSensor = "unknown camera"; spcc.spectralSettings = spectral
        var spectralRejected = false
        do { try spcc.validate(file: file) } catch { spectralRejected = true }
        try require(spectralRejected, "unknown SPCC sensor accepted")
        var pccRejected = false
        do { try await session.compute(pcc, library: records) } catch { pccRejected = true }
        try require(pccRejected, "PCC without WCS accepted")
        checkpoint("PASS: PCC/SPCC settings, original spectral model list, whole-token quoting, persisted selections and missing-WCS rejection")
        guard let rawFixture = Bundle.main.url(forResource: "linear-cfa", withExtension: "dng") else { throw EngineError.failed("DNG fixture missing") }
        let rawRecord = try importFile(rawFixture)
        let rawImage = try read(rawRecord.url)
        var rawInfo = SirilImageInfo(); _ = siril_image_info(rawImage, &rawInfo)
        var rawPixel = [Float](repeating: 0, count: 3)
        let rawChannels = siril_image_pixel(rawImage, 21, 25, &rawPixel)
        siril_image_free(rawImage)
        try require(rawRecord.width == 256 && rawRecord.height == 256 && rawChannels == 1 && abs(rawPixel[0] - 1421 / 65535) < 1e-7, "DNG import pixel precision or orientation")
        try require(withUnsafePointer(to: rawInfo.bayer) { $0.withMemoryRebound(to: CChar.self, capacity: 80) { String(cString: $0) } } == "RGGB", "DNG CFA metadata lost during working FITS conversion")
        try fm.removeItem(at: rawRecord.url)
        checkpoint("PASS: native DNG import and working FITS round-trip retained exact normalized raw samples and Bayer metadata")
        // Every actual native tool must execute, return finite full-resolution
        // pixels and preserve the original. No fake success from command text.
        for tool in NativeTool.allCases.filter({ ![.fftInverse, .plateSolve, .pcc, .spcc].contains($0) }) {
            do {
                checkpoint("START: native tool \(tool.rawValue)")
                var recipe = NativeToolRecipe(tool: tool, file: file)
                if tool == .deconvolution { recipe.values["psfSource"] = 2; recipe.values["ks"] = 9; recipe.values["iterations"] = 2 }
                if tool == .crop { recipe.values["x"] = 16; recipe.values["y"] = 13; recipe.values["width"] = 64; recipe.values["height"] = 48 }
                if [.ghs, .inverseGHS, .modifiedAsinh, .inverseModifiedAsinh].contains(tool) { recipe.values["D"] = 0.8; recipe.values["SP"] = 0.1 }
                if tool == .linearStretch { recipe.values["BP"] = 0.05 }
                if tool == .asinh { recipe.values["stretch"] = 10 }
                if tool == .mtf || tool == .inverseMTF { recipe.values["mid"] = 0.25 }
                if tool == .greenNoise { recipe.values["preserve"] = 0 }
                if tool == .saturation { recipe.values["amount"] = 0.3 }
                if tool == .guided { recipe.values["diameter"] = 2 }
                if tool == .rotate { recipe.values["angle"] = 13 }
                if tool == .resample { recipe.values["mode"] = 4; recipe.values["width"] = 48; recipe.values["height"] = 32; recipe.values["interp"] = 0 }
                try await session.compute(recipe, library: records)
                let info = try await session.info(view: 1)
                let actual = try await session.pixel(view: 1, x: 10, y: 10)
                try require(info.width > 0 && info.height > 0 && info.channels == 3 && actual.allSatisfy(\.isFinite), "\(tool.rawValue) did not return finite RGB pixels")
                switch tool {
                case .negative:
                    let after = try await session.pixel(view: 1, x: x, y: y)
                    try require(zip(after, expected).allSatisfy { abs($0.0 - (1 - $0.1)) < 2e-6 }, "negative pixels")
                case .mtf:
                    let after = try await session.pixel(view: 1, x: x, y: y)
                    try require(zip(after, expected).allSatisfy { abs(Double($0.0) - (-0.75 * Double($0.1)) / (-0.5 * Double($0.1) - 0.25)) < 2e-6 }, "independent MTF formula")
                case .greenNoise:
                    let after = try await session.pixel(view: 1, x: x, y: y)
                    try require(abs(after[1] - min(expected[1], (expected[0] + expected[2]) / 2)) < 2e-6 && after[0] == expected[0] && after[2] == expected[2], "SCNR average-neutral pixels")
                case .crop:
                    let after = try await session.pixel(view: 1, x: 0, y: 0)
                    let corner = (0..<3).map { values[$0 * width * height + 13 * width + 16] }
                    try require(info.width == 64 && info.height == 48 && after == corner, "crop selection coordinates or pixels")
                case .mirrorHorizontal, .mirrorVertical, .rotate180:
                    let fromX = tool == .mirrorVertical ? x : width - 1 - x
                    let fromY = tool == .mirrorHorizontal ? y : height - 1 - y
                    let mirrored = (0..<3).map { values[$0 * width * height + fromY * width + fromX] }
                    let after = try await session.pixel(view: 1, x: x, y: y)
                    try require(after == mirrored, "\(tool.rawValue) coordinates")
                case .binning:
                    let after = try await session.pixel(view: 1, x: 10, y: 10)
                    for c in 0..<3 {
                        let mean = (values[c * width * height + 20 * width + 20] + values[c * width * height + 20 * width + 21] + values[c * width * height + 21 * width + 20] + values[c * width * height + 21 * width + 21]) / 4
                        try require(info.width == 48 && info.height == 48 && abs(after[c] - mean) < 2e-6, "independent binning mean")
                    }
                case .rotate90, .rotate270:
                    let fromX = tool == .rotate90 ? y : width - 1 - y
                    let fromY = tool == .rotate90 ? height - 1 - x : x
                    let rotated = (0..<3).map { values[$0 * width * height + fromY * width + fromX] }
                    let after = try await session.pixel(view: 1, x: x, y: y)
                    try require(after == rotated, "\(tool.rawValue) displayed direction")
                case .resample:
                    let after = try await session.pixel(view: 1, x: 10, y: 10)
                    let resized = (0..<3).map { values[$0 * width * height + 32 * width + 20] }
                    try require(info.width == 48 && info.height == 32 && after == resized, "independent nonuniform nearest resampling")
                case .wavelets, .ccm:
                    let after = try await session.pixel(view: 1, x: x, y: y)
                    try require(zip(after, expected).allSatisfy { abs($0.0 - $0.1) < 2e-5 }, "identity \(tool.rawValue) changed pixels")
                default: break
                }
                try require(try Data(contentsOf: file.url) == sourceBytes, "tool changed imported original")
                checkpoint("PASS: native tool \(tool.rawValue) executed original worker and preserved source")
            } catch {
                let failure = "FAIL: \(tool.rawValue): \(error.localizedDescription)\n" + String(Self.processingLog().suffix(1200))
                failures.append(failure); checkpoint(failure)
            }
        }
        try require(failures.isEmpty, failures.joined(separator: "\n"))
        let identity = NativeToolRecipe(tool: .rotate, file: file)
        try await session.compute(identity, library: records)
        let same = try await session.pixel(view: 1, x: x, y: y)
        try require(same == expected, "zero-angle geometry failed to preserve pixels")
        var negativeAngle = identity; negativeAngle.values["angle"] = -90
        try await session.compute(negativeAngle, library: records)
        let backwards = try await session.pixel(view: 1, x: x, y: y)
        let backwardsOffset = x * width + (width - 1 - y)
        let backwardsExpected: [Float] = (0..<3).map { channel in
            values[channel * width * height + backwardsOffset]
        }
        try require(backwards == backwardsExpected, "negative desktop rotation angle changed direction")
        var oversized = NativeToolRecipe(tool: .resample, file: file)
        oversized.values["mode"] = 4; oversized.values["width"] = 100000; oversized.values["height"] = 100000
        var tooLargeRejected = false
        do { try await session.compute(oversized, library: records) } catch { tooLargeRejected = true }
        try require(tooLargeRejected, "oversized resampling attempted an unsafe allocation")
        checkpoint("START: original deconvolution and PSF")
        jobs += try await deconvolutionSelfTest(file: file, expected: expected, x: x, y: y)
        checkpoint("PASS: original deconvolution SB/RL/Wiener with independent unit-PSF pixels, all RL regularizers/methods/stopping, real masks, independent Gaussian/Moffat and Disc/Airy/star/blind/multiscale PSFs, mono/RGB kernel save/load, script replay, failure/stale-result guards, persistent PSF history and gallery restore/cleanup")
        checkpoint("START: original FFT with independent direct DFT")
        jobs += try await fftToolSelfTest()
        checkpoint("PASS: native tool fftInverse; original FFT mono/RGB centered/regular odd rectangular and black images, independent DFT modulus/phase, full inverse round-trip, saved pair/script replay, stale/malformed pair rejection, persisted pair undo/redo and task delete/restore")
        checkpoint("START: original advanced curves and PixelMath")
        jobs += try await advancedToolsSelfTest(file: file, values: values, width: width, height: height, x: x, y: y)
        checkpoint("PASS: original curves/interpolators/L-C-S channels/stages/range masks and PixelMath RGB/statistics/variables/parameters/three-expression composition/constant rescaling/failure guards; saved script replay and restored advanced history")
        // A non-centred crop must select the same displayed pixels with either
        // sensor ROWORDER tag. Symmetric selections can hide a double flip.
        var bottomBytes = Data(bytes.prefix(2880))
        let rowCard = "ROWORDER= 'BOTTOM-UP'".padding(toLength: 80, withPad: " ", startingAt: 0)
        bottomBytes.replaceSubrange(6 * 80..<7 * 80, with: rowCard.utf8)
        for c in 0..<3 { for row in 0..<height { for column in 0..<width {
            var encoded = values[c * width * height + (height - 1 - row) * width + column].bitPattern.bigEndian
            withUnsafeBytes(of: &encoded) { bottomBytes.append(contentsOf: $0) }
        } } }
        bottomBytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bottomBytes.count % 2880) % 2880))
        let bottomFixture = folder.appendingPathComponent("tools-bottom-up.fits"); try bottomBytes.write(to: bottomFixture)
        let bottomFile = try importFile(bottomFixture)
        let bottomSession = NativeToolSession(); try await bottomSession.open(bottomFile)
        var crop = NativeToolRecipe(tool: .crop, file: bottomFile)
        crop.values["x"] = 16; crop.values["y"] = 13; crop.values["width"] = 64; crop.values["height"] = 48
        try await bottomSession.compute(crop, library: [bottomFile])
        let bottomCorner = try await bottomSession.pixel(view: 1, x: 0, y: 0)
        let cornerOffset = 13 * width + 16
        let bottomExpected: [Float] = (0..<3).map { c in values[c * width * height + cornerOffset] }
        try require(bottomCorner == bottomExpected, "bottom-up crop displayed coordinates")
        await bottomSession.close(); try fm.removeItem(at: bottomFile.url)
        for mode in [1, 3, 4, 5] {
            checkpoint("START: original mask source \(mode)")
            var recipe = NativeToolRecipe(tool: .negative, file: file)
            recipe.mask.values["mode"] = Double(mode)
            if mode == 3 { recipe.mask.sourceID = file.id }
            if mode == 4 {
                recipe.mask.values["red"] = Double(expected[0]); recipe.mask.values["green"] = Double(expected[1]); recipe.mask.values["blue"] = Double(expected[2])
            }
            try await session.compute(recipe, library: records)
            let mask = try await session.pixel(view: 2, x: mode == 5 ? 45 : x, y: mode == 5 ? 48 : y)[0]
            try require(mask.isFinite && (0...1).contains(mask), "mask source \(mode) did not produce normalized pixels")
            if mode == 5 {
                let outside = try await session.pixel(view: 2, x: 5, y: 5)[0]
                try require(mask > 0.5 && outside == 0, "star mask did not cover the known star independently of background")
            }
        }
        var guide = NativeToolRecipe(tool: .guided, file: file)
        checkpoint("START: original external guided filter")
        guide.guideID = file.id; guide.values["diameter"] = 2
        try await session.compute(guide, library: records)
        let guided = try await session.pixel(view: 1, x: x, y: y)
        try require(guided.allSatisfy(\.isFinite), "external guide image was not processed")
        guide.values["amount"] = 0
        try await session.compute(guide, library: records)
        let unchanged = try await session.pixel(view: 1, x: x, y: y)
        try require(zip(unchanged, expected).allSatisfy { abs($0.0 - $0.1) < 2e-6 }, "zero guided-filter modulation changed original pixels")
        for depth in 0..<3 {
            checkpoint("START: original channel mask bit depth \(depth)")
            var masked = NativeToolRecipe(tool: .negative, file: file)
            masked.mask.values["mode"] = 2; masked.mask.values["depth"] = Double(depth)
            try await session.compute(masked, library: records)
            let after = try await session.pixel(view: 1, x: x, y: y), mask = try await session.pixel(view: 2, x: x, y: y)[0]
            try require(abs(mask - expected[0]) < (depth == 0 ? 0.004 : 0.00002), "original channel mask precision")
            for c in 0..<3 { try require(abs(after[c] - (expected[c] * (1 - mask) + (1 - expected[c]) * mask)) < 2e-5, "mask was not applied to original pixels") }
            masked.mask.values["invert"] = 1
            try await session.compute(masked, library: records)
            let inverted = try await session.pixel(view: 2, x: x, y: y)[0]
            try require(abs(inverted - (1 - mask)) < 2e-5, "mask inversion changed orientation or precision")
        }
        var masked = NativeToolRecipe(tool: .negative, file: file)
        checkpoint("START: mask operations, inheritance and geometry")
        masked.mask.values["mode"] = 1; masked.mask.values["blur"] = 1; masked.mask.values["threshold"] = 1; masked.mask.values["low"] = 0.1; masked.mask.values["high"] = 0.8
        masked.mask.values["feather"] = 1; masked.mask.values["factor"] = 0.8
        try await session.compute(masked, library: records)
        let maskedPixel = try await session.pixel(view: 1, x: x, y: y)
        let job = try prepareNativeToolJob(file: file, recipe: masked, library: records); jobs.append(job)
        let output = try await session.export(masked, to: job)
        var saved = try importFile(output, role: .results); saved.parentID = file.id; records.append(saved)
        try require(saved.hasMask == true, "export/import lost the original mask")
        let savedSession = NativeToolSession(); try await savedSession.open(saved)
        var inherited = NativeToolRecipe(tool: .resample, file: saved)
        try await savedSession.compute(inherited, library: records)
        let restoredMask = try await savedSession.pixel(view: 2, x: x, y: y)[0]
        let beforeMask = try await session.pixel(view: 2, x: x, y: y)[0]
        let restoredPixel = try await savedSession.pixel(view: 1, x: x, y: y)
        try require(restoredMask == beforeMask && restoredPixel == maskedPixel, "saved mask or identity geometry pixels changed")
        inherited.values["mode"] = 1; inherited.values["size"] = 48
        try await savedSession.compute(inherited, library: records)
        let resizedMaskInfo = try await savedSession.info(view: 2)
        try require(resizedMaskInfo.width == 48 && resizedMaskInfo.height == 48, "native geometry did not resize the inherited mask")
        await savedSession.close()
        var changed = masked; changed.values["unused"] = 4
        var rejected = false
        do { _ = try await session.export(changed, to: job) } catch { rejected = true }
        try require(rejected, "stale parameters exported")
        changed = NativeToolRecipe(tool: .ghs, file: file); changed.values["LP"] = 0.8; changed.values["SP"] = 0.1
        rejected = false
        do { try await session.compute(changed, library: records) } catch { rejected = true }
        try require(rejected, "invalid protection ranges computed")
        rejected = false
        do { _ = try await session.export(masked, to: job) } catch { rejected = true }
        try require(rejected, "failed compute retained an applicable prior preview")
        await session.close()

        let existingLibrary = loadLibrary()
        checkpoint("START: tool history and companion trash lifecycle")
        var history = try nativeToolHistory(saved, tool: .resample)
        history.record(inherited); try saveNativeToolHistory(history, file: saved)
        let historyBytes = try Data(contentsOf: saved.url.appendingPathExtension("tools.json"))
        let maskBytes = try Data(contentsOf: saved.url.appendingPathExtension("mask.fits"))
        try saveLibrary(existingLibrary + [saved])
        _ = try moveToTrash(ids: [saved.id])
        guard let deletion = trashEntries().first(where: { $0.records.contains(where: { $0.id == saved.id }) }) else { throw EngineError.failed("Tool companion trash missing") }
        _ = try restoreTrash(deletion.id)
        try require(try Data(contentsOf: saved.url.appendingPathExtension("tools.json")) == historyBytes, "persistent mask/tool history restoration")
        try require(try Data(contentsOf: saved.url.appendingPathExtension("mask.fits")) == maskBytes, "saved mask restoration")
        var reopened = try nativeToolHistory(saved, tool: .resample)
        reopened.step(redo: false); try require(reopened.current != inherited, "persisted parameter undo")
        reopened.step(redo: true); try require(reopened.current == inherited, "persisted parameter redo")
        reopened.step(redo: false); reopened.record(NativeToolRecipe(tool: .rotate180, file: saved)); try require(reopened.future.isEmpty, "new tool edit retained redo branch")
        _ = try moveToTrash(ids: [saved.id])
        let trash = Set(trashEntries().filter { $0.records.contains(where: { $0.id == saved.id }) }.map(\.id)); try permanentlyDeleteTrash(trash)
        try require(!fm.fileExists(atPath: saved.url.path) && !fm.fileExists(atPath: saved.url.appendingPathExtension("mask.fits").path), "permanent cleanup retained source companions")
        try saveLibrary(existingLibrary)

        for format in NativeImageFormat.allCases {
            checkpoint("START: original format \(format.rawValue)")
            let image = try read(file.url); defer { siril_image_free(image) }
            let url = folder.appendingPathComponent(format.rawValue + "." + format.ext)
            try require(url.path.withCString { siril_image_export(image, $0, format.native, format.depth, 100) } != 0, "original \(format.rawValue) export")
            try require(url.path.withCString { siril_image_export(image, $0, format.native, format.depth, 100) } == 0, "format overwrite allowed")
            let imported = try importFile(url)
            let reader = ImageAnalysisEngine(); let details = try await reader.open(imported.url)
            let pixel = try await reader.pixel(x: x, y: y).values
            try require(details.channels == 3 && details.width == width && details.height == height, "format RGB shape/orientation")
            let tolerance: Float = format == .jpeg ? 0.035 : format.depth == 8 ? 0.008 : format.depth == 16 ? 0.00004 : 0.000002
            try require(zip(pixel, expected).allSatisfy { abs($0.0 - $0.1) < tolerance }, "\(format.rawValue) imported pixel precision or orientation")
            try fm.removeItem(at: imported.url)
            checkpoint("PASS: original \(format.rawValue) export/import preserved full-size RGB planes at declared precision")
        }
        for ext in ["jpg", "png", "tif"] {
            let bad = folder.appendingPathComponent("invalid." + ext); try Data("not an image".utf8).write(to: bad)
            rejected = false
            do { _ = try importFile(bad) } catch { rejected = true }
            try require(rejected, "malformed \(ext) did not fail safely")
        }
        for job in jobs {
            guard let task = jobHistory().first(where: { $0.id == job.folder.lastPathComponent }) else { throw EngineError.failed("Tool task missing") }
            try trashJob(task)
            try permanentlyDeleteTrash(Set(trashEntries().filter { $0.jobName == task.id }.map(\.id)))
        }
        try require(try Data(contentsOf: file.url) == sourceBytes, "exports, masks or cleanup changed source pixels")
        checkpoint("PASS: all mask sources, 8/16/32-bit blending/inversion, inherited/resized masks, stale previews, persistent history, companion restoration/permanent cleanup and malformed-file survival")
    }
}
