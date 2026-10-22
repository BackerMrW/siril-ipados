// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func sequenceStretchSelfTest() async throws {
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw EngineError.failed("Sequence stretch: " + message) } }
        let fm = FileManager.default, baseline = loadLibrary()
        let scratch = documents.appendingPathComponent("stretch-tests-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        var inputs: [FITSRecord] = [], jobs: [URL] = []
        defer {
            for job in jobs { try? fm.removeItem(at: job) }
            for file in inputs { try? fm.removeItem(at: file.url) }
            try? fm.removeItem(at: scratch); try? saveLibrary(baseline)
        }
        func value(_ frame: Int, _ channel: Int, _ x: Int, _ y: Int) -> Float {
            Float(0.05 + Double(frame) * 0.02 + Double(channel) * 0.08 + Double(x) * 0.04 + Double(y) * 0.06)
        }
        for frame in 0..<3 {
            let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    3",
                "NAXIS1  =                    4", "NAXIS2  =                    3", "NAXIS3  =                    3", "END"]
            var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
                .padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for channel in 0..<3 { for row in 0..<3 { for x in 0..<4 {
                var sample = value(frame, channel, x, 2 - row).bitPattern.bigEndian
                withUnsafeBytes(of: &sample) { bytes.append(contentsOf: $0) }
            } } }
            bytes.append(Data(repeating: 0, count: 2880 - bytes.count % 2880))
            let url = scratch.appendingPathComponent("input-\(frame).fits"); try bytes.write(to: url)
            inputs.append(try importFile(url))
        }
        let regular = try createSequence(files: inputs); jobs.append(regular.folder)
        let fitseq = try prepareJob(files: inputs, script: "set32bits\ncd lights\nconvert stretch -fitseq -out=../process\n")
        jobs.append(fitseq.folder); _ = try run(fitseq)
        var error = [CChar](repeating: 0, count: 512); let capacity = error.count
        try require(fitseq.folder.appendingPathComponent("process").path.withCString { siril_sequence_discover($0, &error, capacity) } != 0, "FITSEQ discovery")
        guard let regularLocation = sequenceLocations(job: regular.folder.lastPathComponent).first,
              let containerLocation = sequenceLocations(job: fitseq.folder.lastPathComponent).first else { throw EngineError.failed("Stretch sequence fixtures missing") }
        var ser = Data("LUCAM-RECORDER".utf8)
        let serFields: [UInt32] = [0, 100, 0, 4, 3, 16, 3]
        for field in serFields {
            var encoded = field.littleEndian; withUnsafeBytes(of: &encoded) { ser.append(contentsOf: $0) }
        }
        ser.append(Data(repeating: 0, count: 136))
        for frame in 0..<3 { for y in 0..<3 { for x in 0..<4 { for channel in 0..<3 {
            var encoded = UInt16((Double(value(frame, channel, x, y)) * 65535).rounded()).littleEndian
            withUnsafeBytes(of: &encoded) { ser.append(contentsOf: $0) }
        } } } }
        let serURL = scratch.appendingPathComponent("source.ser"); try ser.write(to: serURL)
        let serLocation = try importSERSequence(serURL); jobs.append(try sequenceFolder(serLocation).deletingLastPathComponent())
        func pixels(_ location: SequenceLocation, _ index: Int) throws -> [Float] {
            let directory = try sequenceFolder(location)
            guard let image = directory.path.withCString({ path in location.name.withCString { siril_sequence_frame(path, $0, Int32(index), &error, capacity) } }) else {
                throw EngineError.failed(String(cString: error))
            }
            defer { siril_image_free(image) }
            var result: [Float] = []
            for y in 0..<3 { for x in 0..<4 {
                var raw = [Float](repeating: 0, count: 3)
                try require(siril_image_pixel(image, Int32(x), Int32(y), &raw) == 3, "RGB frame read")
                result.append(contentsOf: raw)
            } }
            return result
        }
        for location in [regularLocation, containerLocation, serLocation] {
            // SER quantizes both its independent source and its result to UInt16.
            // The known fixture/parameters have gain < 3, so four LSBs bound
            // those two roundings; Float32 regular/FITSEQ retain 2e-6.
            let tolerance: Double = location == serLocation ? 4 / 65535.0 : 2e-6
            try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 2))
            let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
            let sourceIndex = try Data(contentsOf: process.appendingPathComponent(location.name))
            let sourcePaths = try sequenceFilePaths(location)
            let sources = try sourcePaths.map { try Data(contentsOf: sequenceKeywordSource($0, under: root)) }
            let metadata = try sequenceToolFile(location)
            for tool in SequenceImageTools.stretches {
                var recipe = NativeToolRecipe(tool: tool, file: metadata)
                if tool == .mtf { recipe.values["mid"] = 0.3; recipe.values["channels"] = 1 }
                else if tool == .linearStretch { recipe.values["BP"] = 0.1 }
                else { recipe.values["D"] = 0.5; recipe.values["SP"] = 0.2 }
                let output = try applySequenceTool(location, recipe: recipe)
                let generated = try inspectSequence(output)
                try require(generated.frames.count == 2 && generated.selection.reference == 1 && generated.selection.included == [true, true], "output selection/reference")
                for (index, sourceFrame) in [0, 2].enumerated() {
                    let actual = try pixels(output, index)
                    let job = try prepareNativeToolJob(file: inputs[sourceFrame], recipe: recipe, library: inputs)
                    jobs.append(job.folder); _ = try run(job)
                    let direct = ImageAnalysisEngine(); _ = try await direct.open(job.folder.appendingPathComponent("process/result.fits"))
                    for y in 0..<3 { for x in 0..<4 {
                        let reference = try await direct.pixel(x: x, y: y).values
                        for channel in 0..<3 {
                            let sample = actual[(y * 4 + x) * 3 + channel]
                            try require(abs(Double(sample - reference[channel])) < tolerance, "original sequence/single worker \(tool.rawValue) pixel")
                            let raw = Double(value(sourceFrame, channel, x, y))
                            if tool == .mtf {
                                let expected = channel == 0 ? (-0.7 * raw) / (-0.4 * raw - 0.3) : raw
                                try require(abs(Double(sample) - expected) < tolerance, "independent MTF/channel arithmetic")
                            } else if tool == .linearStretch {
                                try require(abs(Double(sample) - max(0, (raw - 0.1) / 0.9)) < tolerance, "independent linear stretch arithmetic")
                            }
                        }
                    } }
                }
                let state = try recordSequenceResult(entry: location, source: location, output: output)
                try require(state.history.current == output && state.canUndo, "result history")
                let restored = try replaySequenceResult(location, redo: false)
                try require(restored.history.current == location, "result undo")
                _ = try replaySequenceResult(location, redo: true)
            }
            try require(try Data(contentsOf: process.appendingPathComponent(location.name)) == sourceIndex, "source index changed")
            for (i, path) in sourcePaths.enumerated() {
                try require(try Data(contentsOf: sequenceKeywordSource(path, under: root)) == sources[i], "source pixels/container changed")
            }
            var invalid = NativeToolRecipe(tool: .mtf, file: metadata); invalid.values["low"] = 0.8; invalid.values["high"] = 0.2
            var rejected = false
            do { _ = try applySequenceTool(location, recipe: invalid) } catch { rejected = true }
            try require(rejected, "invalid parameters accepted")
            if location == regularLocation {
                try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 0))
                let beforeFailure = try Data(contentsOf: process.appendingPathComponent(location.name))
                let runs = root.appendingPathComponent("SequenceRuns")
                let existingRuns = Set(try fm.contentsOfDirectory(atPath: runs.path))
                let framePaths = sourcePaths.filter { $0.split(separator: "/").count == 2 && !$0.hasSuffix(".seq") }
                try require(framePaths.count == 3, "regular fixture frame ownership list")
                let missing = try sequenceKeywordSource(framePaths[2], under: root)
                let withheld = scratch.appendingPathComponent("withheld.fits")
                try fm.moveItem(at: missing, to: withheld)
                do {
                    defer { try? fm.moveItem(at: withheld, to: missing) }
                    let valid = NativeToolRecipe(tool: .mtf, file: metadata)
                    rejected = false
                    do { _ = try applySequenceTool(location, recipe: valid) } catch { rejected = true }
                    try require(rejected, "partially readable sequence was published")
                    let failedRuns = Set(try fm.contentsOfDirectory(atPath: runs.path)).subtracting(existingRuns)
                    try require(failedRuns.count == 1, "failed run record missing")
                    if let name = failedRuns.first {
                        let failed = runs.appendingPathComponent(name), prefix = "r_" + name.replacingOccurrences(of: "-", with: "") + "_"
                        try require(fm.fileExists(atPath: failed.appendingPathComponent("stretch.json").path) &&
                            !fm.fileExists(atPath: failed.appendingPathComponent("output-sequence.json").path), "failed recipe/result manifest")
                        try require(try fm.contentsOfDirectory(atPath: process.path).allSatisfy({ !$0.hasPrefix(prefix) }), "partial outputs survived failure")
                    }
                    try require(try Data(contentsOf: process.appendingPathComponent(location.name)) == beforeFailure, "failure changed source index")
                }
            }
        }
    }
}
