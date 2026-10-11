// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

enum NativeImageFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case png16, png8, jpeg, tiff32, tiff16, tiff8
    var id: String { rawValue }
    var title: String { switch self { case .png16: return "PNG · 16位"; case .png8: return "PNG · 8位"; case .jpeg: return "JPEG · 8位"; case .tiff32: return "TIFF · 32位浮点"; case .tiff16: return "TIFF · 16位"; case .tiff8: return "TIFF · 8位" } }
    var native: Int32 { [.png16, .png8].contains(self) ? 1 : self == .jpeg ? 2 : 3 }
    var depth: Int32 { self == .tiff32 ? 32 : [.png16, .tiff16].contains(self) ? 16 : 8 }
    var ext: String { native == 1 ? "png" : native == 2 ? "jpg" : "tif" }
}
extension SirilEngine {
    func exportImage(_ file: FITSRecord, format: NativeImageFormat, quality: Int) throws -> URL {
        guard (1...100).contains(quality) else { throw EngineError.failed("JPEG 质量必须在1–100之间。") }
        let input = try owned(file.url.lastPathComponent, under: documents.appendingPathComponent("FITS"))
        let image = try read(input); defer { siril_image_free(image) }
        let job = try prepareJob(files: [file], script: "# 原版图片导出。格式与位深见 export.json；输入副本和输出均保留。\n")
        let output = job.folder.appendingPathComponent("process/export." + format.ext)
        do {
            guard output.path.withCString({ siril_image_export(image, $0, format.native, format.depth, Int32(quality)) }) != 0 else { throw EngineError.failed("原版图像导出失败。") }
            let settings: [String: String] = ["format": format.rawValue, "quality": String(quality), "source": file.id.uuidString]
            try JSONEncoder().encode(settings).write(to: job.folder.appendingPathComponent("export.json"), options: .atomic)
            try writeJobState(job.folder, state: "已完成", message: format.title)
            return output
        } catch { try? writeJobState(job.folder, state: "导出失败", message: error.localizedDescription); throw error }
    }
}
struct NativeImageExportView: View {
    let file: FITSRecord
    let engine: SirilEngine
    @Environment(\.dismiss) private var dismiss
    @State private var format: NativeImageFormat = .tiff32
    @State private var quality = 95
    @State private var output: URL?
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("原版图像导出") {
                    Picker("格式与位深", selection: $format) { ForEach(NativeImageFormat.allCases) { Text($0.title).tag($0) } }
                    if format == .jpeg { Stepper("JPEG 质量：\(quality)", value: $quality, in: 1...100) }
                    Text("导出当前完整分辨率的像素。显示自动拉伸不会改变导出文件；希望保存拉伸后的图片，请先应用拉伸工具。JPEG 有损；32位 TIFF 保留浮点像素。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("生成导出文件") { generate() }
                    if busy { ProgressView() }
                }
                if let output { Section("文件") { Text(output.lastPathComponent); ShareLink("保存到文件 / 分享", item: output) } }
                if !message.isEmpty { Section { Text(message).textSelection(.enabled) } }
                Section { Text("导出文件和输入副本保存在本次处理记录中，可通过任务删除与永久清理释放空间。").font(.caption) }
            }.disabled(busy)
            .navigationTitle("导出图片")
            .toolbar { Button("完成") { dismiss() }.disabled(busy) }
            .onChange(of: format) { _, _ in output = nil }
            .onChange(of: quality) { _, _ in output = nil }
            .interactiveDismissDisabled(busy)
        }
    }
    @MainActor private func generate() {
        guard !busy else { return }; busy = true; message = ""; output = nil
        Task { defer { busy = false }; do { output = try await engine.exportImage(file, format: format, quality: quality) } catch { message = error.localizedDescription } }
    }
}
