// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

extension BackgroundSettings {
    static var sequenceDefaults: Self {
        var settings = Self(); settings.interpolation = 1; settings.tolerance = 1; settings.dither = true
        return settings
    }
    var sampling: SirilBackgroundSampling {
        var s = SirilBackgroundSampling()
        s.per_line = Int32(perLine); s.tolerance = tolerance
        s.randomize = randomize ? 1 : 0; s.gradient_descent = gradientDescent ? 1 : 0
        s.border = border; s.border_percent = borderPercent ? 1 : 0
        return s
    }
}
struct SequenceBackgroundHistory: Codable, Equatable, Sendable {
    let source: SequenceLocation
    var current = BackgroundSettings.sequenceDefaults
    var past: [BackgroundSettings] = []
    var future: [BackgroundSettings] = []
    mutating func record(_ settings: BackgroundSettings) {
        guard settings != current else { return }
        past.append(current); past = Array(past.suffix(30)); current = settings; future = []
    }
    mutating func undo() { if let settings = past.popLast() { future.append(current); current = settings } }
    mutating func redo() { if let settings = future.popLast() { past.append(current); current = settings } }
}
struct SequenceBackgroundRecipe: Codable, Sendable {
    let source: SequenceLocation
    let output: SequenceLocation
    let settings: BackgroundSettings
}
struct SequenceBackgroundRun: Identifiable, Sendable {
    let folder: URL
    let state: JobState
    let output: SequenceLocation?
    var id: String { folder.lastPathComponent }
}
extension SirilEngine {
    func sequenceBackgroundRuns(_ location: SequenceLocation) throws -> [SequenceBackgroundRun] {
        let folder = try owned("SequenceRuns", under: sequenceFolder(location).deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap { candidate in
            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                  let run = try? owned(candidate.lastPathComponent, under: folder),
                  let recipe = try? JSONDecoder().decode(SequenceBackgroundRecipe.self, from: Data(contentsOf: owned("background.json", under: run))),
                  recipe.source == location,
                  var state = try? JSONDecoder().decode(JobState.self, from: Data(contentsOf: owned("job.json", under: run))) else { return nil }
            if state.state == "运行中" { state.state = "处理被中断" }
            let process = try sequenceFolder(location)
            let available = FileManager.default.fileExists(atPath: try owned(recipe.output.name, under: process).path)
            if !available && state.state == "已完成" { state.state = "输出已删除" }
            return SequenceBackgroundRun(folder: run, state: state, output: state.state == "已完成" && available ? recipe.output : nil)
        }.sorted { $0.state.created > $1.state.created }
    }

    private func backgroundHistoryURL(_ location: SequenceLocation) throws -> URL {
        let job = try sequenceFolder(location).deletingLastPathComponent()
        let folder = try owned("SequenceEdits", under: job)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try owned(location.name + ".background.json", under: folder)
    }
    func sequenceBackgroundHistory(_ location: SequenceLocation) throws -> SequenceBackgroundHistory {
        _ = try inspectSequence(location)
        let url = try backgroundHistoryURL(location)
        guard FileManager.default.fileExists(atPath: url.path) else { return SequenceBackgroundHistory(source: location) }
        let history = try JSONDecoder().decode(SequenceBackgroundHistory.self, from: Data(contentsOf: url))
        guard history.source == location, history.past.count <= 30, history.future.count <= 30 else {
            throw EngineError.failed("背景参数历史与序列不匹配。")
        }
        return history
    }
    func saveSequenceBackgroundHistory(_ history: SequenceBackgroundHistory) throws {
        try JSONEncoder().encode(history).write(to: backgroundHistoryURL(history.source), options: .atomic)
    }
    func openSequenceBackground(_ location: SequenceLocation, index: Int, into preview: BackgroundEngine) async throws {
        _ = try inspectSequence(location)
        try await preview.openSequence(directory: sequenceFolder(location), name: location.name, index: index)
    }
    func applySequenceBackground(_ location: SequenceLocation, settings: BackgroundSettings) throws -> SequenceLocation {
        let snapshot = try inspectSequence(location)
        guard snapshot.info.included >= 1 else { throw EngineError.failed("请至少选择一张参与帧。") }
        let process = try sequenceFolder(location), job = process.deletingLastPathComponent()
        let folder = try owned(UUID().uuidString, under: try owned("SequenceRuns", under: job))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = "b_" + folder.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
        let output = SequenceLocation(job: location.job, name: prefix + location.name)
        try JSONEncoder().encode(SequenceBackgroundRecipe(source: location, output: output, settings: settings))
            .write(to: folder.appendingPathComponent("background.json"), options: .atomic)
        try Data(contentsOf: process.appendingPathComponent(location.name))
            .write(to: folder.appendingPathComponent("source.seq"), options: .atomic)
        try "# 原版 GUI 序列背景接口；每帧独立采样。完整可重放参数见 background.json。此文件为记录，不是可执行脚本。\n"
            .write(to: folder.appendingPathComponent("processing.txt"), atomically: true, encoding: .utf8)
        let title = "序列背景提取"
        let state = JobState(created: Date(), updated: Date(), state: "运行中", inputCount: Int(snapshot.info.included), message: title)
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("job.json"), options: .atomic)
        var options = settings.native, sampling = settings.sampling
        var error = [CChar](repeating: 0, count: 4096)
        let capacity = error.count
        activeJobIDs.insert(location.job)
        let success = process.path.withCString { directory in location.name.withCString { name in prefix.withCString {
            siril_sequence_background(directory, name, $0, &options, &sampling, &error, capacity)
        } } }
        activeJobIDs.remove(location.job)
        try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
        do {
            guard success != 0 else { throw EngineError.failed(String(cString: error)) }
            let generated = try inspectSequence(output)
            let selected = snapshot.frames.filter(\.included)
            guard generated.info.count == snapshot.info.included, generated.info.layers == snapshot.info.layers,
                  zip(generated.frames, selected).allSatisfy({ $0.0.native.width == $0.1.native.width && $0.0.native.height == $0.1.native.height }) else {
                throw EngineError.failed("部分帧处理失败或输出尺寸、通道不符。预期 \(snapshot.info.included) 张，实际 \(generated.info.count) 张；请查看本次日志。")
            }
            // Regular numbered FITS keep original filenum. Containers reindex.
            if snapshot.info.type == 0 {
                guard generated.frames.map({ $0.native.file_number }) == selected.map({ $0.native.file_number }) else {
                    throw EngineError.failed("输出帧编号与参与帧不匹配。")
                }
            }
            // Read every output with the original sequence reader before success.
            for frame in generated.frames {
                guard let image = process.path.withCString({ directory in output.name.withCString {
                    siril_sequence_frame(directory, $0, Int32(frame.id), &error, capacity)
                } }) else { throw EngineError.failed(String(cString: error)) }
                siril_image_free(image)
            }
            let reference = snapshot.info.reference >= 0 ? selected.firstIndex(where: { $0.id == Int(snapshot.info.reference) }) ?? -1 : -1
            try editSequence(output, selection: SequenceSelection(included: Array(repeating: true, count: generated.frames.count), reference: reference))
            try JSONEncoder().encode(output).write(to: folder.appendingPathComponent("output-sequence.json"), options: .atomic)
            try writeJobState(folder, state: "已完成", message: title)
            return output
        } catch {
            try? writeJobState(folder, state: "输出验证失败", message: error.localizedDescription)
            throw error
        }
    }
}

struct SequenceBackgroundView: View {
    let location: SequenceLocation
    let engine: SirilEngine
    let onOutput: @MainActor (SequenceLocation) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview = BackgroundEngine()
    @State private var snapshot: SequenceSnapshot?
    @State private var history: SequenceBackgroundHistory?
    @State private var settings = BackgroundSettings.sequenceDefaults
    @State private var sliderEditing = false
    @State private var index = 0
    @State private var view = 0
    @State private var channel = -1
    @State private var automatic = true
    @State private var computed = false
    @State private var busy = false
    @State private var applying = false
    @State private var image: UIImage?
    @State private var output: SequenceLocation?
    @State private var message = ""
    @State private var log = ""
    @State private var logTask: Task<Void, Never>?
    @State private var persistTask: Task<Void, Never>?
    private var binding: Binding<BackgroundSettings> {
        Binding(get: { settings }, set: { value in
            settings = value; computed = false; view = 0
            if !sliderEditing { record() }
        })
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > 800 {
                    HStack(spacing: 0) { imagePanel; controls.frame(width: 360) }
                } else { VStack(spacing: 0) { imagePanel.frame(height: geometry.size.height * 0.42); controls } }
            }
            .navigationTitle("序列背景提取")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { Task { await persistTask?.value; dismiss() } }.disabled(busy || sliderEditing)
                if applying { Button("中止", role: .destructive) { siril_cancel_processing() } }
            }
            .interactiveDismissDisabled(busy || sliderEditing)
            .task { await perform {
                snapshot = try await engine.inspectSequence(location)
                history = try await engine.sequenceBackgroundHistory(location)
                settings = history?.current ?? .sequenceDefaults
                index = max(0, Int(snapshot?.info.reference ?? 0))
                try await loadFrame()
                if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] == "background" {
                    try await preview.computeSequence(settings); computed = true; view = 1
                    try await refresh()
                    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    try "PASS: native sequence background view loaded original frame, exact sequence-hook correction preview and full model controls\n"
                        .write(to: root.appendingPathComponent("simulator-sequence-background-ready.txt"), atomically: true, encoding: .utf8)
                }
            } }
            .onChange(of: index) { _, _ in Task { await perform { try await loadFrame() } } }
            .onChange(of: view) { _, _ in Task { await perform { try await refresh() } } }
            .onChange(of: channel) { _, _ in Task { await perform { try await refresh() } } }
            .onChange(of: automatic) { _, _ in Task { await perform { try await refresh() } } }
            .onChange(of: scenePhase) { _, phase in if phase != .active && sliderEditing { sliderEditing = false; record() } }
        }
    }
    private var imagePanel: some View {
        VStack {
            if let snapshot {
                Picker("预览帧", selection: $index) {
                    ForEach(snapshot.frames) { frame in Text("第 \(frame.id + 1) 帧 · \(frame.included ? "参与" : "排除")").tag(frame.id) }
                }.padding(.horizontal)
            }
            Picker("显示", selection: $view) {
                Text("原图").tag(0); Text("校正结果").tag(1).disabled(!computed)
                Text("背景模型").tag(2).disabled(!computed)
            }.pickerStyle(.segmented).padding(.horizontal)
            if let image, let snapshot {
                ZoomableImageCanvas(image: image, samples: [], imageWidth: Double(snapshot.frames[index].native.width),
                    imageHeight: Double(snapshot.frames[index].native.height), selected: nil, onTap: { _, _ in })
            } else { ProgressView("读取序列帧").frame(maxWidth: .infinity, maxHeight: .infinity) }
            if snapshot?.info.layers == 3 {
                Picker("显示通道", selection: $channel) { Text("RGB").tag(-1); Text("R").tag(0); Text("G").tag(1); Text("B").tag(2) }
                    .pickerStyle(.segmented).padding(.horizontal)
            }
            Toggle("自动拉伸显示", isOn: $automatic).padding(.horizontal)
            Text("逐帧重新采样；手动选点请用单张背景提取。预览不修改原图。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }.disabled(busy)
    }
    private var controls: some View {
        Form {
            Section("参与帧与编辑历史") {
                Text("当前参与：\(snapshot?.info.included ?? 0) / \(snapshot?.info.count ?? 0)")
                HStack {
                    Button("撤销", systemImage: "arrow.uturn.backward") { replay(redo: false) }.disabled(history?.past.isEmpty != false)
                    Spacer()
                    Button("重做", systemImage: "arrow.uturn.forward") { replay(redo: true) }.disabled(history?.future.isEmpty != false)
                }.buttonStyle(.bordered).disabled(sliderEditing)
                Text("参数保留最近 30 步，关闭后可继续撤销。每次应用生成新序列，旧结果保留。")
                    .font(.caption)
                if snapshot?.info.drizzle != 0 {
                    Text("建议在 Drizzle 前做背景校正。校正输出是普通序列；原 Drizzle 序列及权重保留，仍可用于带权叠加。")
                        .font(.caption)
                }
            }
            BackgroundModelControls(settings: binding, onSliderEditing: editing)
            if settings.method == 0 {
                Section("逐帧采样 · 25 × 25 像素") {
                    Stepper("\(settings.randomize ? "内部随机点数" : "每行采样点")：\(settings.perLine)", value: binding.perLine, in: 2...100)
                    BatchNumber(title: "容差", value: binding.tolerance)
                    Toggle("随机暗区采样", isOn: binding.randomize)
                    Toggle("优化到附近暗区", isOn: binding.gradientDescent)
                    BatchNumber(title: "排除边缘", value: binding.border)
                    Toggle("边缘按百分比", isOn: binding.borderPercent)
                    Text("Bayer 采样模型会拆分四个子通道分别校正；自动模型按原版作为单色处理。校准后原始帧通常采用一阶多项式。")
                        .font(.caption)
                }
            }
            Section("预览与整组应用") {
                Button("计算当前帧预览") { Task { await perform {
                    computed = false; view = 0
                    try await refresh() // A failed computation must keep the displayed original.
                    try await preview.computeSequence(settings); computed = true; view = 1
                    try await refresh(); message = "已用原版序列算法计算当前帧。随机采样或抖动时，整组输出可能与预览略有差异。"
                } } }
                Button("应用到全部参与帧") { Task { await perform {
                    await persistTask?.value
                    applying = true; defer { applying = false }
                    let result = try await engine.applySequenceBackground(location, settings: settings)
                    output = result; try await onOutput(result)
                    message = "全部参与帧已验证；关闭此页将切换到校正输出，可撤销处理结果。"
                } } }.disabled(snapshot?.info.included == 0 || sliderEditing)
                if let output { Text("已生成 \(output.name)").textSelection(.enabled) }
                if busy { ProgressView("Siril 正在处理") }
                if !message.isEmpty { Text(message).textSelection(.enabled) }
            }
            if !log.isEmpty { Section("原版处理日志") { Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
        }.disabled(busy)
    }
    private func editing(_ value: Bool) {
        sliderEditing = value
        if !value { record() }
    }
    private func record() {
        guard var history else { return }
        history.record(settings); self.history = history; persist(history)
    }
    private func persist(_ history: SequenceBackgroundHistory) {
        let previous = persistTask
        persistTask = Task {
            await previous?.value
            do { try await engine.saveSequenceBackgroundHistory(history) }
            catch { message = "参数已生效，但历史保存失败：" + error.localizedDescription }
        }
    }
    private func replay(redo: Bool) {
        guard var history else { return }
        if redo { history.redo() } else { history.undo() }
        self.history = history; settings = history.current; computed = false; view = 0; persist(history)
        Task { await perform { try await refresh() } }
    }
    @MainActor private func loadFrame() async throws {
        computed = false; view = 0; image = nil
        try await engine.openSequenceBackground(location, index: index, into: preview)
        try await refresh()
    }
    @MainActor private func refresh() async throws { image = try await preview.preview(view: view, channel: channel, automatic: automatic).uiImage }
    @MainActor private func perform(_ action: @MainActor () async throws -> Void) async {
        guard !busy else { return }; busy = true; message = ""
        UIApplication.shared.isIdleTimerDisabled = true
        logTask = Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)); log = SirilEngine.processingLog() } }
        defer { busy = false; logTask?.cancel(); UIApplication.shared.isIdleTimerDisabled = false; log = SirilEngine.processingLog() }
        do { try await action() } catch { message = error.localizedDescription }
    }
}
