// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func sequenceSelfTest() async throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw EngineError.failed("Sequence App check: " + message) }
        }
        guard let source = Bundle.main.url(forResource: "light", withExtension: "fits") else { throw EngineError.failed("Sequence fixture missing") }
        let reader = ImageAnalysisEngine()
        func pixels(_ url: URL) async throws -> [Float] {
            _ = try await reader.open(url)
            var values: [Float] = []
            for y in 0..<2 { for x in 0..<2 { values.append(try await reader.pixel(x: x, y: y).values[0]) } }
            return values
        }
        let light = try importFile(source)
        let temporary = documents.appendingPathComponent("sequence-high.fits")
        var bytes = try Data(contentsOf: source)
        // This bundled 2x2 FLOAT_IMG has one header block. Add a known offset
        // in FITS big-endian storage; expected pixels come from a separate read.
        for i in 0..<4 {
            let offset = 2880 + i * 4
            let bits = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var high = (Float(bitPattern: bits) + 0.4).bitPattern.bigEndian
            withUnsafeBytes(of: &high) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        try bytes.write(to: temporary)
        let high = try importFile(temporary)
        defer {
            try? FileManager.default.removeItem(at: light.url)
            try? FileManager.default.removeItem(at: high.url)
            try? FileManager.default.removeItem(at: temporary)
        }
        let baseline = try await pixels(light.url)
        let job = try createSequence(files: [light, light, high])
        defer { try? FileManager.default.removeItem(at: job.folder) }
        guard let location = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Created sequence missing") }
        let before = try inspectSequence(location)
        try require(before.info.count == 3 && before.info.included == 3 && before.info.width == 2 && before.info.layers == 1, "native metadata")
        let preview = try sequencePreview(location, index: 2, automatic: false)
        try require(preview.width == 2 && preview.height == 2 && preview.data.count == 16, "native full-frame preview")
        var options = BatchOptions()
        options.register = false; options.rejection = .none; options.normalization = .none; options.outputNormalization = false
        let all = try stackSequence(location, options: options, layer: 0)
        let allBytes = try Data(contentsOf: all)
        let allPixels = try await pixels(all)
        for i in 0..<4 { try require(abs(allPixels[i] - baseline[i] - 0.4 / 3) < 2e-5, "all-frame mean pixel") }
        let selected = SequenceSelection(included: [true, true, false], reference: 0)
        try editSequence(location, selection: selected)
        let subset = try stackSequence(location, options: options, layer: 0)
        let subsetPixels = try await pixels(subset)
        for i in 0..<4 { try require(abs(subsetPixels[i] - baseline[i]) < 2e-5, "excluded high frame still contributed") }
        try require(try Data(contentsOf: all) == allBytes, "restack changed previous result")
        // Recreate the Swift actor to exercise persisted history, not UI state.
        let reopened = SirilEngine()
        try await reopened.editSequence(location, undo: true)
        try require(try await reopened.inspectSequence(location).selection == before.selection, "cross-relaunch undo")
        try await reopened.editSequence(location, redo: true)
        try require(try await reopened.inspectSequence(location).selection == selected, "cross-relaunch redo")
        let statsCSV = try sequenceStatistics(location)
        try require(try String(contentsOf: statsCSV).contains("mean"), "original statistics CSV missing mean")
        let stats = try inspectSequence(location)
        for frame in stats.frames.prefix(2) {
            try require(frame.native.has_statistics != 0 && abs(frame.native.mean - Double(baseline.reduce(0, +) / 4)) < 2e-5, "native normalized statistics")
        }
        try require(try String(contentsOf: exportSequenceQuality(location, layer: 0)).contains("included,reference"), "quality CSV")
        try editSequence(location, undo: true)
        let branch = SequenceSelection(included: [true, false, true], reference: 2)
        try editSequence(location, selection: branch)
        try require(try sequenceHistory(location, snapshot: inspectSequence(location)).future.isEmpty, "new edit retained redo branch")
        let seq = job.folder.appendingPathComponent("process").appendingPathComponent(location.name)
        let edits = job.folder.appendingPathComponent("SequenceEdits")
        let history = edits.appendingPathComponent(location.name + ".json")
        let journal = edits.appendingPathComponent(location.name + ".journal.json")
        let original = try Data(contentsOf: seq), savedHistory = try Data(contentsOf: history)
        try JSONEncoder().encode(SequenceEditJournal(sequence: original, history: savedHistory)).write(to: journal, options: .atomic)
        try Data("interrupted upstream writer".utf8).write(to: seq, options: .atomic)
        try require(try inspectSequence(location).selection == branch && Data(contentsOf: seq) == original && Data(contentsOf: history) == savedHistory, "interrupted edit recovery")
        try require(!FileManager.default.fileExists(atPath: journal.path), "recovered journal retained")
        activeJobIDs.insert(location.job)
        var protected = false
        do { _ = try inspectSequence(location) } catch { protected = true }
        activeJobIDs.remove(location.job)
        try require(protected, "running task allowed sequence edit")
        var invalid = false
        do { _ = try sequencePreview(location, index: 3) } catch { invalid = true }
        try require(invalid, "invalid frame index accepted")
        let raw = job.folder.appendingPathComponent("process/light_00003.fit")
        let rawPixels = try await pixels(raw)
        for i in 0..<4 { try require(abs(rawPixels[i] - baseline[i] - 0.4) < 2e-5, "exclusion altered original frame") }
        guard let task = jobHistory().first(where: { $0.id == location.job }) else { throw EngineError.failed("Sequence task history missing") }
        try require(task.results.contains(all) && task.results.contains(subset), "restacks absent from task results")
        try trashJob(task)
        guard let deletion = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("Sequence task trash missing") }
        _ = try restoreTrash(deletion.id)
        try require(try inspectSequence(location).selection == branch && Data(contentsOf: all) == allBytes, "task restore lost selection or old result")
        try trashJob(task)
        try permanentlyDeleteTrash(Set(trashEntries().filter { $0.jobName == location.job }.map(\.id)))
        try require(!FileManager.default.fileExists(atPath: seq.path), "permanent task cleanup retained sequence")
    }

    func makeSequenceDemo() throws {
        var files: [FITSRecord] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file.url) } }
        for i in 0..<4 {
            guard let source = Bundle.main.url(forResource: "drizzle-bayer-\(i)", withExtension: "fits") else { throw EngineError.failed("Sequence quality fixture missing") }
            files.append(try importFile(source))
        }
        let job = try createSequence(files: files)
        guard let location = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Sequence demo missing") }
        try editSequence(location, selection: SequenceSelection(included: [true, true, true, true], reference: 0))
        var options = BatchOptions(); options.transform = .shift; options.minimumPairs = 4; options.maximumStars = 100
        try measureSequence(location, options: options, layer: 0)
        let measured = try inspectSequence(location)
        guard measured.frames.allSatisfy({ $0.native.fwhm > 0 && $0.native.stars > 0 }) else { throw EngineError.failed("Actual sequence quality missing") }
        try editSequence(location, selection: SequenceSelection(included: [true, true, true, false], reference: 0))
        try JSONEncoder().encode(location).write(to: documents.appendingPathComponent("simulator-sequence-location.json"), options: .atomic)
    }
}
