// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct JobState: Codable, Sendable {
    var created: Date
    var updated: Date
    var state: String
    var inputCount: Int
    var message: String
}

struct JobRecord: Identifiable, Sendable {
    let folder: URL
    let info: JobState
    let results: [URL]
    let bytes: Int64
    var id: String { folder.lastPathComponent }
}

extension SirilEngine {
    func writeJobState(_ folder: URL, state: String, count: Int = 0, message: String = "") throws {
        let url = folder.appendingPathComponent("job.json")
        var value = (try? JSONDecoder().decode(JobState.self, from: Data(contentsOf: url))) ??
            JobState(created: Date(), updated: Date(), state: state, inputCount: count, message: message)
        value.updated = Date()
        value.state = state
        value.message = message
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    func jobHistory() -> [JobRecord] {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jobs")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]) else { return [] }
        return folders.compactMap { folder -> JobRecord? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            var info = (try? JSONDecoder().decode(JobState.self, from: Data(contentsOf: folder.appendingPathComponent("job.json")))) ??
                JobState(created: created, updated: created, state: "旧版本任务", inputCount: 0, message: "")
            // App relaunch cannot resume an interrupted upstream worker.
            if info.state == "运行中" { info.state = "处理被中断" }
            return JobRecord(folder: folder, info: info, results: (try? resultFiles(in: folder)) ?? [], bytes: directoryBytes(folder))
        }.sorted { $0.info.created > $1.info.created }
    }
}

struct JobHistoryView: View {
    let engine: SirilEngine
    let onPreview: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var jobs: [JobRecord] = []
    @State private var loading = true
    @State private var deleting: JobRecord?
    @State private var confirmDelete = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("读取任务记录") }
                if !loading && jobs.isEmpty {
                    ContentUnavailableView("还没有处理任务", systemImage: "clock", description: Text("运行脚本后，结果和日志会自动保存在这里。"))
                }
                ForEach(jobs) { job in
                    NavigationLink {
                        JobDetailView(job: job) { result in dismiss(); onPreview(result) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.info.created.formatted(date: .abbreviated, time: .shortened))
                            Text("\(job.info.state) · \(job.info.inputCount) 张输入 · \(job.results.count) 个 FITS · \(StorageSummary.format(job.bytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { deleting = job; confirmDelete = true } }
                    .contextMenu { Button("删除整个任务", role: .destructive) { deleting = job; confirmDelete = true } }
                }
                Section { Text("删除任务会移走该任务的输入副本、结果和中间文件。已导入图库的结果副本会保留。到删除与存储中永久删除，才能释放空间。").font(.caption) }
            }
            .disabled(loading)
            .navigationTitle("处理记录")
            .toolbar { Button("完成") { dismiss() } }
            .confirmationDialog("删除整个处理任务？可以在最近删除中恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("移入最近删除", role: .destructive) {
                    guard let job = deleting else { return }
                    loading = true
                    Task {
                        do { try await engine.trashJob(job) } catch { self.error = error.localizedDescription }
                        jobs = await engine.jobHistory(); loading = false
                    }
                }
            }
            .alert("删除失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
            .task { jobs = await engine.jobHistory(); loading = false }
        }
    }
}

struct JobDetailView: View {
    let job: JobRecord
    let onPreview: (URL) -> Void
    @State private var script = ""
    @State private var log = ""
    var body: some View {
        List {
            Section("任务") {
                LabeledContent("状态", value: job.info.state)
                LabeledContent("输入", value: "\(job.info.inputCount) 张")
                Text(job.folder.lastPathComponent).font(.caption).textSelection(.enabled)
                if !job.info.message.isEmpty { Text(job.info.message).textSelection(.enabled) }
            }
            Section("结果") {
                ForEach(job.results, id: \.self) { result in
                    HStack {
                        Button(result.lastPathComponent) { onPreview(result) }
                        Spacer()
                        ShareLink(item: result) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                if job.results.isEmpty { Text("没有输出 FITS，请查看日志。") }
            }
            Section("脚本") {
                ShareLink("导出 .ssf", item: job.folder.appendingPathComponent("processing.ssf"))
                Text(script).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if FileManager.default.fileExists(atPath: job.folder.appendingPathComponent("batch-options.json").path) {
                    ShareLink("导出生成时的批处理参数", item: job.folder.appendingPathComponent("batch-options.json"))
                    Text("运行以保存的脚本为准；手动编辑脚本后，命令可能与生成时的界面参数不同。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if FileManager.default.fileExists(atPath: job.folder.appendingPathComponent("inputs.json").path) {
                    ShareLink("导出输入文件列表", item: job.folder.appendingPathComponent("inputs.json"))
                }
            }
            Section("日志") {
                if FileManager.default.fileExists(atPath: job.folder.appendingPathComponent("processing.log").path) {
                    ShareLink("导出日志", item: job.folder.appendingPathComponent("processing.log"))
                }
                Text(log.isEmpty ? "没有日志" : log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .navigationTitle("任务详情")
        .task {
            script = (try? String(contentsOf: job.folder.appendingPathComponent("processing.ssf"), encoding: .utf8)) ?? ""
            log = (try? String(contentsOf: job.folder.appendingPathComponent("processing.log"), encoding: .utf8)) ?? ""
        }
    }
}
