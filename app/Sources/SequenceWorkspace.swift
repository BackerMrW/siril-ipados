// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts
import SirilCore

struct SequenceBrowserView: View {
    let engine: SirilEngine
    var job: String? = nil
    let onPreview: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locations: [SequenceLocation] = []
    var body: some View {
        NavigationStack {
            List {
                if locations.isEmpty { ContentUnavailableView("还没有序列", systemImage: "square.stack", description: Text("可在处理页用勾选的亮场建立序列，或运行转换、校准和配准流程。")) }
                ForEach(locations) { location in
                    NavigationLink {
                        SequenceWorkspace(location: location, engine: engine, onPreview: onPreview)
                    } label: {
                        VStack(alignment: .leading) { Text(location.name); Text("任务 \(location.job.prefix(8))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("原版序列")
            .toolbar { Button("完成") { dismiss() } }
            .task { locations = await engine.sequenceLocations(job: job) }
        }
    }
}

struct SequenceWorkspace: View {
    let location: SequenceLocation
    let engine: SirilEngine
    let onPreview: (URL) -> Void
    @State private var snapshot: SequenceSnapshot?
    @State private var editHistory: SequenceEditHistory?
    @State private var index = 0
    @State private var layer = 0
    @State private var channel = -1
    @State private var automatic = true
    @State private var image: UIImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var xMetric: SequenceMetric = .frame
    @State private var yMetric: SequenceMetric = .fwhm
    @State private var plotFrame: Double?
    @State private var from = 1
    @State private var to = 1
    @State private var busy = false
    @State private var message = ""
    @State private var options = BatchOptions.load()
    @State private var export: URL?
    @State private var result: URL?
    @State private var log = ""
    @State private var logTask: Task<Void, Never>?
    @State private var showStack = false

    var body: some View {
        ScrollViewReader { proxy in
        List {
            if let snapshot {
                Section("序列") {
                    Text(location.name).font(.headline)
                    LabeledContent("参与 / 总数", value: "\(snapshot.info.included) / \(snapshot.info.count)")
                    if snapshot.info.drizzle != 0 { Text("Drizzle 序列：叠加继续使用原版逐帧像素权重。") }
                    Picker("质量通道", selection: $layer) {
                        ForEach(0..<Int(snapshot.info.layers), id: \.self) { Text(snapshot.info.layers == 1 ? "单色" : ["红", "绿", "蓝"][$0]).tag($0) }
                    }
                }
                framePreview(snapshot)
                Section("参与帧和参考帧") {
                    Toggle("当前帧参与处理", isOn: Binding(get: { snapshot.frames[index].included }, set: { includeCurrent($0) }))
                    Picker("参考帧", selection: Binding(get: { Int(snapshot.info.reference) }, set: { reference in
                        var selection = snapshot.selection; selection.reference = reference
                        if reference >= 0 { selection.included[reference] = true }
                        change(selection)
                    })) {
                        Text("自动选择").tag(-1)
                        ForEach(snapshot.frames) { Text("第 \($0.id + 1) 帧").tag($0.id) }
                    }
                    HStack {
                        Button("撤销", systemImage: "arrow.uturn.backward") { perform { try await engine.editSequence(location, undo: true); await reload() } }.disabled(editHistory?.past.isEmpty != false)
                        Button("重做", systemImage: "arrow.uturn.forward") { perform { try await engine.editSequence(location, redo: true); await reload() } }.disabled(editHistory?.future.isEmpty != false)
                    }.buttonStyle(.borderless)
                    Text("排除只改变是否参与处理，原图仍保留。参考帧会自动设为参与；排除参考帧后改为自动选择。修改可以跨重启撤销、重做；新的修改会清除重做分支。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("序号"); TextField("从", value: $from, format: .number).keyboardType(.numberPad)
                        Text("至"); TextField("到", value: $to, format: .number).keyboardType(.numberPad)
                    }
                    HStack {
                        Button("包含范围") { includeRange(true) }; Button("排除范围") { includeRange(false) }
                        Button("全部包含") { includeRange(true, all: true) }
                    }.buttonStyle(.borderless)
                }
                qualityPlot(snapshot).id("sequence-quality")
                Section("原版测量与处理") {
                    BatchPicker(title: "配准变换", value: $options.transform)
                    Stepper("最少匹配星对：\(options.minimumPairs)", value: $options.minimumPairs, in: 4...2000)
                    Stepper("最多检测星点：\(options.maximumStars)", value: $options.maximumStars, in: 100...2000, step: 100)
                    Button("两遍星点配准：测量质量") { perform {
                        try await engine.measureSequence(location, options: options, layer: layer)
                        log = SirilEngine.processingLog(); await reload()
                    } }
                    Text("测量执行原版两遍配准，保存星点质量和变换矩阵。需要应用旋转、缩放或 Drizzle 时，请在批处理流程中生成配准输出，再选择对应输出序列。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("计算原版序列统计") { perform { export = try await engine.sequenceStatistics(location); log = SirilEngine.processingLog(); await reload() } }
                    Button("导出质量数据 CSV") { perform { export = try await engine.exportSequenceQuality(location, layer: layer) } }
                    if let export { ShareLink("分享 CSV", item: export) }
                    Button("设置参数并按当前选择叠加", systemImage: "square.stack.3d.up") { showStack = true }
                    Text("重新叠加会保存新的结果和日志，保留之前的结果，并复用该任务的序列文件。原始、校准后和配准后的序列彼此独立；请确认当前选择的是要叠加的序列。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let result {
                        Button("查看本次叠加结果") { onPreview(result) }
                        ShareLink("导出本次 FITS", item: result)
                    }
                }
                Section("逐帧列表") {
                    ForEach(snapshot.frames) { frame in
                        Button { index = frame.id } label: {
                            HStack {
                                Image(systemName: frame.included ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(frame.included ? .blue : .gray)
                                VStack(alignment: .leading) {
                                    Text("第 \(frame.id + 1) 帧 · 原编号 \(frame.native.file_number)")
                                    Text("\(yMetric.title)：\(formatted(frame.value(yMetric)))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if frame.id == Int(snapshot.info.reference) { Image(systemName: "star.fill").foregroundStyle(.purple) }
                                if frame.id == index { Image(systemName: "eye").foregroundStyle(.blue) }
                            }
                        }.foregroundStyle(.primary)
                    }
                }
            } else { ProgressView("读取原版序列") }
            if busy { Section { ProgressView("Siril 正在处理") } }
            if !message.isEmpty { Section("提示") { Text(message).textSelection(.enabled) } }
            if !log.isEmpty { Section("本次日志") { Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
        }
        .disabled(busy)
        .navigationBarBackButtonHidden(busy)
        .interactiveDismissDisabled(busy)
        .toolbar { if busy { Button("中止", role: .destructive) { siril_cancel_processing() } } }
        .navigationTitle("序列工作区")
        .task {
            await reload(); to = snapshot?.frames.count ?? 1
            if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_VIEW_CHECK"] == "1", snapshot != nil {
                for _ in 0..<60 where image == nil { try? await Task.sleep(for: .milliseconds(50)) }
                guard image != nil else { return }
                if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] == "quality" {
                    try? await Task.sleep(for: .milliseconds(400)); proxy.scrollTo("sequence-quality", anchor: .top)
                }
                try? await Task.sleep(for: .milliseconds(400))
                let section = ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] ?? "frames"
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? "PASS: native sequence \(section) workspace loaded original frames, preview and quality.\n".write(to: root.appendingPathComponent("simulator-sequence-\(section)-ready.txt"), atomically: true, encoding: .utf8)
            }
        }
        .onChange(of: index) { _, _ in refreshPreview() }
        .onChange(of: channel) { _, _ in refreshPreview() }
        .onChange(of: automatic) { _, _ in refreshPreview() }
        .onChange(of: layer) { _, _ in Task { await reload() } }
        .onDisappear { previewTask?.cancel(); logTask?.cancel() }
        .sheet(isPresented: $showStack) {
            NavigationStack {
                Form {
                    StackControls(options: $options)
                    Section { Button("按当前参与帧叠加") {
                        showStack = false
                        perform { result = try await engine.stackSequence(location, options: options, layer: layer); log = SirilEngine.processingLog(); await reload() }
                    } }
                }.navigationTitle("序列叠加")
                .toolbar { Button("完成") { showStack = false } }
            }
        }
        }
    }
    @ViewBuilder private func framePreview(_ snapshot: SequenceSnapshot) -> some View {
        Section("逐帧预览") {
            if let image {
                ZoomableImageCanvas(image: image, samples: [], imageWidth: Double(snapshot.frames[index].native.width), imageHeight: Double(snapshot.frames[index].native.height), onTap: nil)
                    .frame(height: 320).listRowInsets(EdgeInsets()).background(.black)
            } else { ProgressView("读取当前帧") }
            HStack {
                Button("上一帧", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0)
                Spacer(); Text("\(index + 1) / \(snapshot.frames.count)"); Spacer()
                Button("下一帧", systemImage: "chevron.right") { index += 1 }.disabled(index + 1 >= snapshot.frames.count)
            }.buttonStyle(.borderless)
            Picker("显示通道", selection: $channel) {
                Text("RGB / 灰度").tag(-1)
                if snapshot.info.layers == 3 { Text("红").tag(0); Text("绿").tag(1); Text("蓝").tag(2) }
            }
            Toggle("自动拉伸显示", isOn: $automatic)
        }
    }
    @ViewBuilder private func qualityPlot(_ snapshot: SequenceSnapshot) -> some View {
        Section("质量图与当前帧数据") {
            BatchPicker(title: "横轴", value: $xMetric)
            BatchPicker(title: "纵轴", value: $yMetric)
            let points = snapshot.frames.filter { $0.value(xMetric) != nil && $0.value(yMetric) != nil }
            if points.isEmpty { Text("此通道尚未测得对应数据。可执行星点配准或序列统计；不会把缺失数据画成 0。") }
            else {
                Chart(points) { frame in
                    PointMark(x: .value(xMetric.title, frame.value(xMetric)!), y: .value(yMetric.title, frame.value(yMetric)!))
                        .foregroundStyle(frame.id == Int(snapshot.info.reference) ? Color.purple : frame.included ? .blue : .gray)
                        .symbolSize(frame.id == index ? 100 : 35)
                }.frame(height: 240)
                    .chartXSelection(value: $plotFrame)
                    .onChange(of: plotFrame) { _, value in
                        if xMetric == .frame, let value, value.isFinite {
                            let frame = Int(value.rounded())
                            if (1...snapshot.frames.count).contains(frame) { index = frame - 1 }
                        }
                    }
                Text("蓝色：参与；灰色：排除；紫色：参考帧。横轴为帧序号时可拖动图表查看对应帧。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let frame = snapshot.frames[index]
            ForEach(SequenceMetric.allCases.filter { $0 != .frame }) { metric in
                LabeledContent(metric.title, value: formatted(frame.value(metric)))
            }
        }
    }
    private func formatted(_ value: Double?) -> String { value.map { String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "未测得" }
    @MainActor private func reload() async {
        do {
            snapshot = try await engine.inspectSequence(location, layer: layer)
            if let snapshot {
                index = min(index, snapshot.frames.count - 1)
                editHistory = try await engine.sequenceHistory(location, snapshot: snapshot)
                options.register = snapshot.frames.contains { $0.native.has_registration != 0 }
            }
            refreshPreview()
        } catch { message = error.localizedDescription }
    }
    @MainActor private func refreshPreview() {
        previewTask?.cancel(); image = nil
        let current = index, display = channel, automatic = automatic
        previewTask = Task {
            do {
                let bytes = try await engine.sequencePreview(location, index: current, channel: display, automatic: automatic)
                guard !Task.isCancelled else { return }
                image = bytes.uiImage
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    @MainActor private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = ""; previewTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = true
        logTask = Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)); log = SirilEngine.processingLog() } }
        Task {
            defer { busy = false; logTask?.cancel(); UIApplication.shared.isIdleTimerDisabled = false }
            do { try await action() } catch { message = error.localizedDescription }
        }
    }
    @MainActor private func change(_ selection: SequenceSelection) { perform { try await engine.editSequence(location, selection: selection); await reload() } }
    @MainActor private func includeCurrent(_ included: Bool) {
        guard var selection = snapshot?.selection else { return }
        selection.included[index] = included
        if !included && selection.reference == index { selection.reference = -1 }
        change(selection)
    }
    @MainActor private func includeRange(_ included: Bool, all: Bool = false) {
        guard var selection = snapshot?.selection else { return }
        let first = all ? 1 : from, last = all ? selection.included.count : to
        guard (1...selection.included.count).contains(first), last >= first, last <= selection.included.count else { message = "请输入有效的帧序号范围。"; return }
        for i in (first - 1)..<last { selection.included[i] = included }
        if selection.reference >= 0 && !selection.included[selection.reference] { selection.reference = -1 }
        change(selection)
    }
}
