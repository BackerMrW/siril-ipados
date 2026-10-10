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
        let isCFA = options.cfa || options.debayer
        if isCFA && lights.contains(where: { $0.channels != 1 }) {
            throw EngineError.failed("CFA 去马赛克只适用于单通道彩色相机原始图像；RGB 图像请关闭此选项。")
        }
        guard files.filter({ $0.role != .results }).allSatisfy({ $0.width == first.width && $0.height == first.height && $0.channels == first.channels }) else {
            throw EngineError.failed("亮场和校准帧的尺寸、通道数必须相同。")
        }
        if options.method == .mean && options.rejection != .none {
            guard lights.count >= 3 else { throw EngineError.failed("异常值剔除至少需要三张亮场；两张请选择不剔除或中位数。") }
            guard options.low.isFinite, options.high.isFinite, options.low >= 0, options.high >= 0,
                  !options.rejection.fractional || (options.low <= 1 && options.high <= 1) else {
                throw EngineError.failed("剔除参数必须为非负有限数；百分位和广义 ESD 参数必须在 0–1 之间。")
            }
            if options.rejection == .generalized && (options.low <= 0 || options.high <= 0 || options.high >= 1) {
                throw EngineError.failed("广义 ESD 的最大异常值比例须大于 0；显著性水平须大于 0 且小于 1。")
            }
        }
        let has: (FrameRole) -> Bool = { !(groups[$0] ?? []).isEmpty }
        if options.darkOptimization != .none {
            guard has(.darks), has(.biases) else { throw EngineError.failed("暗场优化需要同时勾选暗场和偏置；主暗场会先扣除偏置再缩放。") }
        }
        if options.cosmetic {
            guard has(.darks), first.channels == 1, options.coldSigma.isFinite, options.hotSigma.isFinite,
                  options.coldSigma >= 0, options.hotSigma >= 0, options.coldSigma > 0 || options.hotSigma > 0 else {
                throw EngineError.failed("主暗场坏点修正需要单通道数据和暗场；至少一个 Sigma 必须大于 0。")
            }
        }
        if isCFA == false && (options.equalizeCFA || options.fixXTrans) {
            throw EngineError.failed("CFA 均衡与 X-Trans 修复需要启用 CFA 原始数据选项。")
        }
        // Hidden options do not affect an unrelated stacking method.
        if options.method == .mean && options.weight == .noise && options.normalization == .none {
            throw EngineError.failed("噪声权重需要启用输入归一化。")
        }
        if options.register {
            guard (4...2000).contains(options.minimumPairs), (100...2000).contains(options.maximumStars),
                  options.minimumPairs <= options.maximumStars, (0...2).contains(options.layer),
                  options.scale.isFinite, (0.1...3).contains(options.scale) else {
                throw EngineError.failed("请检查配准星对、星数、通道和输出倍率范围。")
            }
            if options.interpolation == .none && (options.transform != .shift || options.scale != 1) {
                throw EngineError.failed("不插值只支持仅平移、输出倍率为 1 的配准。")
            }
            if let id = options.referenceID, !lights.contains(where: { $0.id == id }) {
                throw EngineError.failed("指定参考亮场未勾选；请重新选择参考帧或改为自动选择。")
            }
            for filter in options.filters where filter.enabled {
                guard filter.value.isFinite, filter.value > 0,
                      filter.limit != .percentage || filter.value <= 100,
                      filter.limit != .threshold || filter.metric != .round || filter.value <= 1 else {
                    throw EngineError.failed("质量阈值须大于 0；百分比不能超过 100，圆度绝对阈值不能超过 1。")
                }
            }
        }
        if options.method == .mean && [.nbstars, .wfwhm].contains(options.weight) && !options.register {
            throw EngineError.failed("星点数量和加权 FWHM 权重需要启用配准。")
        }
        if has(.darks) {
            let exposure = groups[.darks]![0].exposure
            guard exposure.isFinite, exposure > 0, groups[.darks]!.allSatisfy({ abs($0.exposure - exposure) <= 0.01 }) else {
                throw EngineError.failed("生成主暗场的各张暗场必须具有相同且有效的曝光时间。")
            }
            if options.darkOptimization == .none && !lights.allSatisfy({ abs($0.exposure - exposure) <= 0.01 }) {
                throw EngineError.failed("未启用暗场优化：亮场和暗场的曝光时间必须相同。")
            }
            if options.darkOptimization == .exposure && !lights.allSatisfy({ $0.exposure.isFinite && $0.exposure > 0 }) {
                throw EngineError.failed("按曝光缩放需要每张亮场的 FITS 中有有效曝光时间。")
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
        func number(_ value: Double) -> String { String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value) }
        func convert(_ role: FrameRole, _ base: String) {
            lines += ["cd \(role.rawValue)", "convert \(base) -out=../process", "cd ../process"]
        }
        for (role, base) in [(FrameRole.biases, "bias"), (.darks, "dark"), (.flatdarks, "flatdark")] where has(role) {
            if groups[role]!.count == 1 {
                lines += ["cd process", "load ../\(role.rawValue)/frame_00001.fits"]
                if role == .darks && options.darkOptimization != .none { lines += ["isub master_bias.fits"] }
                lines += ["save master_\(base).fits", "close", "cd .."]
            } else {
                convert(role, base)
                var source = base
                if role == .darks && options.darkOptimization != .none {
                    lines += ["calibrate dark -bias=master_bias.fits -prefix=bd_"]
                    source = "bd_dark"
                }
                lines += ["stack \(source) median -nonorm -out=master_\(base).fits", "cd .."]
            }
        }
        if has(.flats) {
            let calibration = has(.flatdarks) ? "-dark=master_flatdark.fits" : "-bias=master_bias.fits"
            if groups[.flats]!.count == 1 {
                // Upstream refuses a one-image regular sequence. Its single
                // calibration command writes a prefixed basename in the CWD.
                lines += ["cd process", "calibrate_single ../flats/frame_00001.fits \(calibration)\(isCFA ? " -cfa" : "") -prefix=pf_",
                          "load pf_frame_00001", "save master_flat.fits", "close"]
            } else {
                convert(.flats, "flat")
                lines += ["calibrate flat \(calibration)\(isCFA ? " -cfa" : "") -prefix=pp_",
                          "stack pp_flat median -norm=mul -out=master_flat.fits"]
            }
            lines += ["cd .."]
        }
        convert(.lights, "light")
        var calibration: [String] = []
        if has(.darks) { calibration += ["-dark=master_dark.fits"] }
        if has(.biases) && (!has(.darks) || options.darkOptimization != .none) { calibration += ["-bias=master_bias.fits"] }
        if has(.flats) { calibration += ["-flat=master_flat.fits"] }
        if isCFA { calibration += ["-cfa"] }
        if options.debayer { calibration += ["-debayer"] }
        if options.equalizeCFA && has(.flats) { calibration += ["-equalize_cfa"] }
        if options.fixXTrans { calibration += ["-fix_xtrans"] }
        if options.darkOptimization != .none { calibration += [options.darkOptimization == .exposure ? "-opt=exp" : "-opt"] }
        if options.cosmetic { calibration += ["-cc=dark", number(options.coldSigma), number(options.hotSigma)] }
        var sequence = "light"
        if !calibration.isEmpty {
            lines += ["calibrate light \(calibration.joined(separator: " ")) -prefix=pp_"]
            sequence = "pp_light"
        }
        if options.register {
            if let index = lights.firstIndex(where: { $0.id == options.referenceID }) { lines += ["setref \(sequence) \(index + 1)"] }
            let outputOptions = "-interp=\(options.interpolation.rawValue) -scale=\(number(options.scale))" +
                (options.interpolation.supportsClamp && !options.clamp ? " -noclamp" : "")
            let layer = first.channels == 1 && !options.debayer ? 0 : options.layer
            let registration = "-transf=\(options.transform.rawValue) -minpairs=\(options.minimumPairs) -maxstars=\(options.maximumStars) -layer=\(layer)"
            if options.twoPass {
                lines += ["register \(sequence) -2pass \(registration)",
                          "seqapplyreg \(sequence) \(outputOptions) -framing=\(options.framing.rawValue) -layer=\(layer)"]
            } else { lines += ["register \(sequence) \(registration) \(outputOptions)"] }
            sequence = "r_" + sequence
        }
        var stack = ["stack", sequence, options.method.rawValue]
        if options.method == .mean { stack += [options.rejection.rawValue, number(options.low), number(options.high)] }
        if options.method.supportsNormalization {
            stack += [options.normalization == .none ? "-nonorm" : "-norm=\(options.normalization.rawValue)"]
            if options.outputNormalization { stack += ["-output_norm"] }
            if options.normalization != .none {
                if options.fastNormalization { stack += ["-fastnorm"] }
                if options.equalizeRGB && (first.channels == 3 || options.debayer) { stack += ["-rgb_equal"] }
            }
        }
        if options.method == .mean {
            if options.weight != .none { stack += ["-weight=\(options.weight.rawValue)"] }
            if options.rejection != .none && options.maps != .none { stack += [options.maps == .separate ? "-rejmaps" : "-rejmap"] }
        }
        if options.register {
            for filter in options.filters where filter.enabled { stack += ["-filter-\(filter.metric.rawValue)=\(number(filter.value))\(filter.limit.suffix)"] }
        }
        stack += ["-32b", "-out=result.fits"]
        lines += [stack.joined(separator: " ")]
        return lines.joined(separator: "\n") + "\n"
    }
}

extension SirilEngine {
    func prepareJob(files: [FITSRecord], script: String, batchOptions: BatchOptions? = nil) throws -> ProcessingJob {
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
        try JSONEncoder().encode(files).write(to: folder.appendingPathComponent("inputs.json"), options: .atomic)
        if let batchOptions { try JSONEncoder().encode(batchOptions).write(to: folder.appendingPathComponent("batch-options.json"), options: .atomic) }
        try writeJobState(folder, state: "准备完成", count: files.count)
        return ProcessingJob(folder: folder, script: script)
    }

    func run(_ job: ProcessingJob) throws -> [URL] {
        activeJobIDs.insert(job.folder.lastPathComponent)
        defer { activeJobIDs.remove(job.folder.lastPathComponent) }
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
    let onPreview: (URL, UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = BatchOptions.load()
    @State private var generatedOptions: BatchOptions?
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
    @State private var showBackground = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section("本次使用勾选的文件") {
                    ForEach(FrameRole.allCases) { role in
                        LabeledContent(role.title, value: "\(files.filter { $0.role == role }.count) 张")
                    }
                    Text("暗场与亮场需匹配曝光、温度、增益和偏置；尺寸与拍摄模式也需一致。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Group { BatchControls(options: $options, lights: files.filter { $0.role == .lights }) }.disabled(busy)
                Section("批处理流程") {
                    Button("生成校准 → 配准 → 叠加脚本") {
                        do {
                            script = try SirilWorkflow.script(files: files, options: options)
                            generatedOptions = options
                            options.save()
                            status = "脚本已生成；执行以此处脚本文本为准。参数与输入列表会随任务保存。"
                        }
                        catch { status = error.localizedDescription }
                    }
                }.disabled(busy)
                Section("单张后期处理") {
                    Text("在图库中只勾选一张亮场或处理结果，然后生成后期脚本。输出另存为新的 FITS。")
                        .font(.caption).foregroundStyle(.secondary)
                    ImageToolControls(options: $tools)
                    Button("打开交互式背景提取（在图像上选点）") { showBackground = true }
                        .disabled(files.count != 1)
                    Button("生成单张处理脚本") {
                        do {
                            script = try ImageToolScript.make(files: files, options: tools)
                            generatedOptions = nil
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
                                Button(result.lastPathComponent) { dismiss(); onPreview(result, files.count == 1 ? files.first?.id : nil) }
                                Spacer()
                                ShareLink(item: result) { Image(systemName: "square.and.arrow.up") }
                            }
                        }
                    }
                }
            }
            .task {
                if ProcessInfo.processInfo.environment["SIRIL_BATCH_VIEW_CHECK"] == "1" {
                    let section = ProcessInfo.processInfo.environment["SIRIL_BATCH_SECTION"] ?? "batch"
                    options.twoPass = true
                    options.cosmetic = true
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo(section == "batch" ? "calibration" : section, anchor: .top)
                    try? await Task.sleep(for: .milliseconds(300))
                    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    try? "PASS: native advanced batch controls loaded at \(section).\n".write(to: root.appendingPathComponent("simulator-\(section)-ready.txt"), atomically: true, encoding: .utf8)
                }
            }
            }
            .navigationTitle("Siril 本地处理")
            .toolbar { Button("完成") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .onDisappear { options.save() }
            .task {
                if let id = options.referenceID, !files.contains(where: { $0.id == id && $0.role == .lights }) { options.referenceID = nil }
            }
            .sheet(isPresented: $showCommands) {
                CommandBrowser { name in
                    script += (script.hasSuffix("\n") || script.isEmpty ? "" : "\n") + name + "\n"
                }
            }
            .fullScreenCover(isPresented: $showBackground) {
                if let file = files.first, files.count == 1 {
                    BackgroundExtractionView(file: file) { result in dismiss(); onPreview(result, files.count == 1 ? files.first?.id : nil) }
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
                    generatedOptions = nil
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
            let job = try await engine.prepareJob(files: files, script: script, batchOptions: generatedOptions)
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
