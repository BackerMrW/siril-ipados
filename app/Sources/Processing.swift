// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import SirilCore

enum FrameRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case lights, darks, flats, biases, flatdarks, results
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lights: return "亮场"
        case .darks: return "暗场"
        case .flats: return "平场"
        case .biases: return "偏置"
        case .flatdarks: return "暗平场"
        case .results: return "处理结果"
        }
    }
}

struct BatchOptions: Sendable {
    var debayer = false
    var register = true
    var rejection = true
}

struct ProcessingJob: Sendable {
    let folder: URL
    let script: String
}

// Generates commands only. Every algorithm runs in the original Siril engine.
enum SirilWorkflow {
    static func script(files: [FITSRecord], options: BatchOptions) throws -> String {
        let groups = Dictionary(grouping: files, by: \.role)
        guard let lights = groups[.lights], lights.count >= 2 else {
            throw EngineError.failed("至少勾选两张亮场；每次处理使用勾选的文件。")
        }
        let first = lights[0]
        guard files.filter({ $0.role != .results }).allSatisfy({ $0.width == first.width && $0.height == first.height && $0.channels == first.channels }) else {
            throw EngineError.failed("亮场和校准帧的尺寸、通道数必须相同。")
        }
        if options.rejection && lights.count < 3 {
            throw EngineError.failed("异常值剔除叠加至少需要三张亮场；两张请关闭此选项。")
        }
        let has: (FrameRole) -> Bool = { !(groups[$0] ?? []).isEmpty }
        for role in FrameRole.allCases where role != .lights && role != .results && has(role) {
            guard groups[role]!.count >= 2 else {
                throw EngineError.failed("\(role.title)至少需要两张才能生成主校准帧。")
            }
        }
        if has(.darks) {
            let exposure = groups[.darks]![0].exposure
            guard exposure > 0, (lights + groups[.darks]!).allSatisfy({ abs($0.exposure - exposure) <= 0.01 }) else {
                throw EngineError.failed("此流程不缩放暗场：亮场和暗场的曝光时间必须相同。")
            }
        }
        if has(.flats) && !has(.biases) && !has(.flatdarks) {
            throw EngineError.failed("使用平场时，请同时导入偏置或暗平场，用于扣除平场中的偏置信号。")
        }
        if has(.flats) && has(.flatdarks) {
            let exposure = groups[.flatdarks]![0].exposure
            guard exposure > 0, (groups[.flats]! + groups[.flatdarks]!).allSatisfy({ abs($0.exposure - exposure) <= 0.01 }) else {
                throw EngineError.failed("平场和暗平场的曝光时间必须相同。")
            }
        }
        var lines = ["# Siril iPad 本地批处理", "set32bits"]
        func convert(_ role: FrameRole, _ base: String) {
            lines += ["cd \(role.rawValue)", "convert \(base) -out=../process", "cd ../process"]
        }
        for (role, base) in [(FrameRole.biases, "bias"), (.darks, "dark"), (.flatdarks, "flatdark")] where has(role) {
            convert(role, base)
            lines += ["stack \(base) median -nonorm -out=master_\(base).fits", "cd .."]
        }
        if has(.flats) {
            convert(.flats, "flat")
            let calibration = has(.flatdarks) ? "-dark=master_flatdark.fits" : "-bias=master_bias.fits"
            lines += ["calibrate flat \(calibration)\(options.debayer ? " -cfa" : "") -prefix=pp_",
                      "stack pp_flat median -norm=mul -out=master_flat.fits", "cd .."]
        }
        convert(.lights, "light")
        var calibration: [String] = []
        if has(.darks) { calibration += ["-dark=master_dark.fits"] }
        else if has(.biases) { calibration += ["-bias=master_bias.fits"] }
        if has(.flats) { calibration += ["-flat=master_flat.fits"] }
        if options.debayer { calibration += ["-cfa", "-debayer"] }
        var sequence = "light"
        if !calibration.isEmpty {
            lines += ["calibrate light \(calibration.joined(separator: " ")) -prefix=pp_"]
            sequence = "pp_light"
        }
        if options.register {
            lines += ["register \(sequence)"]
            sequence = "r_" + sequence
        }
        let method = options.rejection ? "rej w 3 3 -norm=addscale -output_norm" : "median -nonorm"
        lines += ["stack \(sequence) \(method) -out=result.fits"]
        return lines.joined(separator: "\n") + "\n"
    }
}

extension SirilEngine {
    func prepareJob(files: [FITSRecord], script: String) throws -> ProcessingJob {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Jobs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("process"), withIntermediateDirectories: true)
        for role in FrameRole.allCases {
            let target = folder.appendingPathComponent(role.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for (index, file) in files.filter({ $0.role == role }).enumerated() {
                let name = String(format: "frame_%05d.fits", index + 1)
                try FileManager.default.copyItem(at: file.url, to: target.appendingPathComponent(name))
            }
        }
        try script.write(to: folder.appendingPathComponent("processing.ssf"), atomically: true, encoding: .utf8)
        try writeJobState(folder, state: "准备完成", count: files.count)
        return ProcessingJob(folder: folder, script: script)
    }

    func run(_ job: ProcessingJob) throws -> [URL] {
        try writeJobState(job.folder, state: "运行中")
        var error = [CChar](repeating: 0, count: 4096)
        let capacity = error.count
        let success = job.folder.path.withCString { directory in
            job.script.withCString { siril_run_commands(directory, $0, &error, capacity) }
        }
        // Keep the full available diagnostic log alongside partial results.
        try? Self.processingLog().write(to: job.folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
        try? writeJobState(job.folder, state: success != 0 ? "已完成" : "已停止或失败", message: success != 0 ? "" : String(cString: error))
        guard success != 0 else { throw EngineError.failed(String(cString: error)) }
        return try resultFiles(in: job.folder)
    }

    func resultFiles(in folder: URL) throws -> [URL] {
        let paths = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("process"), includingPropertiesForKeys: nil)
        return paths.filter { ["fit", "fits", "fts"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let ar = a.deletingPathExtension().lastPathComponent == "result"
                let br = b.deletingPathExtension().lastPathComponent == "result"
                return ar != br ? ar : a.lastPathComponent < b.lastPathComponent
            }
    }

    nonisolated static func processingLog() -> String {
        var bytes = [CChar](repeating: 0, count: 132 * 1024)
        let capacity = bytes.count
        siril_copy_processing_log(&bytes, capacity)
        return String(cString: bytes)
    }
}

struct ProcessingView: View {
    let engine: SirilEngine
    let files: [FITSRecord]
    let onPreview: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = BatchOptions()
    @State private var script = ""
    @State private var log = ""
    @State private var busy = false
    @State private var status = ""
    @State private var results: [URL] = []
    @State private var folder: URL?
    @State private var importingScript = false
    @State private var logTask: Task<Void, Never>?
    @State private var showCommands = false
    @State private var tools = ImageToolOptions()

    var body: some View {
        NavigationStack {
            Form {
                Section("本次使用勾选的文件") {
                    ForEach(FrameRole.allCases) { role in
                        LabeledContent(role.title, value: "\(files.filter { $0.role == role }.count) 张")
                    }
                    Text("暗场与亮场需匹配曝光、温度、增益和偏置；尺寸与拍摄模式也需一致。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("批处理流程") {
                    Toggle("彩色相机 CFA 去马赛克", isOn: $options.debayer)
                    Toggle("星点配准", isOn: $options.register)
                    Toggle("Winsorized 异常值剔除叠加", isOn: $options.rejection)
                    Button("生成校准 → 配准 → 叠加脚本") {
                        do { script = try SirilWorkflow.script(files: files, options: options); status = "可编辑命令后运行" }
                        catch { status = error.localizedDescription }
                    }
                }.disabled(busy)
                Section("单张后期处理") {
                    Text("在图库中只勾选一张亮场或处理结果，然后生成后期脚本。输出另存为新的 FITS。")
                        .font(.caption).foregroundStyle(.secondary)
                    ImageToolControls(options: $tools)
                    Button("生成单张处理脚本") {
                        do {
                            script = try ImageToolScript.make(files: files, options: tools)
                            status = "可编辑后运行；输出保留在新的任务目录"
                        } catch { status = error.localizedDescription }
                    }
                }.disabled(busy)
                Section("Siril 原生脚本 / 命令") {
                    Button("导入 .ssf 脚本") { importingScript = true }.disabled(busy)
                    Button("浏览 Siril 原生命令") { showCommands = true }.disabled(busy)
                    Text("工作目录包含 lights、darks、flats、biases、flatdarks 和 process；导入脚本的路径需与这些目录对应。在线服务、外部程序和桌面交互命令暂不支持。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $script).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220).disabled(busy).autocorrectionDisabled()
                    if busy {
                        ProgressView("Siril 正在 iPad 本地处理")
                        Button("中止", role: .destructive) {
                            siril_cancel_processing()
                            status = "已请求中止，正在等待当前处理停止"
                        }
                    } else {
                        Button("运行脚本", systemImage: "play.fill") { Task { await run() } }
                            .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !status.isEmpty { Text(status).textSelection(.enabled) }
                }
                Section("处理日志") {
                    Text(log.isEmpty ? "运行后显示 Siril 原始日志" : log)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let folder {
                    Section("文件与结果") {
                        Text("保存在“文件 → 我的 iPad → Siril iPad → Jobs → \(folder.lastPathComponent)”")
                            .font(.caption).textSelection(.enabled)
                        ShareLink("导出本次脚本", item: folder.appendingPathComponent("processing.ssf"))
                        ShareLink("导出日志", item: folder.appendingPathComponent("processing.log"))
                        ForEach(results, id: \.self) { result in
                            HStack {
                                Button(result.lastPathComponent) { dismiss(); onPreview(result) }
                                Spacer()
                                ShareLink(item: result) { Image(systemName: "square.and.arrow.up") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Siril 本地处理")
            .toolbar { Button("完成") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $showCommands) {
                CommandBrowser { name in
                    script += (script.hasSuffix("\n") || script.isEmpty ? "" : "\n") + name + "\n"
                }
            }
            .fileImporter(isPresented: $importingScript, allowedContentTypes: [.item]) { selection in
                do {
                    let url = try selection.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard ["ssf", "txt"].contains(url.pathExtension.lowercased()) else {
                        throw EngineError.failed("请选择 .ssf 或 .txt 脚本")
                    }
                    script = try String(contentsOf: url, encoding: .utf8)
                    status = "已导入 \(url.lastPathComponent)，请检查工作目录与文件路径"
                } catch { status = error.localizedDescription }
            }
        }
    }

    @MainActor private func run() async {
        busy = true
        UIApplication.shared.isIdleTimerDisabled = true
        status = "准备处理文件"
        results = []
        folder = nil
        log = ""
        defer {
            logTask?.cancel()
            log = SirilEngine.processingLog()
            busy = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            let job = try await engine.prepareJob(files: files, script: script)
            folder = job.folder
            status = "处理期间请保持 App 在前台"
            logTask = Task { @MainActor in
                while !Task.isCancelled {
                    log = SirilEngine.processingLog()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            results = try await engine.run(job)
            status = "Siril 已完成处理，可预览或导出 FITS"
        } catch {
            status = error.localizedDescription
            if let folder { results = (try? await engine.resultFiles(in: folder)) ?? [] }
        }
    }
}

struct CommandBrowser: View {
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var entries: [(name: String, usage: String)] {
        String(cString: siril_command_catalog()).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.usage.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List(entries, id: \.name) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.name).font(.headline)
                    Text(entry.usage).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("插入命令名称") { insert(entry.name); dismiss() }
                }
            }
            .searchable(text: $query, prompt: "搜索命令或参数")
            .navigationTitle("Siril 原生命令")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
