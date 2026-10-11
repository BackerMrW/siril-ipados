// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct SequenceOutputTrash: Codable, Sendable {
    let location: SequenceLocation
    let paths: [String] // Relative to the original job, not arbitrary filesystem paths.
    var committed = false
    var restoring = false
}
struct SequenceOutputRecord: Identifiable, Sendable {
    let location: SequenceLocation
    let source: SequenceLocation?
    let folder: URL
    let state: JobState
    let available: Bool
    let trashID: UUID?
    var id: String { location.id }
    var status: String { available ? state.state : trashID == nil ? "输出已清理或未生成" : "输出在最近删除中" }
}

extension SirilEngine {
    func sequenceOutputRecords(job: String) throws -> [SequenceOutputRecord] {
        guard UUID(uuidString: job) != nil, !activeJobIDs.contains(job) else { throw EngineError.failed("任务正在处理或路径无效。") }
        let root = try owned(job, under: documents.appendingPathComponent("Jobs"))
        let process = try owned("process", under: root), runs = try owned("SequenceRuns", under: root)
        let entries = trashEntries()
        guard FileManager.default.fileExists(atPath: runs.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil).compactMap { candidate in
            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                  let folder = try? owned(candidate.lastPathComponent, under: runs) else { return nil }
            let recipe = try? JSONDecoder().decode(SequenceBackgroundRecipe.self, from: Data(contentsOf: owned("background.json", under: folder)))
            let saved = try? JSONDecoder().decode(SequenceLocation.self, from: Data(contentsOf: owned("output-sequence.json", under: folder)))
            guard let output = saved ?? recipe?.output, output.job == job,
                  let path = try? owned(output.name, under: process), output.name.hasSuffix(".seq") else { return nil }
            // All generated outputs use a UUID prefix. Never offer deletion of
            // imported/source sequences based only on untrusted saved metadata.
            let token = candidate.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
            guard output.name.hasPrefix("r_" + token) || output.name.hasPrefix("b_" + token) else { return nil }
            var source = recipe?.source ?? (try? JSONDecoder().decode(SequenceLocation.self, from: Data(contentsOf: owned("source-location.json", under: folder))))
            if source == nil, let snapshot = try? String(contentsOf: owned("source.seq", under: folder), encoding: .utf8),
               let line = snapshot.split(separator: "\n").first(where: { $0.hasPrefix("S '") }),
               let end = line.range(of: "' ", options: .backwards) {
                source = SequenceLocation(job: job, name: String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound]) + ".seq")
            }
            if let value = source { guard value.job == job, (try? owned(value.name, under: process)) != nil else { return nil } }
            var state = (try? JSONDecoder().decode(JobState.self, from: Data(contentsOf: owned("job.json", under: folder)))) ??
                JobState(created: .distantPast, updated: .distantPast, state: "旧版本记录", inputCount: 0, message: "")
            if state.state == "运行中" { state.state = "处理被中断" }
            return SequenceOutputRecord(location: output, source: source, folder: folder, state: state,
                available: FileManager.default.fileExists(atPath: path.path),
                trashID: entries.first(where: { $0.sequenceOutput?.location == output })?.id)
        }.sorted { $0.state.created > $1.state.created }
    }

    func sequenceFilePaths(_ location: SequenceLocation) throws -> [String] {
        let process = try sequenceFolder(location)
        var error = [CChar](repeating: 0, count: 512)
        let errorSize = error.count
        let size = process.path.withCString { directory in location.name.withCString { siril_sequence_files(directory, $0, nil, 0, &error, errorSize) } }
        guard size > 0 else { throw EngineError.failed(String(cString: error)) }
        var output = [CChar](repeating: 0, count: Int(size))
        let outputSize = output.count
        let count = process.path.withCString { directory in location.name.withCString { siril_sequence_files(directory, $0, &output, outputSize, &error, errorSize) } }
        guard count == size else { throw EngineError.failed(String(cString: error)) }
        return String(cString: output).split(separator: "\n").map { "process/" + $0 }
    }

    // Components pass the same symlink/traversal checks as gallery deletion.
    func sequenceTrashPath(_ relative: String, under root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count), parts[0] == "process" || parts[0] == "SequenceEdits",
              parts.count == 2 || (parts[0] == "process" && ["drizztmp", "cache"].contains(parts[1])) else {
            throw EngineError.failed("无效的序列删除文件路径。")
        }
        var url = root
        for part in parts { url = try owned(part, under: url) }
        return url
    }

    @discardableResult func trashSequenceOutput(_ location: SequenceLocation) throws -> UUID {
        try recoverTrashTransactions()
        let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
        let outputs = try sequenceOutputRecords(job: location.job)
        guard outputs.contains(where: { $0.location == location && $0.available }) else { throw EngineError.failed("只能独立删除由本 App 生成且仍存在的输出序列。") }
        // Check saved provenance and legacy UUID-name chains, including outputs
        // currently in trash: restoring those must not leave missing inputs.
        if let dependent = outputs.first(where: { $0.location != location && ($0.available || $0.trashID != nil) &&
            ($0.source == location || $0.location.name.hasSuffix("_" + location.name)) }) {
            throw EngineError.failed("后续输出 \(dependent.location.name) 仍依赖此序列。请先永久清理后续输出，或保留此输入。")
        }
        try recoverSequenceEdit(location)
        var paths = try sequenceFilePaths(location)
        let edits = try owned("SequenceEdits", under: root)
        if FileManager.default.fileExists(atPath: edits.path) {
            for url in try FileManager.default.contentsOfDirectory(at: edits, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(location.name + ".") || url.lastPathComponent.hasPrefix(location.name + "-quality-") {
                _ = try owned(url.lastPathComponent, under: edits)
                paths.append("SequenceEdits/" + url.lastPathComponent)
            }
        }
        paths = Array(Set(paths)).sorted()
        for path in paths {
            let url = try sequenceTrashPath(path, under: root)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw EngineError.failed("输出包含缺失或非普通文件，不能独立删除。") }
        }
        let id = UUID()
        var entry = TrashEntry(id: id, deleted: Date(), records: [], jobName: nil,
            sequenceOutput: SequenceOutputTrash(location: location, paths: paths))
        siril_release_workspace()
        try manifest(entry)
        let payload = try trashFolder(id).appendingPathComponent("payload")
        do {
            for path in paths {
                let destination = try sequenceTrashPath(path, under: payload)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: sequenceTrashPath(path, under: root), to: destination)
            }
            entry.sequenceOutput?.committed = true
            try manifest(entry)
            return id
        } catch {
            try recoverSequenceTrash(entry) // Uncommitted moves roll back, also after a crash.
            throw error
        }
    }

    func restoreSequenceTrash(_ entry: TrashEntry) throws {
        guard var output = entry.sequenceOutput else { return }
        let root = try owned(output.location.job, under: documents.appendingPathComponent("Jobs"))
        guard FileManager.default.fileExists(atPath: root.path), !activeJobIDs.contains(output.location.job) else {
            throw EngineError.failed("请先恢复所属任务，并等待任务处理结束。")
        }
        // Preflight the whole batch before starting; never overwrite new files.
        let payload = try trashFolder(entry.id).appendingPathComponent("payload")
        for path in output.paths {
            guard !FileManager.default.fileExists(atPath: try sequenceTrashPath(path, under: root).path),
                  FileManager.default.fileExists(atPath: try sequenceTrashPath(path, under: payload).path) else {
                throw EngineError.failed("恢复位置已存在同名文件，或删除文件缺失；原文件未覆盖。")
            }
        }
        var journal = entry; output.restoring = true; journal.sequenceOutput = output
        siril_release_workspace()
        try manifest(journal)
        try recoverSequenceTrash(journal)
    }

    func recoverSequenceTrash(_ entry: TrashEntry) throws {
        guard let output = entry.sequenceOutput, !output.committed || output.restoring else { return }
        let root = try owned(output.location.job, under: documents.appendingPathComponent("Jobs"))
        guard FileManager.default.fileExists(atPath: root.path), !activeJobIDs.contains(output.location.job) else {
            throw EngineError.failed("序列恢复尚未完成，请先恢复所属任务或等待处理结束。")
        }
        let payload = try trashFolder(entry.id).appendingPathComponent("payload")
        for path in output.paths {
            let source = try sequenceTrashPath(path, under: payload), target = try sequenceTrashPath(path, under: root)
            if FileManager.default.fileExists(atPath: source.path) {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw EngineError.failed("恢复遇到同名文件；保留两份文件等待处理。") }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: target)
            } else if !FileManager.default.fileExists(atPath: target.path) { throw EngineError.failed("序列恢复文件缺失。") }
        }
        try FileManager.default.removeItem(at: trashFolder(entry.id))
    }
}

struct SequenceOutputManagementView: View {
    let job: String
    let engine: SirilEngine
    let onPreview: (URL) -> Void
    @State private var outputs: [SequenceOutputRecord] = []
    @State private var deleting: SequenceOutputRecord?
    @State private var confirmation = false
    @State private var busy = false
    @State private var error = ""
    @State private var lastDeleted: UUID?
    var body: some View {
        List {
            Section {
                Text("独立清理配准、Drizzle 和背景校正输出。输入、其他输出及已保存的叠加结果会保留。移入最近删除可以撤销；永久删除才释放空间。")
                if let id = lastDeleted {
                    Button("撤销刚才的删除", systemImage: "arrow.uturn.backward") { perform { _ = try await engine.restoreTrash(id); lastDeleted = nil } }
                }
                NavigationLink("最近删除与空间清理") { StorageManagementView(engine: engine) { _ in } }
            }
            ForEach(outputs) { output in
                Section {
                    Text(output.state.message.isEmpty ? "处理输出" : output.state.message).font(.headline)
                    Text(output.location.name).font(.caption).lineLimit(2).textSelection(.enabled)
                    Text("\(output.state.created.formatted()) · \(output.status)").font(.caption)
                    if let source = output.source { Text("输入：\(source.name)").font(.caption).textSelection(.enabled) }
                    if output.available {
                        NavigationLink("打开此输出") { SequenceWorkspace(location: output.location, engine: engine, onPreview: onPreview) }
                        Button("删除此输出", role: .destructive) { deleting = output; confirmation = true }
                    } else if let id = output.trashID {
                        Button("恢复此输出", systemImage: "arrow.uturn.backward") { perform { _ = try await engine.restoreTrash(id); if lastDeleted == id { lastDeleted = nil } } }
                    }
                    if !output.state.message.isEmpty { Text(output.state.message).font(.caption) }
                    ShareLink("导出处理日志", item: output.folder.appendingPathComponent("processing.log"))
                }
            }
            if outputs.isEmpty { Text("此任务还没有可管理的独立输出。") }
        }
        .disabled(busy).navigationTitle("输出删除与恢复")
        .navigationBarBackButtonHidden(busy).interactiveDismissDisabled(busy)
        .onAppear { Task { await reload() } }
        .confirmationDialog("删除此输出序列及其权重和编辑历史？可以恢复。", isPresented: $confirmation, titleVisibility: .visible) {
            Button("移入最近删除", role: .destructive) {
                guard let output = deleting else { return }
                perform { lastDeleted = try await engine.trashSequenceOutput(output.location) }
            }
        }
        .alert("文件操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
    }
    @MainActor private func reload() async {
        do {
            outputs = try await engine.sequenceOutputRecords(job: job)
            if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] == "outputs", outputs.count >= 2 {
                if outputs.allSatisfy({ $0.available }), let candidate = outputs.last {
                    lastDeleted = try await engine.trashSequenceOutput(candidate.location)
                    outputs = try await engine.sequenceOutputRecords(job: job)
                }
                guard let live = outputs.first(where: { $0.available }), outputs.contains(where: { $0.trashID != nil }),
                      try await engine.inspectSequence(live.location).info.drizzle != 0,
                      try await engine.sequenceFilePaths(live.location).contains(where: { $0.contains("/drizztmp/") }) else { return }
                let root = await engine.documents
                try "PASS: output manager loaded real live Drizzle output/weights, recoverable independent output, delete/restore/undo and storage controls.\n"
                    .write(to: root.appendingPathComponent("simulator-sequence-outputs-ready.txt"), atomically: true, encoding: .utf8)
            }
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription }; await reload() }
    }
}
