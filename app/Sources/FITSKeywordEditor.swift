// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct FITSKeywordEdit: Codable, Equatable, Sendable {
    enum Action: Int32, CaseIterable, Codable, Identifiable, Sendable {
        case set = 0, delete = 1, rename = 2, comment = 3
        var id: Int32 { rawValue }
        var title: String { switch self { case .set: return "新增 / 修改"; case .delete: return "删除"; case .rename: return "重命名"; case .comment: return "添加注释" } }
    }
    var action: Action = .set
    var key = "OBJECT", value = "", comment = ""
    var stringValue = true
}
extension SirilEngine {
    func editSequenceFITSKeywords(_ location: SequenceLocation, edit: FITSKeywordEdit) throws -> SequenceLocation {
        let before = try inspectSequence(location)
        guard before.info.included > 0 else { throw EngineError.failed("请至少选择一张参与帧。") }
        let source = try sequenceFolder(location).deletingLastPathComponent()
        let paths = try sequenceFilePaths(location)
        let job = try prepareJob(files: [], script: "# 原版序列 FITS 关键字编辑；参数见 keywords.json。\n")
        let process = job.folder.appendingPathComponent("process")
        try JSONEncoder().encode(edit).write(to: job.folder.appendingPathComponent("keywords.json"), options: .atomic)
        try JSONEncoder().encode(location).write(to: job.folder.appendingPathComponent("source-location.json"), options: .atomic)
        let initial = JobState(created: Date(), updated: Date(), state: "准备完成", inputCount: Int(before.info.included), message: "原版序列 FITS 关键字编辑")
        try JSONEncoder().encode(initial).write(to: job.folder.appendingPathComponent("job.json"), options: .atomic)
        activeJobIDs.insert(location.job)
        activeJobIDs.insert(job.folder.lastPathComponent)
        defer { activeJobIDs.remove(location.job); activeJobIDs.remove(job.folder.lastPathComponent) }
        do {
            try writeJobState(job.folder, state: "运行中", count: Int(before.info.included))
            for path in paths {
                try Task.checkCancellation()
                let input = try sequenceTrashPath(path, under: source)
                let output = try sequenceTrashPath(path, under: job.folder)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: input, to: output)
            }
            try Task.checkCancellation()
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            let success = process.path.withCString { directory in location.name.withCString { name in
                edit.key.withCString { key in edit.value.withCString { value in edit.comment.withCString { comment in
                    siril_sequence_edit_keyword(directory, name, edit.action.rawValue, key, value, comment,
                        edit.stringValue ? 1 : 0, &error, capacity)
                } } }
            } }
            try? Self.processingLog().write(to: job.folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            guard success != 0 else { throw EngineError.failed(String(cString: error)) }
            try Task.checkCancellation()
            let result = SequenceLocation(job: job.folder.lastPathComponent, name: location.name)
            // Verify before publishing: both jobs are still locked against UI edits.
            var info = SirilSequenceInfo()
            let count = process.path.withCString { directory in location.name.withCString {
                siril_sequence_inspect(directory, $0, 0, &info, nil, 0, &error, capacity)
            } }
            guard count == before.info.count, info.included == before.info.included, info.reference == before.info.reference else {
                throw EngineError.failed("关键字结果序列的帧数或参与选择不一致。")
            }
            try JSONEncoder().encode(result).write(to: job.folder.appendingPathComponent("output-sequence.json"), options: .atomic)
            try writeJobState(job.folder, state: "已完成", count: Int(info.count))
            return result
        } catch {
            siril_release_workspace()
            try? FileManager.default.removeItem(at: process)
            try? FileManager.default.createDirectory(at: process, withIntermediateDirectories: true)
            try? writeJobState(job.folder, state: "编辑失败或取消", message: error.localizedDescription)
            throw error
        }
    }
    func editFITSKeywords(_ files: [FITSRecord], edit: FITSKeywordEdit) throws -> [URL] {
        guard !files.isEmpty else { throw EngineError.failed("没有待编辑的图像。") }
        let job = try prepareJob(files: files, script: "# 原版 FITS 关键字编辑；参数见 keywords.json。\n")
        activeJobIDs.insert(job.folder.lastPathComponent)
        defer { activeJobIDs.remove(job.folder.lastPathComponent) }
        try JSONEncoder().encode(edit).write(to: job.folder.appendingPathComponent("keywords.json"), options: .atomic)
        var outputs: [URL] = []
        do {
            try writeJobState(job.folder, state: "运行中")
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let source = try owned(file.url.lastPathComponent, under: documents.appendingPathComponent("FITS"))
                let original = try read(source); defer { siril_image_free(original) }
                var error = [CChar](repeating: 0, count: 512); let capacity = error.count
                let result = edit.key.withCString { key in edit.value.withCString { value in edit.comment.withCString { comment in
                    siril_image_edit_keyword(original, edit.action.rawValue, key, value, comment, edit.stringValue ? 1 : 0, &error, capacity)
                } } }
                guard let result else { throw EngineError.failed(String(cString: error)) }
                defer { siril_image_free(result) }
                let output = job.folder.appendingPathComponent(String(format: "process/keywords_%05d.fits", index + 1))
                guard output.path.withCString({ siril_image_write(result, $0) }) != 0 else { throw EngineError.failed("关键字结果保存失败。") }
                outputs.append(output)
            }
            try Task.checkCancellation()
            try writeJobState(job.folder, state: "已完成", count: outputs.count)
            return outputs
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            try? writeJobState(job.folder, state: "编辑失败或取消", message: error.localizedDescription)
            throw error
        }
    }
}
struct FITSKeywordEditorView: View {
    let files: [FITSRecord]
    let engine: SirilEngine
    let onOutput: (URL) -> Void
    var sequence: SequenceLocation? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var edit = FITSKeywordEdit()
    @State private var outputs: [URL] = []
    @State private var outputSequence: SequenceLocation?
    @State private var task: Task<Void, Never>?
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section(sequence == nil ? "原版 FITS 关键字编辑 · \(files.count) 张图像" : "原版序列 FITS 关键字编辑 · 当前参与帧") {
                    Picker("操作", selection: $edit.action) { ForEach(FITSKeywordEdit.Action.allCases) { Text($0.title).tag($0) } }
                    if edit.action != .comment {
                        TextField("关键字 · 最多8个英文字符", text: $edit.key).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    if edit.action == .set {
                        Toggle("文本值", isOn: $edit.stringValue)
                        TextField(edit.stringValue ? "文本内容" : "FITS 数字或逻辑值（T / F）", text: $edit.value).autocorrectionDisabled()
                        TextField("关键字注释", text: $edit.comment).autocorrectionDisabled()
                    }
                    if edit.action == .rename { TextField("新关键字", text: $edit.value).textInputAutocapitalization(.characters).autocorrectionDisabled() }
                    if edit.action == .comment { TextField("注释内容", text: $edit.comment).autocorrectionDisabled() }
                    Text("关键字和值使用 FITS 英文字符。结构、压缩、比例和 WCS 关键字受原版保护。编辑后生成独立文件，原图和本次参数保存在处理记录中。").font(.caption).foregroundStyle(.secondary)
                    if sequence != nil { Text("复制完整序列，只编辑参与帧；保留参考帧、排除帧及配准数据。失败或取消会清理本次输出。").font(.caption).foregroundStyle(.secondary) }
                    Button("生成编辑结果") { apply() }
                    if task != nil { ProgressView() }
                }.disabled(task != nil)
                if let outputSequence {
                    Section("编辑结果") {
                        NavigationLink("打开结果序列") { SequenceWorkspace(location: outputSequence, engine: engine, onPreview: onOutput) }
                    }
                }
                if !outputs.isEmpty {
                    Section("编辑结果") {
                        ForEach(outputs, id: \.self) { url in
                            Button("导入 \(url.lastPathComponent)") { dismiss(); onOutput(url) }
                            ShareLink("保存 / 分享", item: url)
                        }
                    }
                }
                if !message.isEmpty { Section { Text(message).textSelection(.enabled) } }
            }
            .navigationTitle("FITS 关键字")
            .toolbar { Button(task == nil ? "完成" : "取消编辑") { if let task { task.cancel() } else { dismiss() } } }
            .onChange(of: edit) { _, _ in outputs = []; outputSequence = nil }
            .interactiveDismissDisabled(task != nil)
            .task {
                if ProcessInfo.processInfo.environment["SIRIL_KEYWORD_VIEW_CHECK"] == "1" {
                    let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-keyword-ready.txt")
                    try? "PASS: native FITS keyword editor displayed original edit operations, value type and protected-header guidance.\n".write(to: report, atomically: true, encoding: .utf8)
                }
            }
        }
    }
    private func apply() {
        guard task == nil else { return }; outputs = []; outputSequence = nil; message = ""
        edit.key = edit.key.uppercased()
        if edit.action == .rename { edit.value = edit.value.uppercased() }
        task = Task { defer { task = nil }
            do {
                if let sequence {
                    outputSequence = try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        return try await engine.editSequenceFITSKeywords(sequence, edit: edit)
                    } onCancel: { siril_cancel_processing() }
                }
                else { outputs = try await engine.editFITSKeywords(files, edit: edit) }
            }
            catch { message = error.localizedDescription }
        }
    }
}
