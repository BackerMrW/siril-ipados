// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import SirilCore

struct FITSRecord: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let width: Int
    let height: Int
    let channels: Int
    let exposure: Double
}

struct PreviewBytes: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

enum EngineError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let text): return text }
    }
}

// All upstream calls stay on one actor and its C ABI serializes global state.
actor SirilEngine {
    private func read(_ url: URL) throws -> OpaquePointer {
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        guard let image = url.path.withCString({ siril_image_read($0, &error, capacity) }) else {
            throw EngineError.failed(String(cString: error))
        }
        return image
    }

    func importFile(_ source: URL) throws -> FITSRecord {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let allowed = ["fit", "fits", "fts"]
        guard allowed.contains(source.pathExtension.lowercased()) else {
            throw EngineError.failed("请选择 .fit、.fits 或 .fts 文件")
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FITS", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let image = try read(destination)
            defer { siril_image_free(image) }
            var info = SirilImageInfo()
            guard siril_image_info(image, &info) != 0 else {
                throw EngineError.failed("Siril 无法读取图像信息")
            }
            return FITSRecord(url: destination, width: Int(info.width), height: Int(info.height),
                              channels: Int(info.channels), exposure: info.exposure)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func preview(_ url: URL) throws -> PreviewBytes {
        let image = try read(url)
        defer { siril_image_free(image) }
        var preview = SirilPreview()
        guard siril_image_preview(image, 1024, &preview) != 0, let bytes = preview.rgba else {
            throw EngineError.failed("Siril 无法生成自动拉伸预览")
        }
        defer { siril_preview_free(&preview) }
        let w = Int(preview.width), h = Int(preview.height)
        return PreviewBytes(data: Data(bytes: bytes, count: w * h * 4), width: w, height: h)
    }
}

@main
struct SirilPadApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    private let engine = SirilEngine()
    @State private var files: [FITSRecord] = []
    @State private var showImporter = false
    @State private var busy = false
    @State private var progress = ""
    @State private var errors = ""
    @State private var image: UIImage?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            List(files) { file in
                Button {
                    previewTask?.cancel()
                    previewTask = Task { await loadPreview(file) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.url.lastPathComponent.dropFirst(37)).lineLimit(1)
                        Text("\(file.width) × \(file.height) · \(file.channels) 通道 · \(file.exposure, specifier: "%.1f") 秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(busy)
            }
            .navigationTitle("Siril iPad")
            .toolbar {
                Button("导入 FITS", systemImage: "plus") { showImporter = true }.disabled(busy)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 5) {
                    Text(String(cString: siril_core_version())).font(.caption)
                    if busy { ProgressView(progress) }
                    Text("移植测试版：多文件导入与自动拉伸预览")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
        } detail: {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding().background(.black)
            } else {
                ContentUnavailableView("导入天文图像", systemImage: "sparkles",
                                       description: Text("点“导入 FITS”，可同时选择多张文件。"))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await importFiles(urls) }
            case .failure(let error): errors = error.localizedDescription
            }
        }
        .alert("读取提示", isPresented: Binding(get: { !errors.isEmpty }, set: { if !$0 { errors = "" } })) {
            Button("好") { errors = "" }
        } message: { Text(errors) }
    }

    @MainActor private func importFiles(_ urls: [URL]) async {
        busy = true
        defer { busy = false; progress = "" }
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            progress = "导入 \(index + 1) / \(urls.count)"
            do { files.append(try await engine.importFile(url)) }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { errors = failures.joined(separator: "\n") }
    }

    @MainActor private func loadPreview(_ record: FITSRecord) async {
        busy = true
        progress = "Siril 正在自动拉伸"
        defer { busy = false; progress = "" }
        do {
            let p = try await engine.preview(record.url)
            guard !Task.isCancelled, let provider = CGDataProvider(data: p.data as CFData),
                  let cg = CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: p.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
            image = UIImage(cgImage: cg)
        } catch { if !Task.isCancelled { errors = error.localizedDescription } }
    }
}
