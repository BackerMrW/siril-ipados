// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import SirilCore

struct FITSRecord: Identifiable, Sendable, Codable {
    var id = UUID()
    var url: URL
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
    func read(_ url: URL) throws -> OpaquePointer {
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
              var records = try? JSONDecoder().decode([FITSRecord].self, from: data) else { return [] }
        // Installation updates can change the sandbox's absolute container path.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for index in records.indices {
            records[index].url = documents.appendingPathComponent("FITS").appendingPathComponent(records[index].url.lastPathComponent)
        }
        return records.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func saveLibrary(_ records: [FITSRecord]) throws {
        try JSONEncoder().encode(records).write(to: libraryURL, options: .atomic)
    }

    private var libraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("library.json")
    }

    func preview(_ url: URL, channel: Int = -1, automatic: Bool = true) throws -> PreviewBytes {
        let image = try read(url)
        defer { siril_image_free(image) }
        var preview = SirilPreview()
        guard siril_image_preview_display(image, 2048, Int32(channel), automatic ? 1 : 0, &preview) != 0, let bytes = preview.rgba else {
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
    @State private var showAbout = false
    @State private var showHistory = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showProcessing = false
    @State private var previewURL: URL?
    @State private var selected: Set<UUID> = []
    @State private var activeFile: FITSRecord?
    @State private var displayChannel = -1
    @State private var autoDisplay = true
    @State private var showBackground = false
    @State private var showTools = false
    @State private var pendingTool: Int?
    @State private var showAnalysis = false
    @State private var analysisTab = 0
    @State private var imageSelection: ImageSelection?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
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
                .contextMenu {
                    Menu("更改类型") {
                        ForEach(FrameRole.allCases) { role in
                            Button(role.title) {
                                if let index = files.firstIndex(where: { $0.id == file.id }) {
                                    files[index].role = role
                                    Task { do { try await engine.saveLibrary(files) } catch { errors = error.localizedDescription } }
                                }
                            }
                        }
                    }
                    Button("只选择这张") { selected = [file.id] }
                }.disabled(busy)
                  }
                }
              }
            }
            .navigationTitle("Siril iPad")
            .toolbar {
                Button("导入 FITS", systemImage: "plus") { showImporter = true }.disabled(busy)
                Button("处理", systemImage: "slider.horizontal.3") { showProcessing = true }.disabled(busy)
                Button("记录", systemImage: "clock.arrow.circlepath") { showHistory = true }.disabled(busy)
                Menu("选择", systemImage: "checklist") {
                    Button("选中拍摄帧") { selected = Set(files.filter { $0.role != .results }.map(\.id)) }
                    Button("取消全选") { selected.removeAll() }
                }.disabled(busy)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 5) {
                    Text(String(cString: siril_core_version())).font(.caption)
                    if busy { ProgressView(progress) }
                    Button("关于与源码") { showAbout = true }.font(.caption)
                    Text("原生 Siril · 本地处理")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
        } detail: {
            VStack {
                if let image {
                    HStack {
                        Picker("通道", selection: $displayChannel) {
                            Text("RGB / 灰度").tag(-1)
                            if activeFile?.channels == 3 {
                                Text("红 R").tag(0); Text("绿 G").tag(1); Text("蓝 B").tag(2)
                            }
                        }.pickerStyle(.segmented)
                        Toggle("自动拉伸显示", isOn: $autoDisplay)
                    }.padding(.horizontal)
                    ZoomableImageCanvas(image: image, samples: [], imageWidth: Double(activeFile?.width ?? 1),
                        imageHeight: Double(activeFile?.height ?? 1), region: imageSelection, onTap: nil)
                        .background(.black)
                    HStack {
                        Button("图像处理", systemImage: "slider.horizontal.3") { showTools = true }
                        Button("背景提取") { showBackground = true }
                        Button("统计 / 直方图") { analysisTab = 0; showAnalysis = true }
                    }.disabled(busy).padding(.top, 8)
                    if let previewURL { ShareLink("导出 FITS", item: previewURL).padding() }
                } else {
                    ContentUnavailableView("导入天文图像", systemImage: "sparkles",
                                           description: Text("可同时导入多张文件，在图库中勾选本次处理的图像。"))
                }
            }
            .navigationTitle(activeFile?.displayName ?? "图像工作区")
            .toolbar {
                Button("导入", systemImage: "plus") { showImporter = true }.disabled(busy)
                Button("处理", systemImage: "slider.horizontal.3") { showProcessing = true }.disabled(busy)
                Button("记录", systemImage: "clock.arrow.circlepath") { showHistory = true }.disabled(busy)
            }
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .fullScreenCover(isPresented: $showBackground) {
            if let file = activeFile {
                BackgroundExtractionView(file: file, onPreview: importResult)
            }
        }
        .fullScreenCover(isPresented: $showAnalysis) {
            if let file = activeFile {
                ImageAnalysisView(file: file, selection: $imageSelection, initialTab: analysisTab)
            }
        }
        .sheet(isPresented: $showTools, onDismiss: {
            if pendingTool == 0 { showBackground = true }
            if pendingTool == 1 { showProcessing = true }
            if let pendingTool, pendingTool >= 2 { analysisTab = pendingTool - 2; showAnalysis = true }
            pendingTool = nil
        }) {
            ToolInventoryView(onBackground: { pendingTool = 0; showTools = false },
                              onProcessing: { pendingTool = 1; showTools = false },
                              onAnalysis: { tab in pendingTool = tab + 2; showTools = false })
        }
        .onChange(of: displayChannel) { _, _ in refreshDisplay() }
        .onChange(of: autoDisplay) { _, _ in refreshDisplay() }
        .sheet(isPresented: $showHistory) {
            JobHistoryView(engine: engine, onPreview: importResult)
        }
        .sheet(isPresented: $showProcessing) {
            ProcessingView(engine: engine, files: files.filter { selected.contains($0.id) }, onPreview: importResult)
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
                if ProcessInfo.processInfo.environment["SIRIL_ANALYSIS_VIEW_CHECK"] == "1", let file = files.last {
                    await loadPreview(file)
                    imageSelection = ImageSelection(x: 24, y: 32, width: 80, height: 64)
                    analysisTab = 0
                    showAnalysis = true
                }
            }
        }
    }

    @MainActor private func importResult(_ result: URL) {
        Task {
            do {
                let record = try await engine.importFile(result, role: .results)
                files.append(record)
                selected = [record.id]
                try await engine.saveLibrary(files)
                await loadPreview(record)
            } catch { errors = error.localizedDescription }
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
            var batch = [record, record, record]
            for (name, role) in [("dark", FrameRole.darks), ("flat", .flats), ("bias", .biases)] {
                guard let fixture = Bundle.main.url(forResource: name, withExtension: "fits") else {
                    throw EngineError.failed("Bundled calibration fixture missing")
                }
                let calibration = try await engine.importFile(fixture, role: role)
                batch += [calibration, calibration, calibration]
            }
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
            let history = await engine.jobHistory()
            guard let savedJob = history.first(where: { $0.id == job.folder.lastPathComponent }), savedJob.info.state == "已完成",
                  savedJob.info.inputCount == batch.count, !savedJob.results.isEmpty else {
                throw EngineError.failed("Processing history restore failed")
            }
            var toolOptions = ImageToolOptions()
            toolOptions.stretch = .mtf
            let toolScript = try ImageToolScript.make(files: [processed], options: toolOptions)
            let toolJob = try await engine.prepareJob(files: [processed], script: toolScript)
            let toolOutputs = try await engine.run(toolJob)
            guard toolOutputs.contains(where: { $0.lastPathComponent == "result.fits" }) else {
                throw EngineError.failed("Native image tools result missing")
            }
            guard Bundle.main.url(forResource: "LICENSE", withExtension: "md") != nil,
                  let licenses = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: nil),
                  FileManager.default.fileExists(atPath: licenses.appendingPathComponent("GSL/COPYING").path) else {
                throw EngineError.failed("Bundled open-source notices missing")
            }
            guard String(cString: siril_command_catalog()).contains("register\t") else { throw EngineError.failed("Command catalog missing") }
            guard UpstreamInventory.bundled.count >= 100,
                  let gradient = Bundle.main.url(forResource: "gradient", withExtension: "fits") else {
                throw EngineError.failed("Original feature inventory / background fixture missing")
            }
            let backgroundFile = try await engine.importFile(gradient)
            let analysis = ImageAnalysisEngine()
            let metadata = try await analysis.open(backgroundFile.url)
            let full = try await analysis.analyze(region: nil, perCFA: true)
            let area = ImageSelection(x: 24, y: 32, width: 80, height: 64)
            let partial = try await analysis.analyze(region: area, perCFA: false)
            let pixel = try await analysis.pixel(x: 24, y: 32)
            guard metadata.header.contains("BITPIX"), metadata.width == 256,
                  full.statistics.count == 1, full.statistics[0].total == 65536,
                  full.histograms[0].reduce(0, +) == 65536,
                  partial.statistics[0].total == 5120, partial.histograms[0].reduce(0, +) == 5120,
                  partial.statistics[0].values[0] != full.statistics[0].values[0],
                  pixel.values.count == 1, pixel.values[0] > 0 else {
                throw EngineError.failed("Native workspace statistics / histogram / pixel / header failed")
            }
            let background = BackgroundEngine()
            try await background.open(backgroundFile.url)
            var settings = BackgroundSettings()
            settings.perLine = 8
            try await background.generate(settings)
            let samples = try await background.samples()
            guard samples.count > 6 else { throw EngineError.failed("Native sample generation failed") }
            try await background.remove(0)
            let fewer = try await background.samples()
            guard fewer.count == samples.count - 1 else { throw EngineError.failed("Native sample deletion failed") }
            try await background.add(x: 50, y: 50, descent: false)
            try await background.compute(settings)
            guard try await background.preview(view: 2, channel: -1, automatic: true).uiImage != nil else {
                throw EngineError.failed("Native background model preview failed")
            }
            let corrected = try await background.save(file: backgroundFile, settings: settings)
            guard FileManager.default.fileExists(atPath: corrected.path) else { throw EngineError.failed("Native background export failed") }
            await loadPreview(backgroundFile)
            try await engine.saveLibrary([record, processed, backgroundFile])
            showBackground = true
            try "PASS: Swift actor imported FITS, calibrated and stacked lights with original Siril commands, restored library/history, ran manual MTF, tested native background samples/RBF/model/FITS export, and verified original full/selected statistics and histogram counts, full-resolution pixel reads and complete FITS header. Bundled original feature inventory and notices were verified.\n"
                .write(to: report, atomically: true, encoding: .utf8)
        } catch {
            try? ("FAIL: " + error.localizedDescription + "\n" + String(SirilEngine.processingLog().suffix(16000)))
                .write(to: report, atomically: true, encoding: .utf8)
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

    @MainActor private func refreshDisplay() {
        guard let activeFile else { return }
        previewTask?.cancel()
        previewTask = Task { await loadPreview(activeFile) }
    }

    @MainActor private func loadPreview(_ record: FITSRecord) async {
        busy = true
        progress = "Siril 正在自动拉伸"
        defer { busy = false; progress = "" }
        do {
            if activeFile?.id != record.id { displayChannel = -1; imageSelection = nil }
            activeFile = record
            let p = try await engine.preview(record.url, channel: displayChannel, automatic: autoDisplay)
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
