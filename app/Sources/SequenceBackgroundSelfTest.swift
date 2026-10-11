// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func sequenceBackgroundSelfTest() async throws {
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw EngineError.failed("Sequence background App check: " + message) }
        }
        guard let fixture = Bundle.main.url(forResource: "gradient", withExtension: "fits") else {
            throw EngineError.failed("Sequence background fixture missing")
        }
        let source = try importFile(fixture)
        let job = try createSequence(files: [source, source, source])
        defer { try? FileManager.default.removeItem(at: source.url); try? FileManager.default.removeItem(at: job.folder) }
        guard let location = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Sequence background source missing") }
        let original = try inspectSequence(location)
        let selection = SequenceSelection(included: [true, false, true], reference: 2)
        try editSequence(location, selection: selection)
        let process = job.folder.appendingPathComponent("process")
        let sourceIndex = process.appendingPathComponent(location.name)
        let sourceBytes = try Data(contentsOf: sourceIndex)
        let originalPaths = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil).filter { ["fit", "fits", "fts"].contains($0.pathExtension) }
        try require(originalPaths.count == 3, "source preservation test did not find three FITS frames")
        let originalBytes = try originalPaths.map { try Data(contentsOf: $0) }
        var settings = BackgroundSettings.sequenceDefaults
        settings.perLine = 10; settings.tolerance = 3; settings.dither = false
        let output = try applySequenceBackground(location, settings: settings)
        let generated = try inspectSequence(output)
        try require(generated.info.count == 2 && generated.info.reference == 1 && generated.info.layers == 1, "selection count and explicit reference mapping")
        try require(generated.frames.map { $0.native.file_number } == [original.frames[0].native.file_number, original.frames[2].native.file_number], "original file number mapping")
        try require(try Data(contentsOf: sourceIndex) == sourceBytes && originalPaths.map { try Data(contentsOf: $0) } == originalBytes, "source FITS/index changed")
        let preview = BackgroundEngine()
        try await openSequenceBackground(location, index: 0, into: preview)
        try await preview.computeSequence(settings)
        let previewURL = job.folder.appendingPathComponent("sequence-preview.fits")
        try await preview.exportSequencePreview(previewURL)
        let reader = ImageAnalysisEngine(), compare = ImageAnalysisEngine()
        let outputStem = output.base + String(format: "%05d", generated.frames[0].native.file_number)
        guard let firstOutput = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil)
            .first(where: { $0.deletingPathExtension().lastPathComponent == outputStem && ["fit", "fits", "fts"].contains($0.pathExtension) }) else {
            throw EngineError.failed("Corrected frame file missing")
        }
        _ = try await reader.open(firstOutput); _ = try await compare.open(previewURL)
        for y in stride(from: 0, to: 256, by: 17) { for x in stride(from: 0, to: 256, by: 17) {
            let actual = try await reader.pixel(x: x, y: y).values[0]
            let expected = try await compare.pixel(x: x, y: y).values[0]
            try require(actual.isFinite && abs(actual - expected) < 1e-6, "sequence preview differs from real output pixels")
        } }
        let left = try await reader.pixel(x: 32, y: 64).values[0]
        let right = try await reader.pixel(x: 224, y: 64).values[0]
        try require(abs(left - right) < 0.02, "gradient not removed")
        let savedOutput = try Data(contentsOf: firstOutput)
        let again = try applySequenceBackground(location, settings: settings)
        try require(try Data(contentsOf: firstOutput) == savedOutput && again != output, "repeat overwrote an earlier output")
        try require(try sequenceBackgroundRuns(location).count == 2 && sequenceBackgroundRuns(location).allSatisfy { $0.state.state == "已完成" && $0.output != nil }, "saved successful run browser")
        guard let latestRun = try sequenceBackgroundRuns(location).first else { throw EngineError.failed("Background run missing") }
        try writeJobState(latestRun.folder, state: "运行中", message: "simulated interrupted final state write")
        let restarted = SirilEngine()
        let interrupted = try await restarted.sequenceBackgroundRuns(location).first
        try require(interrupted?.state.state == "处理被中断" && interrupted?.output == nil, "interrupted run falsely advertised as active or complete")
        try require(try Data(contentsOf: firstOutput) == savedOutput, "interrupted-state read changed earlier FITS")
        try writeJobState(latestRun.folder, state: "已完成", message: "序列背景提取")
        var history = try sequenceBackgroundHistory(location)
        history.record(settings); settings.correction = 1; history.record(settings)
        try saveSequenceBackgroundHistory(history)
        let reopened = SirilEngine()
        var restored = try await reopened.sequenceBackgroundHistory(location)
        restored.undo()
        try require(restored.current.correction == 0, "persisted parameter undo")
        try await reopened.saveSequenceBackgroundHistory(restored)
        restored = try sequenceBackgroundHistory(location); restored.redo()
        try require(restored.current.correction == 1, "persisted parameter redo")
        restored.undo(); var branch = restored.current; branch.degree = 2; restored.record(branch)
        try require(restored.future.isEmpty, "parameter redo branch not cleared")
        for i in 0..<45 { branch.border = Double(i); restored.record(branch) }
        try require(restored.past.count == 30, "parameter history limit")
        try saveSequenceBackgroundHistory(restored)
        // Original sequence worker permits skipped bad frames. The Swift layer
        // must reject a partial result rather than advertise full success.
        let zeroURL = job.folder.appendingPathComponent("zero.fits")
        var error = [CChar](repeating: 0, count: 512); let capacity = error.count
        guard let zero = source.url.path.withCString({ siril_image_read($0, &error, capacity) }),
              let subtract = source.url.path.withCString({ siril_image_read($0, &error, capacity) }) else { throw EngineError.failed("Cannot build zero test frame") }
        let subtracted = siril_image_subtract(zero, subtract)
        let written = zeroURL.path.withCString { siril_image_write(zero, $0) }
        siril_image_free(zero); siril_image_free(subtract)
        try require(subtracted != 0 && written != 0, "zero frame export")
        let empty = try importFile(zeroURL)
        defer { try? FileManager.default.removeItem(at: empty.url) }
        let badJob = try createSequence(files: [source, empty, source])
        defer { try? FileManager.default.removeItem(at: badJob.folder) }
        guard let bad = sequenceLocations(job: badJob.folder.lastPathComponent).first else { throw EngineError.failed("Partial background test sequence missing") }
        let badSourceBytes = try Data(contentsOf: badJob.folder.appendingPathComponent("process").appendingPathComponent(bad.name))
        var rejected = false
        settings.correction = 0
        do { _ = try applySequenceBackground(bad, settings: settings) } catch { rejected = true }
        try require(rejected, "partial processing claimed success")
        let runs = try FileManager.default.contentsOfDirectory(at: badJob.folder.appendingPathComponent("SequenceRuns"), includingPropertiesForKeys: nil)
        try require(runs.count == 1, "failed run evidence missing")
        let failed = try JSONDecoder().decode(JobState.self, from: Data(contentsOf: runs[0].appendingPathComponent("job.json")))
        try require(try sequenceBackgroundRuns(bad).first?.state.state == "输出验证失败" && sequenceBackgroundRuns(bad).first?.output == nil, "failed run browser incorrectly exposed successful output")
        try require(failed.state == "输出验证失败" && FileManager.default.fileExists(atPath: runs[0].appendingPathComponent("background.json").path), "failed run state/recipe missing")
        try require(try Data(contentsOf: badJob.folder.appendingPathComponent("process").appendingPathComponent(bad.name)) == badSourceBytes, "failed run changed source sequence")
        try require(try inspectSequence(location).selection == selection, "background changed source selection")
        try editSequence(location, undo: true)
        try require(try inspectSequence(location).selection == original.selection, "background broke sequence selection undo")
        try editSequence(location, redo: true)
        // Reversible cleanup of a dependent background-output chain.
        let child = try applySequenceBackground(output, settings: settings)
        rejected = false
        do { _ = try trashSequenceOutput(output) } catch { rejected = true }
        try require(rejected, "dependent chain input deleted")
        let childTrash = try trashSequenceOutput(child)
        rejected = false
        do { _ = try trashSequenceOutput(output) } catch { rejected = true }
        try require(rejected, "recoverable dependent lost its input")
        try permanentlyDeleteTrash([childTrash])
        let outputTrash = try trashSequenceOutput(output)
        try require(try sequenceBackgroundRuns(location).first(where: { $0.folder.lastPathComponent != latestRun.folder.lastPathComponent })?.output == nil, "deleted background output still advertised")
        _ = try restoreTrash(outputTrash)
        try require(try Data(contentsOf: firstOutput) == savedOutput, "independent background restoration changed pixels")
        // Delete/restore/permanent cleanup moves every correction and its history.
        guard let task = jobHistory().first(where: { $0.id == location.job }) else { throw EngineError.failed("Background task missing") }
        try trashJob(task)
        guard let deletion = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("Background task trash missing") }
        _ = try restoreTrash(deletion.id)
        try require(try inspectSequence(output).info.count == 2 && Data(contentsOf: firstOutput) == savedOutput && sequenceBackgroundHistory(location) == restored, "task restore lost corrected FITS or parameter history")
        try trashJob(task)
        guard let permanent = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("Background task permanent trash missing") }
        try permanentlyDeleteTrash([permanent.id])
        try require(!FileManager.default.fileExists(atPath: job.folder.path), "permanent task cleanup retained output files")
    }
}
