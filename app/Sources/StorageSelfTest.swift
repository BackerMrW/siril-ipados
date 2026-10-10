// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func storageSelfTest(baseline: [FITSRecord], source: URL, editedSource: URL) throws {
        let manager = FileManager.default
        let first = try importFile(source, role: .lights)
        var second = try importFile(editedSource, role: .results)
        second.parentID = first.id
        try saveLibrary(baseline + [first, second])
        let initial = storageSummary()
        var history = WorkspaceHistory()
        history.open(second.id)
        guard history.undo(in: loadLibrary())?.url == first.url,
              history.redo(in: loadLibrary())?.url == second.url else { throw EngineError.failed("FITS undo/redo failed") }
        try saveWorkspace(history)
        guard loadWorkspace().current == second.id else { throw EngineError.failed("Persistent undo history failed") }
        _ = history.undo(in: loadLibrary())
        history.open(first.id)
        guard history.future.isEmpty else { throw EngineError.failed("Undo branch did not clear redo") }

        let remaining = try moveToTrash(ids: [first.id, second.id])
        guard remaining.count == baseline.count, !manager.fileExists(atPath: first.url.path),
              !manager.fileExists(atPath: second.url.path), manager.fileExists(atPath: source.path),
              let entry = trashEntries().first, entry.records.count == 2 else { throw EngineError.failed("Batch delete/source preservation failed") }
        // Simulate interrupted batch restoration after only one payload has moved.
        let stored = documents.appendingPathComponent("Trash").appendingPathComponent(entry.id.uuidString)
            .appendingPathComponent("payload").appendingPathComponent(first.url.lastPathComponent)
        try manager.moveItem(at: stored, to: first.url)
        try recoverTrashTransactions()
        guard loadLibrary().contains(where: { $0.id == first.id }),
              trashEntries().first?.records.count == 1 else { throw EngineError.failed("Interrupted restore recovery failed") }
        let restored = try restoreTrash(entry.id)
        guard restored.count == baseline.count + 2,
              restored.first(where: { $0.id == second.id })?.parentID == first.id,
              restored.first(where: { $0.id == second.id })?.role == .results,
              trashEntries().isEmpty else { throw EngineError.failed("Trash restore metadata failed") }
        _ = try moveToTrash(ids: [first.id, second.id])
        try permanentlyDeleteTrash(Set(trashEntries().map(\.id)))
        let cleaned = storageSummary()
        guard cleaned.gallery < initial.gallery, cleaned.trash == 0,
              loadLibrary().count == baseline.count else { throw EngineError.failed("Permanent deletion did not release gallery storage") }

        let job = try prepareJob(files: [baseline[0]], script: "# storage fixture\n")
        guard let task = jobHistory().first(where: { $0.id == job.folder.lastPathComponent }), task.bytes > 0 else {
            throw EngineError.failed("Task size failed")
        }
        try trashJob(task)
        guard !manager.fileExists(atPath: job.folder.path), let deletedJob = trashEntries().first,
              manager.fileExists(atPath: baseline[0].url.path) else { throw EngineError.failed("Job deletion affected gallery") }
        _ = try restoreTrash(deletedJob.id)
        guard manager.fileExists(atPath: job.folder.appendingPathComponent("lights/frame_00001.fits").path) else {
            throw EngineError.failed("Job input restoration failed")
        }
        try trashJob(task)
        try permanentlyDeleteTrash(Set(trashEntries().map(\.id)))
        guard !manager.fileExists(atPath: job.folder.path), storageSummary().trash == 0 else { throw EngineError.failed("Job cleanup failed") }

        // A symlink inside FITS must never cause deletion of the external source.
        let linked = try importFile(source)
        try manager.removeItem(at: linked.url)
        try manager.createSymbolicLink(at: linked.url, withDestinationURL: source)
        try saveLibrary(baseline + [linked])
        var rejected = false
        do { _ = try moveToTrash(ids: [linked.id]) } catch { rejected = true }
        guard rejected, manager.fileExists(atPath: source.path) else { throw EngineError.failed("Unsafe symlink deletion was allowed") }
        try manager.removeItem(at: linked.url)
        try saveLibrary(baseline)
        try saveWorkspace(WorkspaceHistory())
    }
}
