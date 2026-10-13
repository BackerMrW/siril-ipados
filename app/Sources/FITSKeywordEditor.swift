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
    @Environment(\.dismiss) private var dismiss
    @State private var edit = FITSKeywordEdit()
    @State private var outputs: [URL] = []
    @State private var task: Task<Void, Never>?
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("原版 FITS 关键字编辑 · \(files.count) 张图像") {
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
                    Button("生成编辑结果") { apply() }
                    if task != nil { ProgressView() }
                }.disabled(task != nil)
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
            .onChange(of: edit) { _, _ in outputs = [] }
            .interactiveDismissDisabled(task != nil)
        }
    }
    private func apply() {
        guard task == nil else { return }; outputs = []; message = ""
        edit.key = edit.key.uppercased()
        if edit.action == .rename { edit.value = edit.value.uppercased() }
        task = Task { defer { task = nil }
            do { outputs = try await engine.editFITSKeywords(files, edit: edit) }
            catch { message = error.localizedDescription }
        }
    }
}
