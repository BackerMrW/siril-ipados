// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

enum NativeImageFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case png16, png8, jpeg, tiff32, tiff16, tiff8, jxl32, jxl8
    var id: String { rawValue }
    var title: String { switch self { case .png16: return "PNG · 16位"; case .png8: return "PNG · 8位"; case .jpeg: return "JPEG · 8位"; case .tiff32: return "TIFF · 32位浮点"; case .tiff16: return "TIFF · 16位"; case .tiff8: return "TIFF · 8位"; case .jxl32: return "JPEG XL · 32位浮点"; case .jxl8: return "JPEG XL · 8位" } }
    var isJXL: Bool { [.jxl32, .jxl8].contains(self) }
    var native: Int32 { isJXL ? 4 : [.png16, .png8].contains(self) ? 1 : self == .jpeg ? 2 : 3 }
    var depth: Int32 { [.tiff32, .jxl32].contains(self) ? 32 : [.png16, .tiff16].contains(self) ? 16 : 8 }
    var ext: String { isJXL ? "jxl" : native == 1 ? "png" : native == 2 ? "jpg" : "tif" }
}
extension SirilEngine {
    func exportImage(_ file: FITSRecord, format: NativeImageFormat, quality: Int, jxlQuality: Double = 94, jxlEffort: Int = 7) throws -> URL {
        guard (1...100).contains(quality) else { throw EngineError.failed("JPEG 质量必须在1–100之间。") }
        guard jxlQuality.isFinite && (0...100).contains(jxlQuality) && (1...9).contains(jxlEffort) else { throw EngineError.failed("JPEG XL 质量范围为0–100，压缩计算量范围为1–9。") }
        let input = try owned(file.url.lastPathComponent, under: documents.appendingPathComponent("FITS"))
        let image = try read(input); defer { siril_image_free(image) }
        let job = try prepareJob(files: [file], script: "# 原版图片导出。格式与位深见 export.json；输入副本和输出均保留。\n")
        let output = job.folder.appendingPathComponent("process/export." + format.ext)
        do {
            let success = output.path.withCString { format.isJXL ? siril_image_export_jxl(image, $0, format.depth, Int32(jxlEffort), jxlQuality) : siril_image_export(image, $0, format.native, format.depth, Int32(quality)) }
            guard success != 0 else { throw EngineError.failed("原版图像导出失败。") }
            var settings: [String: String] = ["format": format.rawValue, "quality": format.isJXL ? String(jxlQuality) : String(quality), "source": file.id.uuidString]
            if format.isJXL { settings["effort"] = String(jxlEffort) }
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
    @State private var jxlQuality = 94.0
    @State private var jxlEffort = 7
    @State private var output: URL?
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("原版图像导出") {
                    Picker("格式与位深", selection: $format) { ForEach(NativeImageFormat.allCases) { Text($0.title).tag($0) } }
                    if format == .jpeg { Stepper("JPEG 质量：\(quality)", value: $quality, in: 1...100) }
                    if format.isJXL {
                        Toggle("无损压缩", isOn: Binding(get: { jxlQuality == 100 }, set: { jxlQuality = $0 ? 100 : 94 }))
                        if jxlQuality < 100 { Slider(value: $jxlQuality, in: 0...100, step: 0.1); Text("质量：\(jxlQuality, specifier: "%.1f")") }
                        Stepper("压缩计算量：\(jxlEffort)", value: $jxlEffort, in: 1...9)
                        Text("计算量越高，压缩通常越小且耗时越长。质量100为无损；32位浮点可保留处理像素的精度。").font(.caption).foregroundStyle(.secondary)
                    }
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
            .onChange(of: jxlQuality) { _, _ in output = nil }
            .onChange(of: jxlEffort) { _, _ in output = nil }
            .interactiveDismissDisabled(busy)
        }
    }
    @MainActor private func generate() {
        guard !busy else { return }; busy = true; message = ""; output = nil
        Task { defer { busy = false }; do { output = try await engine.exportImage(file, format: format, quality: quality, jxlQuality: jxlQuality, jxlEffort: jxlEffort) } catch { message = error.localizedDescription } }
    }
}
