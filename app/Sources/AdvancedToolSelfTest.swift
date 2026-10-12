// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func advancedToolsSelfTest(file: FITSRecord, values: [Float], width: Int, height: Int, x: Int, y: Int) async throws -> [ProcessingJob] {
        func require(_ ok: Bool, _ detail: String) throws {
            if !ok { throw EngineError.failed("Advanced tools: " + detail) }
        }
        func equal(_ actual: [Float], _ expected: [Float], _ tolerance: Float = 0.00004) -> Bool {
            actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0.0 - $0.1) < tolerance }
        }
        func headerNumber(_ header: String, _ keyword: String) -> Double? {
            let row = header.components(separatedBy: .newlines).first { $0.prefix(8).trimmingCharacters(in: .whitespaces) == keyword }
            guard let row, let split = row.firstIndex(of: "=") else { return nil }
            let value = row[row.index(after: split)...].split(separator: "/", maxSplits: 1).first
            return value.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        let count = width * height, offset = y * width + x
        let expected: [Float] = (0..<3).map { values[$0 * count + offset] }
        let sourceBytes = try Data(contentsOf: file.url)
        let fm = FileManager.default
        let fixture = documents.appendingPathComponent("advanced-mono-" + UUID().uuidString + ".fits")
        var monoBytes = Data(sourceBytes.prefix(2880))
        let monoCard = "NAXIS   =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        monoBytes.replaceSubrange(2 * 80..<3 * 80, with: monoCard.utf8)
        let exposureCard = "EXPTIME =                 20.0".padding(toLength: 80, withPad: " ", startingAt: 0)
        monoBytes.replaceSubrange(5 * 80..<6 * 80, with: exposureCard.utf8)
        monoBytes.append(sourceBytes.subdata(in: 2880..<2880 + count * 4))
        let padding = (2880 - monoBytes.count % 2880) % 2880
        monoBytes.append(Data(repeating: 0, count: padding))
        try monoBytes.write(to: fixture)
        defer { try? fm.removeItem(at: fixture) }
        let mono = try importFile(fixture)
        defer { try? fm.removeItem(at: mono.url); try? fm.removeItem(at: mono.url.appendingPathExtension("tools.json")) }
        let session = NativeToolSession(); try await session.open(file)
        var recipe = NativeToolRecipe(tool: .curves, file: file)
        recipe.curveSettings.current.algorithm = 1
        recipe.curveSettings.current.channels[0].points.insert(CurveKnot(x: 0.5, y: 0.8), at: 1)
        try await session.compute(recipe, library: [file, mono])
        let linear = try await session.pixel(view: 1, x: x, y: y)
        let linearExpected = expected.map { $0 * 1.6 }
        try require(equal(linear, linearExpected), "independent linear curve pixels")
        let histograms = try await session.curveHistograms(view: 0)
        try require(histograms.count == 7 && histograms.allSatisfy({ $0.reduce(0, +) == UInt64(count) }), "all curve-space histogram counts")
        let tone = try await session.curvePipette(recipe.curveSettings, x: x, y: y)
        let meanTone = Double(expected.reduce(0, +) / 3)
        try require(abs(tone - meanTone) < 0.000001, "pre-curve pixel pipette")
        let plot = recipe.curveSettings.plotted()
        try require(plot.count == 257 && abs(plot[128] - 0.8) < 0.000001, "original interpolation graph")
        for algorithm in [0, 2] {
            recipe.curveSettings.current.algorithm = algorithm
            try await session.compute(recipe, library: [file, mono])
            let pixel = try await session.pixel(view: 1, x: x, y: y)
            try require(pixel.allSatisfy(\.isFinite) && !equal(pixel, expected, 0.000001), "original cubic/Akima execution")
        }
        recipe.curveSettings.current.algorithm = 1
        recipe.curveSettings.stages = [recipe.curveSettings.current]
        recipe.curveSettings.current = CurveStage(); recipe.curveSettings.current.algorithm = 1
        recipe.curveSettings.current.channels[1].points = [CurveKnot(x: 0, y: 1), CurveKnot(x: 1, y: 0)]
        try await session.compute(recipe, library: [file, mono])
        let staged = try await session.pixel(view: 1, x: x, y: y)
        let stagedExpected = [1 - linearExpected[0], linearExpected[1], linearExpected[2]]
        try require(equal(staged, stagedExpected), "independent staged RGB then red-channel curve")
        recipe.curveSettings.selectedChannel = 1
        let stagedTone = try await session.curvePipette(recipe.curveSettings, x: x, y: y)
        try require(abs(stagedTone - Double(linearExpected[0])) < 0.00004, "pipette used original current curve input after retained stages")
        for channel in 4...6 {
            var special = NativeToolRecipe(tool: .curves, file: file)
            special.curveSettings.selectedChannel = channel
            special.curveSettings.current.channels[channel].points.insert(CurveKnot(x: 0.5, y: 0.7), at: 1)
            try await session.compute(special, library: [file, mono])
            let pixel = try await session.pixel(view: 1, x: x, y: y)
            try require(pixel.allSatisfy(\.isFinite) && !equal(pixel, expected, 0.000001), "original L/chroma/saturation channel execution")
        }
        recipe = NativeToolRecipe(tool: .curves, file: file)
        recipe.curveSettings.current.algorithm = 1
        recipe.curveSettings.current.channels[0].points = [CurveKnot(x: 0, y: 1), CurveKnot(x: 1, y: 0)]
        recipe.curveSettings.current.channels[0].rangeEnabled = true
        recipe.curveSettings.current.channels[0].low = 0.2
        recipe.curveSettings.current.channels[0].high = 0.8
        recipe.curveSettings.current.channels[0].feather = 0.1
        try await session.compute(recipe, library: [file, mono])
        let lum = Double(expected.reduce(0, +)) / 3
        let lowWeight = 1 / (1 + exp(-2.5 * (lum - 0.2) / 0.1))
        let highWeight = 1 / (1 + exp(-2.5 * (0.8 - lum) / 0.1))
        let weight = Float(min(lowWeight, highWeight))
        let range = try await session.pixel(view: 2, x: x, y: y)
        let ranged = try await session.pixel(view: 1, x: x, y: y)
        let rangedExpected = expected.map { $0 * (1 - weight) + (1 - $0) * weight }
        try require(range.allSatisfy({ abs($0 - weight) < 0.00002 }) && equal(ranged, rangedExpected), "independent sigmoid range mask and actual blended pixels")
        let curveJob = try prepareNativeToolJob(file: file, recipe: recipe, library: [file, mono])
        let curveURL = try await session.export(recipe, to: curveJob)
        try require(!fm.fileExists(atPath: curveURL.appendingPathExtension("mask.fits").path), "curve range display accidentally exported as an attached source mask")
        let curveReplay = try prepareNativeToolJob(file: file, recipe: recipe, library: [file, mono])
        _ = try run(curveReplay)
        let analysis = ImageAnalysisEngine()
        _ = try await analysis.open(curveReplay.folder.appendingPathComponent("process/result.fits"))
        let replayedCurve = try await analysis.pixel(x: x, y: y).values
        try require(equal(replayedCurve, ranged), "saved curve settings/script replay")

        recipe = NativeToolRecipe(tool: .pixelMath, file: file)
        recipe.mathSettings.expressions[0] = "1-$T"
        try await session.compute(recipe, library: [file, mono])
        let negative = try await session.pixel(view: 1, x: x, y: y)
        try require(equal(negative, expected.map { 1 - $0 }, 0.000002), "independent $T expression")
        recipe.mathSettings.expressions[0] = "mean($T)"
        try await session.compute(recipe, library: [file, mono])
        let statistics = try await session.pixel(view: 1, x: x, y: y)
        let means: [Float] = (0..<3).map { c in
            Float(values[(c * count)..<((c + 1) * count)].reduce(0.0) { $0 + Double($1) } / Double(count))
        }
        try require(equal(statistics, means, 0.000002), "per-plane original image-statistics expressions")
        recipe.mathSettings.bindings = [PMBinding(name: "image", imageID: file.id)]
        recipe.mathSettings.parameters = [PMParameter(name: "gain", expression: "1+1")]
        recipe.mathSettings.expressions[0] = "($T+image)/gain"
        try await session.compute(recipe, library: [file, mono])
        let parameterized = try await session.pixel(view: 1, x: x, y: y)
        try require(equal(parameterized, expected, 0.000002), "image variable and expanded expression parameter")
        recipe.mathSettings.bindings = [PMBinding(name: "A", imageID: mono.id)]
        recipe.mathSettings.parameters = []
        recipe.mathSettings.singleRGB = false
        recipe.mathSettings.expressions = ["A", "A*2", "1-A"]
        try await session.compute(recipe, library: [file, mono])
        let combined = try await session.pixel(view: 1, x: x, y: y)
        let combinedExpected = [expected[0], 2 * expected[0], 1 - expected[0]]
        try require(equal(combined, combinedExpected, 0.000002), "independent three-expression mono-to-RGB composition")
        let pmReplay = try prepareNativeToolJob(file: file, recipe: recipe, library: [file, mono])
        _ = try run(pmReplay)
        _ = try await analysis.open(pmReplay.folder.appendingPathComponent("process/result.fits"))
        let replayedPM = try await analysis.pixel(x: x, y: y).values
        try require(equal(replayedPM, combined, 0.000002), "copied variable manifest and original PixelMath script replay")
        recipe = NativeToolRecipe(tool: .pixelMath, file: file)
        recipe.mathSettings.bindings = [PMBinding(name: "I1", imageID: mono.id), PMBinding(name: "I10", imageID: mono.id)]
        recipe.mathSettings.expressions[0] = "I1+I10"
        try await session.compute(recipe, library: [file, mono])
        var metadata = try await session.info(view: 1)
        var header = try await session.header(view: 1)
        try require(abs(metadata.exposure - 20) < 0.000001 && headerNumber(header, "LIVETIME") == 40 && headerNumber(header, "STACKCNT") == 2, "average subexposure and summed integration/frame metadata")
        recipe.mathSettings.doSum = false
        try await session.compute(recipe, library: [file, mono])
        metadata = try await session.info(view: 1)
        header = try await session.header(view: 1)
        try require(abs(metadata.exposure - 20) < 0.000001 && headerNumber(header, "LIVETIME") == 20 && headerNumber(header, "STACKCNT") == 1, "non-summed integration/frame metadata")
        recipe.mathSettings.doSum = true; recipe.mathSettings.expressions[0] = "I10"
        try await session.compute(recipe, library: [file, mono])
        metadata = try await session.info(view: 1)
        header = try await session.header(view: 1)
        try require(abs(metadata.exposure - 20) < 0.000001 && headerNumber(header, "LIVETIME") == 20, "I1 name prefix incorrectly contributed unused image metadata")
        recipe.mathSettings.expressions[0] = "mean(I10)"
        try await session.compute(recipe, library: [file, mono])
        metadata = try await session.info(view: 1)
        header = try await session.header(view: 1)
        try require(abs(metadata.exposure - 20) < 0.000001 && headerNumber(header, "LIVETIME") == 20, "statistics-only image expression lost used input metadata")
        recipe = NativeToolRecipe(tool: .pixelMath, file: file)
        recipe.mathSettings.expressions[0] = "0.25"
        recipe.mathSettings.rescale = true; recipe.mathSettings.low = 0.1; recipe.mathSettings.high = 0.9
        try await session.compute(recipe, library: [file, mono])
        let constant = try await session.pixel(view: 1, x: x, y: y)
        try require(equal(constant, [0.1, 0.1, 0.1], 0.000002), "constant rescaling survived without NaN")
        for expression in ["unknown_function($T)", "sqrt(-1)+$T*0"] {
            recipe.mathSettings.expressions[0] = expression
            var rejected = false
            do { try await session.compute(recipe, library: [file, mono]) } catch { rejected = true }
            try require(rejected, "syntax/nonfinite result was reported successful")
            rejected = false
            do { _ = try await session.export(recipe, to: curveJob) } catch { rejected = true }
            try require(rejected, "failed expression exported stale pixels")
        }
        recipe.mathSettings.expressions[0] = "a*$T"
        recipe.mathSettings.parameters = [PMParameter(name: "a", expression: "b"), PMParameter(name: "b", expression: "a")]
        var cycleRejected = false
        do { try await session.compute(recipe, library: [file, mono]) } catch { cycleRejected = true }
        try require(cycleRejected, "cyclic parameters reached original evaluator")
        await session.close()
        let before = loadLibrary()
        let sourceHistory = NativeToolHistory(sourceID: file.id, width: file.width, height: file.height, current: recipe)
        try saveNativeToolHistory(sourceHistory, file: file)
        let historyBytes = try Data(contentsOf: file.url.appendingPathExtension("tools.json"))
        try saveLibrary(before + [file, mono])
        _ = try moveToTrash(ids: [file.id])
        guard let entry = trashEntries().first(where: { $0.records.contains(where: { $0.id == file.id }) }) else { throw EngineError.failed("Advanced history trash missing") }
        _ = try restoreTrash(entry.id)
        let restoredHistory = try nativeToolHistory(file, tool: .pixelMath)
        let restoredBytes = try Data(contentsOf: file.url.appendingPathExtension("tools.json"))
        try require(restoredHistory.current == recipe && restoredBytes == historyBytes, "restored image bindings/parameters/advanced history")
        _ = try moveToTrash(ids: [mono.id])
        try permanentlyDeleteTrash(Set(trashEntries().filter { $0.records.contains(where: { $0.id == mono.id }) }.map(\.id)))
        try saveLibrary(before)
        try require(try Data(contentsOf: file.url) == sourceBytes, "advanced tools/history changed original FITS")
        return [curveJob, curveReplay, pmReplay]
    }
}
