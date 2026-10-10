// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct TrashEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let deleted: Date
    let records: [FITSRecord]
    let jobName: String?
    var title: String { jobName == nil ? "\(records.count) 张图像" : "处理任务 \(jobName!.prefix(8))" }
}

struct StorageSummary: Sendable {
    var gallery: Int64 = 0
    var jobs: Int64 = 0
    var trash: Int64 = 0
    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

// Undo restores full FITS files, including their metadata. Display navigation starts a new chain.
struct WorkspaceHistory: Codable, Sendable {
    var current: UUID?
    var future: [UUID] = []
    mutating func open(_ id: UUID) { current = id; future = [] }
    mutating func undo(in records: [FITSRecord]) -> FITSRecord? {
        guard let file = records.first(where: { $0.id == current }),
              let parent = records.first(where: { $0.id == file.parentID }) else { return nil }
        future.append(file.id); current = parent.id
        return parent
    }
    mutating func redo(in records: [FITSRecord]) -> FITSRecord? {
        guard let id = future.last, let file = records.first(where: { $0.id == id && $0.parentID == current }) else { return nil }
        future.removeLast(); current = file.id
        return file
    }
}

extension SirilEngine {
    var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.resolvingSymlinksInPath() }
    private var trashRoot: URL { documents.appendingPathComponent("Trash", isDirectory: true) }

    // Reject traversal and symbolic links, including symlinks in parent directories.
    func owned(_ name: String, under root: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw EngineError.failed("无效的文件路径")
        }
        let url = root.appendingPathComponent(name).standardizedFileURL
        guard url.resolvingSymlinksInPath().path == url.path,
              url.deletingLastPathComponent().path == root.standardizedFileURL.path else {
            throw EngineError.failed("不能访问 App 文件夹以外的文件或符号链接")
        }
        return url
    }

    private func trashFolder(_ id: UUID) throws -> URL { try owned(id.uuidString, under: trashRoot) }
    private func manifest(_ entry: TrashEntry) throws {
        let folder = try trashFolder(entry.id)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("payload"), withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("entry.json"), options: .atomic)
    }
    func trashEntries() -> [TrashEntry] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let safe = try? trashFolder(id),
                  let value = try? JSONDecoder().decode(TrashEntry.self, from: Data(contentsOf: safe.appendingPathComponent("entry.json"))), value.id == id else { return nil }
            return value
        }.sorted { $0.deleted > $1.deleted }
    }

    func moveToTrash(ids: Set<UUID>) throws -> [FITSRecord] {
        let library = loadLibrary()
        let removed = library.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return library }
        let entry = TrashEntry(id: UUID(), deleted: Date(), records: removed, jobName: nil)
        let payload = try trashFolder(entry.id).appendingPathComponent("payload")
        // Validate the complete batch before moving anything.
        let sources = try removed.map { try owned($0.url.lastPathComponent, under: documents.appendingPathComponent("FITS")) }
        siril_release_workspace()
        try manifest(entry)
        var moved: [URL] = []
        do {
            for source in sources {
                try FileManager.default.moveItem(at: source, to: payload.appendingPathComponent(source.lastPathComponent))
                moved.append(source)
            }
            let remaining = library.filter { !ids.contains($0.id) }
            try saveLibrary(remaining)
            return remaining
        } catch {
            for source in moved { try? FileManager.default.moveItem(at: payload.appendingPathComponent(source.lastPathComponent), to: source) }
            // Leave a journal if rollback failed; startup recovery reconciles both locations.
            try? recoverTrashTransactions()
            throw error
        }
    }

    func trashJob(_ job: JobRecord) throws {
        guard !activeJobIDs.contains(job.id) else { throw EngineError.failed("任务正在处理，不能删除") }
        guard UUID(uuidString: job.id) != nil else { throw EngineError.failed("无效的任务目录") }
        let source = try owned(job.id, under: documents.appendingPathComponent("Jobs"))
        siril_release_workspace()
        let entry = TrashEntry(id: UUID(), deleted: Date(), records: [], jobName: job.id)
        try manifest(entry)
        do { try FileManager.default.moveItem(at: source, to: try trashFolder(entry.id).appendingPathComponent("payload").appendingPathComponent(job.id)) }
        catch { try? FileManager.default.removeItem(at: try trashFolder(entry.id)); throw error }
    }

    func restoreTrash(_ id: UUID) throws -> [FITSRecord] {
        guard let entry = trashEntries().first(where: { $0.id == id }) else { throw EngineError.failed("删除记录不存在") }
        let payload = try trashFolder(id).appendingPathComponent("payload")
        if let job = entry.jobName {
            let destination = try owned(job, under: documents.appendingPathComponent("Jobs"))
            try FileManager.default.moveItem(at: try owned(job, under: payload), to: destination)
        } else {
            for record in entry.records {
                let destination = try owned(record.url.lastPathComponent, under: documents.appendingPathComponent("FITS"))
                let source = try owned(record.url.lastPathComponent, under: payload)
                if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: destination) }
            }
        }
        // Journal is retained until the library index is durably updated.
        try recoverTrashTransactions()
        return loadLibrary()
    }

    func permanentlyDeleteTrash(_ ids: Set<UUID>) throws {
        siril_release_workspace()
        try recoverTrashTransactions()
        for entry in trashEntries() where ids.contains(entry.id) {
            try FileManager.default.removeItem(at: try trashFolder(entry.id))
        }
    }

    func recoverTrashTransactions() throws {
        let entries = trashEntries()
        guard !entries.isEmpty else { return }
        var records = (try? JSONDecoder().decode([FITSRecord].self, from: Data(contentsOf: documents.appendingPathComponent("library.json")))) ?? []
        var completed: [UUID] = []
        var updated: [TrashEntry] = []
        for entry in entries {
            let payload = (try? trashFolder(entry.id))?.appendingPathComponent("payload")
            if let job = entry.jobName {
                if let source = try? owned(job, under: documents.appendingPathComponent("Jobs")),
                   FileManager.default.fileExists(atPath: source.path) { completed.append(entry.id) }
                continue
            }
            var pending: [FITSRecord] = []
            for var record in entry.records {
                guard let original = try? owned(record.url.lastPathComponent, under: documents.appendingPathComponent("FITS")),
                      let payload, let trashed = try? owned(record.url.lastPathComponent, under: payload) else { pending.append(record); continue }
                if FileManager.default.fileExists(atPath: original.path) {
                    record.url = original
                    if !records.contains(where: { $0.id == record.id }) { records.append(record) }
                } else {
                    records.removeAll { $0.id == record.id }
                    if FileManager.default.fileExists(atPath: trashed.path) { pending.append(record) }
                }
            }
            if pending.isEmpty { completed.append(entry.id) }
            else if pending.count != entry.records.count {
                updated.append(TrashEntry(id: entry.id, deleted: entry.deleted, records: pending, jobName: nil))
            }
        }
        try saveLibrary(records)
        for entry in updated { try manifest(entry) }
        for id in completed { try FileManager.default.removeItem(at: try trashFolder(id)) }
    }

    func storageSummary() -> StorageSummary {
        StorageSummary(gallery: directoryBytes(documents.appendingPathComponent("FITS")),
                       jobs: directoryBytes(documents.appendingPathComponent("Jobs")), trash: directoryBytes(trashRoot))
    }
    func directoryBytes(_ folder: URL) -> Int64 {
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in iterator {
            if let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), value.isSymbolicLink != true, value.isRegularFile == true { bytes += Int64(value.fileSize ?? 0) }
        }
        return bytes
    }
    func loadWorkspace() -> WorkspaceHistory {
        (try? JSONDecoder().decode(WorkspaceHistory.self, from: Data(contentsOf: documents.appendingPathComponent("workspace.json")))) ?? WorkspaceHistory()
    }
    func saveWorkspace(_ history: WorkspaceHistory) throws {
        try JSONEncoder().encode(history).write(to: documents.appendingPathComponent("workspace.json"), options: .atomic)
    }
}

struct StorageManagementView: View {
    let engine: SirilEngine
    let onLibraryChanged: ([FITSRecord]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TrashEntry] = []
    @State private var summary = StorageSummary()
    @State private var busy = false
    @State private var error = ""
    @State private var permanent: Set<UUID> = []
    @State private var confirming = false
    var body: some View {
        NavigationStack {
            List {
                Section("存储空间") {
                    LabeledContent("图库", value: StorageSummary.format(summary.gallery))
                    LabeledContent("任务与中间文件", value: StorageSummary.format(summary.jobs))
                    LabeledContent("最近删除", value: StorageSummary.format(summary.trash))
                    Text("移入最近删除仍占空间。永久删除后才能释放空间；此操作不能撤回。任务副本请在处理记录中删除。").font(.caption)
                }
                Section("最近删除") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title)
                            Text(entry.deleted.formatted()).font(.caption).foregroundStyle(.secondary)
                            if !entry.records.isEmpty { Text(entry.records.map(\.displayName).joined(separator: "、")).font(.caption).lineLimit(3) }
                            HStack {
                                Button("恢复", systemImage: "arrow.uturn.backward") { perform { onLibraryChanged(try await engine.restoreTrash(entry.id)) } }
                                Spacer()
                                Button("永久删除", role: .destructive) { permanent = [entry.id]; confirming = true }
                            }.buttonStyle(.borderless)
                        }
                    }
                    if entries.isEmpty { Text("最近删除为空") }
                }
                if !entries.isEmpty {
                    Button("清空最近删除", role: .destructive) { permanent = Set(entries.map(\.id)); confirming = true }
                }
            }.disabled(busy)
            .navigationTitle("删除与存储")
            .toolbar { Button("完成") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("永久删除所选内容？文件将无法恢复。", isPresented: $confirming, titleVisibility: .visible) {
                Button("永久删除并释放空间", role: .destructive) { let ids = permanent; perform { try await engine.permanentlyDeleteTrash(ids) } }
            }
            .alert("文件操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
            .task {
                await reload()
                if ProcessInfo.processInfo.environment["SIRIL_STORAGE_VIEW_CHECK"] == "1", entries.count == 1, summary.trash > 0 {
                    let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-storage-ready.txt")
                    try? "PASS: storage view loaded recoverable files and storage sizes.\n".write(to: marker, atomically: true, encoding: .utf8)
                }
            }
        }
    }
    @MainActor private func reload() async { entries = await engine.trashEntries(); summary = await engine.storageSummary() }
    @MainActor private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription }; await reload() }
    }
}
