// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func sequenceFilterSelfTest() throws {
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw EngineError.failed("Sequence filters: " + message) }
        }
        let fm = FileManager.default, baseline = loadLibrary(), size = 32
        let scratch = documents.appendingPathComponent("sequence-filter-tests-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        var inputs: [FITSRecord] = [], jobs: [URL] = [], floatSources: [URL] = [], integerSources: [URL] = []
        defer {
            for job in jobs { try? fm.removeItem(at: job) }
            for file in inputs { try? fm.removeItem(at: file.url) }
            try? fm.removeItem(at: scratch); try? saveLibrary(baseline)
        }
        func value(_ frame: Int, _ channel: Int, _ x: Int, _ y: Int) -> Double {
            0.05 + Double(frame) * 0.02 + Double(channel) * 0.08 + (frame == 2 ? Double(x) * 0.004 : Double(y) * 0.006)
        }
        for frame in 0..<3 {
            for integer in [false, true] {
                var cards = ["SIMPLE  =                    T", integer ? "BITPIX  =                   16" : "BITPIX  =                  -32",
                    "NAXIS   =                    3", "NAXIS1  =                   32", "NAXIS2  =                   32", "NAXIS3  =                    3"]
                if integer { cards += ["BZERO   =                32768", "BSCALE  =                    1"] }
                cards.append("END")
                var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
                    .padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
                for channel in 0..<3 { for row in 0..<size { for x in 0..<size {
                    let sample = value(frame, channel, x, size - 1 - row)
                    if integer {
                        var encoded = (UInt16((sample * 65535).rounded()) ^ 0x8000).bigEndian
                        withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
                    } else {
                        var encoded = Float(sample).bitPattern.bigEndian
                        withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
                    }
                } } }
                if bytes.count % 2880 != 0 { bytes.append(Data(repeating: 0, count: 2880 - bytes.count % 2880)) }
                let url = scratch.appendingPathComponent("input-\(frame)-\(integer).fits")
                try bytes.write(to: url)
                if integer { integerSources.append(url) }
                else { floatSources.append(url); inputs.append(try importFile(url)) }
            }
        }
        let regular = try createSequence(files: inputs); jobs.append(regular.folder)
        let fitseq = try prepareJob(files: inputs, script: "set32bits\ncd lights\nconvert filters -fitseq -out=../process\n")
        jobs.append(fitseq.folder); _ = try run(fitseq)
        var error = [CChar](repeating: 0, count: 512); let capacity = error.count
        try require(fitseq.folder.appendingPathComponent("process").path.withCString { siril_sequence_discover($0, &error, capacity) } != 0, "FITSEQ discovery")
        guard let regularLocation = sequenceLocations(job: regular.folder.lastPathComponent).first,
              let containerLocation = sequenceLocations(job: fitseq.folder.lastPathComponent).first else { throw EngineError.failed("Filter fixtures missing") }
        var ser = Data("LUCAM-RECORDER".utf8)
        let fields: [UInt32] = [0, 100, 0, 32, 32, 16, 3]
        for field in fields { var encoded = field.littleEndian; withUnsafeBytes(of: &encoded) { ser.append(contentsOf: $0) } }
        ser.append(Data(repeating: 0, count: 136))
        for frame in 0..<3 { for y in 0..<size { for x in 0..<size { for channel in 0..<3 {
            var encoded = UInt16((value(frame, channel, x, y) * 65535).rounded()).littleEndian
            withUnsafeBytes(of: &encoded) { ser.append(contentsOf: $0) }
        } } } }
        let serURL = scratch.appendingPathComponent("source.ser"); try ser.write(to: serURL)
        let serLocation = try importSERSequence(serURL); jobs.append(try sequenceFolder(serLocation).deletingLastPathComponent())
        func pixels(_ image: OpaquePointer) throws -> [Float] {
            var info = SirilImageInfo(); _ = siril_image_info(image, &info)
            try require(Int(info.width) == size && Int(info.height) == size && info.channels == 3, "output geometry")
            var result: [Float] = [], raw = [Float](repeating: 0, count: 3)
            for y in 0..<size { for x in 0..<size {
                try require(siril_image_pixel(image, Int32(x), Int32(y), &raw) == 3, "output pixels")
                result.append(contentsOf: raw)
            } }
            return result
        }
        for location in [regularLocation, containerLocation, serLocation] {
            try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 2))
            let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
            let paths = try sequenceFilePaths(location)
            let sources = try paths.map { try Data(contentsOf: sequenceKeywordSource($0, under: root)) }
            let metadata = try sequenceToolFile(location)
            for variant in 0..<8 {
                var recipe = NativeToolRecipe(tool: variant < 3 ? .banding : .wavelets, file: metadata)
                if variant < 3 {
                    recipe.values["amount"] = variant == 0 ? 0.5 : 0.75
                    recipe.values["vertical"] = variant == 0 ? 0 : 1
                    recipe.values["protect"] = variant == 2 ? 1 : 0
                    recipe.values["sigma"] = 1
                } else {
                    recipe.values["layers"] = 2; recipe.values["type"] = variant == 3 ? 0 : 1
                    if variant != 5 { recipe.values["c0"] = 1.4; recipe.values["c1"] = 0.7 }
                    if variant >= 6 {
                        recipe.values["vst"] = 1; recipe.values["denoise"] = 1
                        recipe.values["method"] = variant == 6 ? 0 : 1
                        recipe.values["soft"] = variant == 6 ? 1 : 0
                        recipe.values["perband"] = 1; recipe.values["k"] = 2
                    }
                }
                let output = try applySequenceTool(location, recipe: recipe)
                let generated = try inspectSequence(output)
                try require(generated.frames.count == 2 && generated.selection == SequenceSelection(included: [true, true], reference: 1), "inclusion/reference")
                for (index, sourceFrame) in [0, 2].enumerated() {
                    guard let frame = process.path.withCString({ directory in output.name.withCString { siril_sequence_frame(directory, $0, Int32(index), &error, capacity) } }) else {
                        throw EngineError.failed(String(cString: error))
                    }
                    let actual: [Float]
                    do { defer { siril_image_free(frame) }; actual = try pixels(frame) }
                    // Keep the original source bit depth for both original workers.
                    // The normal single-image workspace promotes integers with fmul 1.
                    guard let line = try recipe.commands(file: metadata, topDown: false).split(separator: "\n").last else {
                        throw EngineError.failed("Filter reference command missing")
                    }
                    let command = String(line)
                    let direct = try prepareJob(files: [], script: "set32bits\ncd process\nload input.fits\n" + command + "\nsave result.fits\nclose\n")
                    jobs.append(direct.folder)
                    try fm.copyItem(at: location == serLocation ? integerSources[sourceFrame] : floatSources[sourceFrame], to: direct.folder.appendingPathComponent("process/input.fits"))
                    _ = try run(direct)
                    let referenceImage = try read(direct.folder.appendingPathComponent("process/result.fits"))
                    let reference: [Float]
                    do { defer { siril_image_free(referenceImage) }; reference = try pixels(referenceImage) }
                    let tolerance = location == serLocation ? 1.1 / 65535 : 2e-6
                    try require(zip(actual, reference).allSatisfy { abs(Double($0.0 - $0.1)) < tolerance }, "original single/sequence worker variant \(variant), \(location.name), frame \(sourceFrame)")
                    if variant < 2 || variant == 5 {
                        for y in 0..<size { for x in 0..<size { for channel in 0..<3 {
                            var expected = value(sourceFrame, channel, x, y)
                            if variant == 0 && sourceFrame == 0 { expected += 0.5 * 0.006 * Double(size - 1 - y) }
                            if variant == 1 && sourceFrame == 2 { expected += 0.75 * 0.004 * Double(size - 1 - x) }
                            let bound = location == serLocation ? 4 / 65535.0 : 2e-6
                            try require(abs(Double(actual[(y * size + x) * 3 + channel]) - expected) < bound, "independent stripe correction/identity wavelet")
                        } } }
                    }
                }
                let state = try recordSequenceResult(entry: location, source: location, output: output)
                try require(state.history.current == output && state.canUndo, "history")
                try require(try replaySequenceResult(location, redo: false).history.current == location, "undo")
                try require(try replaySequenceResult(location, redo: true).history.current == output, "redo")
            }
            for (index, path) in paths.enumerated() {
                try require(try Data(contentsOf: sequenceKeywordSource(path, under: root)) == sources[index], "source bytes changed: " + path)
            }
            if location == regularLocation {
                try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 0))
                let sourceIndex = try Data(contentsOf: process.appendingPathComponent(location.name))
                let framePaths = paths.filter { $0.split(separator: "/").count == 2 && !$0.hasSuffix(".seq") }
                try require(framePaths.count == 3, "frame ownership list")
                let missing = try sequenceKeywordSource(framePaths[2], under: root), withheld = scratch.appendingPathComponent("withheld.fits")
                try fm.moveItem(at: missing, to: withheld)
                do {
                    defer { try? fm.moveItem(at: withheld, to: missing) }
                    for tool in SequenceImageTools.filters {
                        let runs = root.appendingPathComponent("SequenceRuns"), existing = Set(try fm.contentsOfDirectory(atPath: runs.path))
                        var recipe = NativeToolRecipe(tool: tool, file: metadata); recipe.values["layers"] = 2
                        var rejected = false
                        do { _ = try applySequenceTool(location, recipe: recipe) } catch { rejected = true }
                        try require(rejected, "partial filter output accepted")
                        let failed = Set(try fm.contentsOfDirectory(atPath: runs.path)).subtracting(existing)
                        try require(failed.count == 1, "failed run record")
                        if let name = failed.first {
                            let folder = runs.appendingPathComponent(name), prefix = "r_" + name.replacingOccurrences(of: "-", with: "") + "_"
                            try require(fm.fileExists(atPath: folder.appendingPathComponent("filter.json").path) && !fm.fileExists(atPath: folder.appendingPathComponent("output-sequence.json").path), "failed recipe/manifest")
                            try require(try fm.contentsOfDirectory(atPath: process.path).allSatisfy { !$0.hasPrefix(prefix) }, "partial filter files survived")
                        }
                        try require(try Data(contentsOf: process.appendingPathComponent(location.name)) == sourceIndex, "failure changed selection/reference")
                    }
                }
            }
        }
    }
}
