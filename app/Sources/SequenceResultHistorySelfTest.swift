// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func sequenceResultHistorySelfTest(source: SequenceLocation, registered: SequenceLocation, sibling: SequenceLocation, drizzle: SequenceLocation) async throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw EngineError.failed("Sequence result history: " + message) }
        }
        func pixels(_ location: SequenceLocation) throws -> (Int, Int, [Float]) {
            let folder = try sequenceFolder(location)
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            guard let image = folder.path.withCString({ directory in location.name.withCString { siril_sequence_frame(directory, $0, 0, &error, capacity) } }) else { throw EngineError.failed(String(cString: error)) }
            defer { siril_image_free(image) }
            var info = SirilImageInfo()
            try require(siril_image_info(image, &info) != 0, "original image info failed")
            var values = [Float](repeating: 0, count: 3)
            try require(siril_image_pixel(image, 64, 64, &values) != 0, "original pixel read failed")
            return (Int(info.width), Int(info.channels), Array(values.prefix(Int(info.channels))))
        }
        let root = try sequenceFolder(source).deletingLastPathComponent()
        let historyURL = root.appendingPathComponent("SequenceResults").appendingPathComponent(source.name + ".json")
        let original = try pixels(source), rgb = try pixels(drizzle)
        let initial = try sequenceResultStatus(source)
        try require(initial.history.current == source && !initial.canUndo && !initial.canRedo, "initial source history")
        let first = try recordSequenceResult(entry: source, source: source, output: registered)
        try require(first.history.current == registered && first.history.past == [source] && first.canUndo && !first.canRedo, "registration result was not recorded")
        _ = try recordSequenceResult(entry: source, source: source, output: registered)
        let reopened = SirilEngine()
        try require(try await reopened.sequenceResultStatus(source).history == first.history, "reopen or duplicate completion changed history")
        _ = try recordSequenceResult(entry: source, source: source, output: drizzle)
        let undo = try replaySequenceResult(source, redo: false), undoPixels = try pixels(undo.history.current)
        try require(undo.history.current == source && undoPixels.0 == 256 && undoPixels.1 == 1 && undoPixels.2 == original.2 && undo.canRedo, "undo did not restore original mono size/pixels")
        let redo = try await reopened.replaySequenceResult(source, redo: true), redoPixels = try pixels(redo.history.current)
        try require(redo.history.current == drizzle && redoPixels.0 == 512 && redoPixels.1 == 3 && redoPixels.2 == rgb.2, "redo did not restore actual RGB drizzle size/pixels")
        let before = try sequenceFilePaths(drizzle).map { (path: $0, bytes: try Data(contentsOf: sequenceTrashPath($0, under: root))) }
        _ = try replaySequenceResult(source, redo: false)
        let branch = try recordSequenceResult(entry: source, source: source, output: sibling)
        try require(branch.history.past == [source] && branch.history.current == sibling && branch.history.future.isEmpty, "new source processing retained the redo branch")
        let repeated = try recordSequenceResult(entry: source, source: source, output: registered)
        try require(repeated.history.past == [source], "repeated modal application created a false sibling-to-sibling chain")
        try require(sequenceLocations(job: source.job).contains(drizzle), "branch clearing removed old result files")
        for item in before { try require(try Data(contentsOf: sequenceTrashPath(item.path, under: root)) == item.bytes, "undo/redo changed FITS, index or weights") }

        // Original background worker produces a real second processing step.
        var settings = BackgroundSettings.sequenceDefaults
        settings.perLine = 10; settings.tolerance = 3; settings.dither = false
        let corrected = try applySequenceBackground(drizzle, settings: settings)
        let chain = try recordSequenceResult(entry: source, source: drizzle, output: corrected)
        let correctedPixels = try pixels(corrected)
        let correctedInfo = try inspectSequence(corrected)
        try require(chain.history.past == [source, drizzle] && correctedPixels.1 == 3 && correctedInfo.info.drizzle == 0, "background ancestry or ordinary output flags")
        let both = try replaySequenceResult(source, redo: false)
        try require(both.history.current == drizzle && both.canUndo && both.canRedo, "chain undo/redo did not retain both directions")
        _ = try replaySequenceResult(source, redo: true)
        let removed = try trashSequenceOutput(corrected)
        let fallback = try await reopened.sequenceResultStatus(source)
        try require(fallback.history.current == drizzle && fallback.history.future.last == corrected && !fallback.canRedo && !fallback.note.isEmpty, "deleted current result did not fall back with a recoverable redo step")
        _ = try restoreTrash(removed)
        let recovered = try sequenceResultStatus(source)
        try require(recovered.canRedo, "restored output did not reactivate redo")
        let replayed = try replaySequenceResult(source, redo: true), replayedPixels = try pixels(replayed.history.current)
        try require(replayedPixels.2 == correctedPixels.2 && replayedPixels.0 == correctedPixels.0, "restored background redo changed pixels")
        let fromOutput = try sequenceResultStatus(corrected)
        try require(fromOutput.history.past == [source, drizzle] && fromOutput.canUndo, "opening an existing output did not reconstruct its original ancestry")

        // Saved cursor changes must fail without touching files or the branch.
        let goodHistory = try Data(contentsOf: historyURL)
        activeJobIDs.insert(source.job)
        var rejected = false
        do { _ = try replaySequenceResult(source, redo: false) } catch { rejected = true }
        activeJobIDs.remove(source.job)
        let afterActive = try Data(contentsOf: historyURL)
        try require(rejected && afterActive == goodHistory, "active task history changed")
        let foreign = SequenceLocation(job: UUID().uuidString, name: source.name)
        rejected = false
        do { _ = try selectSequenceResult(entry: source, target: foreign) } catch { rejected = true }
        try require(rejected, "cross-job result accepted")
        var damaged = chain.history
        damaged.current = SequenceLocation(job: source.job, name: "../escape.seq")
        try JSONEncoder().encode(damaged).write(to: historyURL, options: .atomic)
        rejected = false
        do { _ = try sequenceResultStatus(source) } catch { rejected = true }
        try require(rejected, "saved traversal accepted")
        try goodHistory.write(to: historyURL, options: .atomic)
        guard let run = try sequenceOutputRecords(job: source.job).first(where: { $0.location == registered }) else { throw EngineError.failed("Missing registered output provenance") }
        try writeJobState(run.folder, state: "输出验证失败", message: "simulated incomplete output")
        rejected = false
        do { _ = try recordSequenceResult(entry: source, source: source, output: registered) } catch { rejected = true }
        let afterFailure = try Data(contentsOf: historyURL)
        try require(rejected && afterFailure == goodHistory, "failed output entered history")
        try writeJobState(run.folder, state: "已完成", message: run.state.message)
        _ = try selectSequenceResult(entry: source, target: source)
        let cleanup = try trashSequenceOutput(corrected)
        try permanentlyDeleteTrash([cleanup])
        for item in before { try require(try Data(contentsOf: sequenceTrashPath(item.path, under: root)) == item.bytes, "permanent child cleanup changed parent FITS/weights") }
    }
}
