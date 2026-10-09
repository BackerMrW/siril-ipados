// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import SirilCore

struct FITSRecord: Identifiable, Sendable, Codable {
    var id = UUID()
    let url: URL
    let width: Int
    let height: Int
    let channels: Int
    let exposure: Double
    var role: FrameRole = .lights
    var displayName: String {
        let name = url.lastPathComponent
        return name.count > 37 && UUID(uuidString: String(name.prefix(36))) != nil ? String(name.dropFirst(37)) : name
    }
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

    func importFile(_ source: URL, role: FrameRole = .lights) throws -> FITSRecord {
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
                              channels: Int(info.channels), exposure: info.exposure, role: role)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func loadLibrary() -> [FITSRecord] {
        guard let data = try? Data(contentsOf: libraryURL),
              let records = try? JSONDecoder().decode([FITSRecord].self, from: data) else { return [] }
        return records.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func saveLibrary(_ records: [FITSRecord]) throws {
        try JSONEncoder().encode(records).write(to: libraryURL, options: .atomic)
    }

    private var libraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("library.json")
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
    @State private var importRole: FrameRole = .lights
    @State private var showProcessing = false
    @State private var previewURL: URL?
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationSplitView {
            List {
              Picker("导入类型", selection: $importRole) {
                  ForEach(FrameRole.allCases.filter { $0 != .results }) { role in Text(role.title).tag(role) }
              }.disabled(busy)
              ForEach(FrameRole.allCases) { role in
                Section(role.title) {
                  ForEach(files.filter { $0.role == role }) { file in
                HStack {
                Button {
                    if selected.contains(file.id) { selected.remove(file.id) }
                    else { selected.insert(file.id) }
                } label: {
                    Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                }.buttonStyle(.borderless).disabled(busy)
                Button {
                    previewTask?.cancel()
                    previewTask = Task { await loadPreview(file) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(file.displayName).lineLimit(1)
                        Text("\(file.width) × \(file.height) · \(file.channels) 通道 · \(file.exposure, specifier: "%.1f") 秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.borderless).disabled(busy)
                }
                  }
                }
              }
            }
            .navigationTitle("Siril iPad")
            .toolbar {
                Button("导入 FITS", systemImage: "plus") { showImporter = true }.disabled(busy)
                Button("处理", systemImage: "slider.horizontal.3") { showProcessing = true }.disabled(busy)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 5) {
                    Text(String(cString: siril_core_version())).font(.caption)
                    if busy { ProgressView(progress) }
                    Text("原生 Siril · 本地处理")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
        } detail: {
            if let image {
                VStack {
                    Image(uiImage: image).resizable().scaledToFit().padding().background(.black)
                    if let previewURL { ShareLink("导出 FITS", item: previewURL).padding() }
                }
            } else {
                ContentUnavailableView("导入天文图像", systemImage: "sparkles",
                                       description: Text("点“导入 FITS”，可同时选择多张文件。"))
            }
        }
        .sheet(isPresented: $showProcessing) {
            ProcessingView(engine: engine, files: files.filter { selected.contains($0.id) }) { result in
                Task {
                    do {
                        let record = try await engine.importFile(result, role: .results)
                        files.append(record)
                        try await engine.saveLibrary(files)
                        await loadPreview(record)
                    } catch { errors = error.localizedDescription }
                }
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
        .task {
            if ProcessInfo.processInfo.environment["SIRIL_SELF_TEST"] == "1" {
                await runSimulatorCheck()
            } else {
                files = await engine.loadLibrary()
                selected = Set(files.filter { $0.role != .results }.map(\.id))
            }
        }
    }

    @MainActor private func runSimulatorCheck() async {
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simulator-app-selftest.txt")
        do {
            guard let source = Bundle.main.url(forResource: "light", withExtension: "fits") else {
                throw EngineError.failed("Bundled FITS fixture missing")
            }
            let record = try await engine.importFile(source)
            guard record.width == 2, record.height == 2, record.channels == 1, record.exposure == 120 else {
                throw EngineError.failed("Swift bridge metadata mismatch")
            }
            files.append(record)
            await loadPreview(record)
            guard image != nil else { throw EngineError.failed("Swift image preview failed: " + errors) }
            let batch = [record, record, record]
            let script = try SirilWorkflow.script(files: batch, options: BatchOptions(debayer: false, register: false, rejection: false))
            let job = try await engine.prepareJob(files: batch, script: script)
            let outputs = try await engine.run(job)
            guard let result = outputs.first(where: { $0.lastPathComponent == "result.fits" }) else {
                throw EngineError.failed("Native batch result missing")
            }
            let processed = try await engine.importFile(result, role: .results)
            guard processed.width == 2 && processed.height == 2 else { throw EngineError.failed("Batch output dimensions changed") }
            await loadPreview(processed)
            try await engine.saveLibrary([record, processed])
            let restored = await engine.loadLibrary()
            guard restored.count == 2 && restored[1].role == .results else { throw EngineError.failed("Library restore failed") }
            guard String(cString: siril_command_catalog()).contains("register\t") else { throw EngineError.failed("Command catalog missing") }
            try "PASS: Swift actor imported FITS, executed generated Siril conversion/stacking commands, restored its library, and rendered the result through automatic MTF in SwiftUI.\n"
                .write(to: report, atomically: true, encoding: .utf8)
        } catch {
            try? ("FAIL: " + error.localizedDescription).write(to: report, atomically: true, encoding: .utf8)
        }
    }

    @MainActor private func importFiles(_ urls: [URL]) async {
        busy = true
        defer { busy = false; progress = "" }
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            progress = "导入 \(index + 1) / \(urls.count)"
            do {
                let file = try await engine.importFile(url, role: importRole)
                files.append(file)
                selected.insert(file.id)
            }
            catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        do { try await engine.saveLibrary(files) }
        catch { failures.append("保存图库：" + error.localizedDescription) }
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
            previewURL = record.url
        } catch { if !Task.isCancelled { errors = error.localizedDescription } }
    }
}
