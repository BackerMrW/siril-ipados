// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func sequenceOutputStorageSelfTest(source: SequenceLocation, output: SequenceLocation, sibling: SequenceLocation, stacked: URL) throws {
        let fm = FileManager.default
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Independent sequence deletion: " + message) }
        }
        let process = try sequenceFolder(source), root = process.deletingLastPathComponent()
        let sourcePaths = try sequenceFilePaths(source), siblingPaths = try sequenceFilePaths(sibling)
        let untouched = try (sourcePaths + siblingPaths).map { path in (path, try Data(contentsOf: sequenceTrashPath(path, under: root))) }
        let stackBytes = try Data(contentsOf: stacked)
        let snapshot = try inspectSequence(output)
        var selection = snapshot.selection; selection.included[0] = false
        try editSequence(output, selection: selection)
        var backgroundHistory = SequenceBackgroundHistory(source: output)
        var settings = backgroundHistory.current; settings.degree = 2; backgroundHistory.record(settings)
        try saveSequenceBackgroundHistory(backgroundHistory)
        _ = try exportSequenceQuality(output, layer: 1)
        let paths = try sequenceFilePaths(output)
        try require(paths.filter { $0.contains("/drizztmp/") }.count == 3, "original helper omitted weights")
        let before = try paths.map { ($0, try Data(contentsOf: sequenceTrashPath($0, under: root))) }
        var rejected = false
        do { _ = try trashSequenceOutput(source) } catch { rejected = true }
        try require(rejected, "original input was deletable as output")
        activeJobIDs.insert(source.job); rejected = false
        do { _ = try trashSequenceOutput(output) } catch { rejected = true }
        activeJobIDs.remove(source.job)
        try require(rejected, "active task deletion allowed")

        // Exact upstream filenames include extension alternatives; avoid a
        // guessed .fits prefix scan. The restored index still opens this .fts.
        guard let regular = paths.first(where: { $0.hasSuffix(".fit") && !$0.contains("/drizztmp/") }) else { throw EngineError.failed("Missing regular deletion fixture") }
        let original = try sequenceTrashPath(regular, under: root)
        let alternate = original.deletingPathExtension().appendingPathExtension("fts")
        try fm.moveItem(at: original, to: alternate)
        let alternatePaths = try sequenceFilePaths(output)
        try require(alternatePaths.contains("process/" + alternate.lastPathComponent), "actual .fts was not resolved")
        try fm.moveItem(at: alternate, to: original)

        let id = try trashSequenceOutput(output)
        guard var entry = trashEntries().first(where: { $0.id == id }), let deletion = entry.sequenceOutput else { throw EngineError.failed("Independent trash manifest missing") }
        try require(!sequenceLocations(job: source.job).contains(output), "deleted output remained in browser")
        for path in deletion.paths { try require(!fm.fileExists(atPath: sequenceTrashPath(path, under: root).path), "deleted payload retained at source") }
        try require(deletion.paths.contains(where: { $0.hasSuffix(".background.json") }) && deletion.paths.contains(where: { $0.contains("-quality-") }), "companion histories omitted")
        let record = try sequenceOutputRecords(job: source.job).first { $0.location == output }
        try require(record?.available == false && record?.trashID == id, "deleted run claimed available")
        for (path, bytes) in untouched { try require(try Data(contentsOf: sequenceTrashPath(path, under: root)) == bytes, "other sequence changed") }
        try require(try Data(contentsOf: stacked) == stackBytes, "existing stack changed")

        // A crash before the deletion commit rolls the entire move back.
        entry.sequenceOutput?.committed = false; try manifest(entry)
        try recoverTrashTransactions()
        try require(!trashEntries().contains(where: { $0.id == id }), "rollback journal retained")
        for (path, bytes) in before { try require(try Data(contentsOf: sequenceTrashPath(path, under: root)) == bytes, "rollback bytes changed") }
        try require(try inspectSequence(output).selection == selection, "restored selection changed")
        try require(try sequenceBackgroundHistory(output) == backgroundHistory, "background history changed")
        try editSequence(output, undo: true)
        try require(try inspectSequence(output).selection == snapshot.selection, "restored selection undo failed")
        try editSequence(output, redo: true)

        let restoreID = try trashSequenceOutput(output)
        guard var journal = trashEntries().first(where: { $0.id == restoreID }), let first = journal.sequenceOutput?.paths.first else { throw EngineError.failed("Restore fixture missing") }
        let payload = try trashFolder(restoreID).appendingPathComponent("payload")
        // Conflicts must reject the whole restore without overwriting anything.
        let collision = try sequenceTrashPath(first, under: root)
        try fm.copyItem(at: sequenceTrashPath(first, under: payload), to: collision)
        rejected = false
        do { _ = try restoreTrash(restoreID) } catch { rejected = true }
        try require(rejected && trashEntries().contains(where: { $0.id == restoreID }), "restore conflict overwrote a file")
        try fm.removeItem(at: collision)
        journal.sequenceOutput?.restoring = true; try manifest(journal)
        try fm.moveItem(at: sequenceTrashPath(first, under: payload), to: collision)
        try recoverTrashTransactions()
        try require(!trashEntries().contains(where: { $0.id == restoreID }), "interrupted restore not completed")
        for (path, bytes) in before { try require(try Data(contentsOf: sequenceTrashPath(path, under: root)) == bytes, "restored FITS/weights differ") }

        // A symlink among planned weights must reject the complete deletion.
        guard let weight = paths.first(where: { $0.contains("/drizztmp/") }), let sourceFrame = sourcePaths.first(where: { $0.hasSuffix(".fit") }) else { throw EngineError.failed("Weight fixture missing") }
        let weightURL = try sequenceTrashPath(weight, under: root), weightBytes = try Data(contentsOf: weightURL)
        try fm.removeItem(at: weightURL)
        try fm.createSymbolicLink(at: weightURL, withDestinationURL: sequenceTrashPath(sourceFrame, under: root))
        rejected = false
        do { _ = try trashSequenceOutput(output) } catch { rejected = true }
        try require(rejected && fm.fileExists(atPath: process.appendingPathComponent(output.name).path), "symlink deletion touched files")
        try fm.removeItem(at: weightURL); try weightBytes.write(to: weightURL)
        rejected = false
        do { _ = try sequenceTrashPath("process/../library.json", under: root) } catch { rejected = true }
        try require(rejected, "relative traversal allowed")

        let finalID = try trashSequenceOutput(output)
        let size = storageSummary(); try require(size.trash > 0, "trash did not retain data")
        _ = try restoreTrash(finalID)
        try require(try inspectSequence(output).info.drizzle != 0, "undo did not restore native drizzle sequence")
        let disposable = try trashSequenceOutput(sibling)
        let withTrash = storageSummary()
        try permanentlyDeleteTrash([disposable])
        try require(storageSummary().trash < withTrash.trash && !sequenceLocations(job: source.job).contains(sibling), "permanent cleanup did not release selected output")
        for (path, bytes) in before { try require(try Data(contentsOf: sequenceTrashPath(path, under: root)) == bytes, "permanent cleanup damaged retained output") }
        for path in sourcePaths { try require(fm.fileExists(atPath: sequenceTrashPath(path, under: root).path), "permanent cleanup removed inputs") }
        try require(try Data(contentsOf: stacked) == stackBytes, "permanent cleanup removed stack")
    }
}
