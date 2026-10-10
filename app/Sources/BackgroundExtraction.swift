// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct BackgroundSettings: Codable, Equatable, Sendable {
    var method = 0
    var interpolation = 0
    var degree = 1
    var correction = 0
    var smoothing = 0.5
    var dither = false
    var perLine = 20
    var tolerance = 2.0
    var randomize = false
    var gradientDescent = false
    var border = 0.0
    var borderPercent = true
    var keepSamples = false
    var scale = 5.0
    var smoothness = 1.0
    var protect = true
    var protectThreshold = 0.05
    var protectAmount = 0.5
    var simplified = false
    var autoDegree = 1
    var downsample = 4
    var native: SirilBackgroundOptions {
        var o = SirilBackgroundOptions()
        o.method = Int32(method); o.interpolation = Int32(interpolation)
        o.degree = Int32(degree); o.correction = Int32(correction)
        o.smoothing = smoothing; o.dither = dither ? 1 : 0
        o.scale = scale; o.smoothness = smoothness; o.protect = protect ? 1 : 0
        o.protect_threshold = protectThreshold; o.protect_amount = protectAmount
        o.simplified = simplified ? 1 : 0; o.auto_degree = Int32(autoDegree)
        o.downsample = Int32(downsample)
        return o
    }
}

actor BackgroundEngine {
    private var session: OpaquePointer?
    deinit { if let session { siril_background_free(session) } }

    func open(_ url: URL) throws {
        if let session { siril_background_free(session) }
        session = nil
        var error = [CChar](repeating: 0, count: 1024)
        let capacity = error.count
        session = url.path.withCString { siril_background_open($0, &error, capacity) }
        guard session != nil else { throw EngineError.failed(String(cString: error)) }
    }
    private func handle() throws -> OpaquePointer {
        guard let session else { throw EngineError.failed("还没有打开图像") }
        return session
    }
    func samples() throws -> [SampleMarker] {
        let session = try handle()
        let count = siril_background_samples(session, nil, 0)
        var values = [SirilBackgroundSample](repeating: SirilBackgroundSample(), count: count)
        siril_background_samples(session, &values, count)
        return values.enumerated().map { i, value in
            SampleMarker(id: i, x: value.x, y: value.y, size: Double(value.size),
                         median: [value.median.0, value.median.1, value.median.2])
        }
    }
    func generate(_ settings: BackgroundSettings) throws {
        let session = try handle()
        let previous = settings.keepSamples ? try samples() : []
        var error = [CChar](repeating: 0, count: 1024)
        let capacity = error.count
        guard siril_background_generate(session, Int32(settings.perLine), settings.tolerance,
            settings.randomize ? 1 : 0, settings.gradientDescent ? 1 : 0,
            settings.border, settings.borderPercent ? 1 : 0, &error, capacity) != 0 else {
            throw EngineError.failed(String(cString: error))
        }
        let generated = try samples()
        for point in previous where !generated.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 1 }) {
            _ = siril_background_add(session, point.x, point.y, 0)
        }
    }
    func add(x: Double, y: Double, descent: Bool) throws {
        guard siril_background_add(try handle(), x, y, descent ? 1 : 0) != 0 else {
            throw EngineError.failed("采样框必须完全位于图像内；请离边缘至少 13 像素。")
        }
    }
    func remove(_ index: Int) throws {
        guard siril_background_remove(try handle(), index) != 0 else { throw EngineError.failed("采样点已不存在") }
    }
    func clear() throws { siril_background_clear(try handle()) }
    func compute(_ settings: BackgroundSettings) throws {
        var options = settings.native
        var error = [CChar](repeating: 0, count: 1024)
        let capacity = error.count
        guard siril_background_compute(try handle(), &options, &error, capacity) != 0 else {
            throw EngineError.failed(String(cString: error).isEmpty ? "背景计算失败，请检查参数" : String(cString: error))
        }
    }
    func preview(view: Int, channel: Int, automatic: Bool) throws -> PreviewBytes {
        var preview = SirilPreview()
        guard siril_background_preview(try handle(), Int32(view), Int32(channel), automatic ? 1 : 0, &preview) != 0,
              let pixels = preview.rgba else { throw EngineError.failed("无法显示背景预览，请先计算模型") }
        defer { siril_preview_free(&preview) }
        return PreviewBytes(data: Data(bytes: pixels, count: Int(preview.width * preview.height) * 4),
                            width: Int(preview.width), height: Int(preview.height))
    }
    func save(file: FITSRecord, settings: BackgroundSettings) throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jobs").appendingPathComponent(UUID().uuidString)
        let process = root.appendingPathComponent("process")
        try FileManager.default.createDirectory(at: process, withIntermediateDirectories: true)
        let output = process.appendingPathComponent("result.fits")
        let session = try handle()
        guard output.path.withCString({ siril_background_write(session, $0) }) != 0 else {
            throw EngineError.failed("Siril 无法保存校正结果")
        }
        struct Recipe: Codable {
            let sourceName: String
            let sourceWidth: Int
            let sourceHeight: Int
            let settings: BackgroundSettings
            let points: [[Double]]
        }
        let recipe = Recipe(sourceName: file.displayName, sourceWidth: file.width, sourceHeight: file.height,
                            settings: settings, points: try samples().map { [$0.x, $0.y] })
        try JSONEncoder().encode(recipe).write(to: root.appendingPathComponent("background.json"), options: .atomic)
        let state = JobState(created: Date(), updated: Date(), state: "已完成", inputCount: 1, message: "交互式背景提取")
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("job.json"), options: .atomic)
        try SirilEngine.processingLog().write(to: root.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
        try "# 交互式背景提取。采样坐标和完整参数见 background.json；此任务通过原版图像接口执行。\n"
            .write(to: root.appendingPathComponent("processing.ssf"), atomically: true, encoding: .utf8)
        return output
    }
}

extension PreviewBytes {
    var uiImage: UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct BackgroundExtractionView: View {
    let file: FITSRecord
    let onPreview: (URL) -> Void
    @State private var engine = BackgroundEngine()
    @Environment(\.dismiss) private var dismiss
    @State private var settings = BackgroundSettings()
    @State private var markers: [SampleMarker] = []
    @State private var image: UIImage?
    @State private var busy = false
    @State private var computed = false
    @State private var status = ""
    @State private var view = 0
    @State private var channel = -1
    @State private var automatic = true
    @State private var editMode = 0
    @State private var selected: Int?
    @State private var output: URL?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > 800 {
                    HStack(spacing: 0) { imagePanel; controls.frame(width: 340) }
                } else {
                    VStack(spacing: 0) { imagePanel.frame(height: geometry.size.height * 0.48); controls }
                }
            }
            .navigationTitle("背景提取")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .task { await perform {
                try await engine.open(file.url)
                if ProcessInfo.processInfo.environment["SIRIL_SELF_TEST"] == "1" {
                    settings.perLine = 8
                    try await engine.generate(settings)
                    markers = try await engine.samples()
                }
                try await refresh()
                if ProcessInfo.processInfo.environment["SIRIL_SELF_TEST"] == "1", image != nil {
                    let ready = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("simulator-background-ready.txt")
                    try "PASS: interactive background view loaded image and sample overlay\n"
                        .write(to: ready, atomically: true, encoding: .utf8)
                }
            } }
            .onChange(of: view) { _, _ in Task { await perform { try await refresh() } } }
            .onChange(of: channel) { _, _ in Task { await perform { try await refresh() } } }
            .onChange(of: automatic) { _, _ in Task { await perform { try await refresh() } } }
            .onChange(of: settings) { _, _ in computed = false; output = nil; view = 0 }
        }
    }
    private var imagePanel: some View {
        VStack(spacing: 8) {
            Picker("显示", selection: $view) {
                Text("原图").tag(0)
                Text("校正结果").tag(1).disabled(!computed)
                Text("背景模型").tag(2).disabled(!computed)
            }.pickerStyle(.segmented).disabled(busy).padding(.horizontal)
            if let image {
                ZoomableImageCanvas(image: image, samples: settings.method == 0 && view == 0 ? markers : [],
                    imageWidth: Double(file.width), imageHeight: Double(file.height), selected: selected,
                    onTap: { x, y in
                        guard !busy, view == 0, settings.method == 0 else { return }
                        tapped(x, y)
                    })
                    .background(.black)
            } else { ProgressView("读取图像").frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack {
                if file.channels == 3 {
                    Picker("通道", selection: $channel) {
                        Text("RGB").tag(-1); Text("R").tag(0); Text("G").tag(1); Text("B").tag(2)
                    }.pickerStyle(.segmented)
                }
                Toggle("自动拉伸显示", isOn: $automatic)
            }.disabled(busy).padding(.horizontal)
            Text("双指缩放与拖动查看图像；显示拉伸不改变 FITS 像素。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
    private var controls: some View {
        Form {
            Section("方法与校正") {
                Picker("建模方法", selection: $settings.method) {
                    Text("采样点").tag(0); Text("自动渐变移除").tag(1)
                }
                Picker("校正", selection: $settings.correction) {
                    Text("减法 Subtraction").tag(0); Text("除法 Division").tag(1)
                }
                Toggle("抖动 Dither", isOn: $settings.dither)
            }.disabled(busy)
            if settings.method == 0 { sampleControls; interpolationControls }
            else { automaticControls }
            Section("计算与应用") {
                if busy { ProgressView("Siril 正在处理") }
                Button("计算背景模型") {
                    Task { await perform {
                        try await engine.compute(settings)
                        computed = true; view = 1; output = nil
                        try await refresh()
                        status = "已计算。可比较原图、背景模型和校正结果，再应用。"
                    } }
                }.disabled(busy || (settings.method == 0 && markers.isEmpty))
                Button("应用并另存 FITS") {
                    Task { await perform {
                        output = try await engine.save(file: file, settings: settings)
                        status = "已另存校正结果，原图保留。"
                    } }
                }.disabled(busy || !computed)
                if let output {
                    Button("打开校正结果") { dismiss(); onPreview(output) }
                    ShareLink("导出结果 FITS", item: output)
                }
                if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
            }
        }
    }
    private var sampleControls: some View {
        Section("采样点：\(markers.count) 个 · 25 × 25 像素") {
            Picker("轻点操作", selection: $editMode) {
                Text("添加").tag(0); Text("选择").tag(1); Text("删除").tag(2)
            }.pickerStyle(.segmented)
            Text("在原图上轻点，避开星点、星云和图像边缘。可先生成采样点，再选择或删除不合适的点。")
                .font(.caption)
            if let selected, let point = markers.first(where: { $0.id == selected }) {
                Text("点 \(selected + 1)：X \(Int(point.x))，Y \(Int(point.y))")
                Text("中值：" + point.median.prefix(file.channels).map { $0.formatted(.number.precision(.fractionLength(6))) }.joined(separator: " / "))
                    .font(.caption).textSelection(.enabled)
                Button("删除选中采样点", role: .destructive) { delete(selected) }
            }
            Stepper("\(settings.randomize ? "内部随机点数" : "每行采样点")：\(settings.perLine)", value: $settings.perLine, in: 5...100)
            numberSlider("容差", value: $settings.tolerance, range: 0.01...6)
            Toggle("随机暗区采样", isOn: $settings.randomize)
            Toggle("优化到附近暗区", isOn: $settings.gradientDescent)
            Toggle("保留已有采样点", isOn: $settings.keepSamples)
            numberSlider("排除边缘", value: $settings.border, range: settings.borderPercent ? 0...45 : 0...Double(max(0, min(file.width, file.height) / 2 - 14)))
            Toggle("边缘按百分比", isOn: $settings.borderPercent)
            Button("生成采样点") {
                Task { await perform {
                    try await engine.generate(settings)
                    try await changedSamples()
                    status = "已生成 \(markers.count) 个采样点，请检查并避开目标结构。"
                } }
            }
            Button("清空采样点", role: .destructive) {
                Task { await perform { try await engine.clear(); try await changedSamples() } }
            }
        }.disabled(busy)
    }
    private var interpolationControls: some View {
        Section("插值") {
            Picker("插值方法", selection: $settings.interpolation) {
                Text("RBF 径向基函数").tag(0); Text("多项式").tag(1)
            }
            if settings.interpolation == 0 { numberSlider("平滑度", value: $settings.smoothing, range: 0...1) }
            else { Stepper("多项式阶数：\(settings.degree)", value: $settings.degree, in: 1...4) }
        }.disabled(busy)
    }
    private var automaticControls: some View {
        Section("自动渐变模型") {
            numberSlider("模型尺度", value: $settings.scale, range: 1...10)
            numberSlider("额外平滑", value: $settings.smoothness, range: 0...3)
            Toggle("保护目标结构", isOn: $settings.protect)
            if settings.protect {
                numberSlider("保护阈值", value: $settings.protectThreshold, range: 0...1)
                numberSlider("保护范围", value: $settings.protectAmount, range: 0...1)
            }
            Toggle("先去除多项式模型", isOn: $settings.simplified)
            if settings.simplified { Stepper("预处理阶数：\(settings.autoDegree)", value: $settings.autoDegree, in: 1...6) }
            Picker("内部降采样", selection: $settings.downsample) {
                ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)×").tag($0) }
            }
        }.disabled(busy)
    }
    private func numberSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: value.wrappedValue.formatted(.number.precision(.fractionLength(3))))
            Slider(value: value, in: range)
        }
    }
    @MainActor private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do { try await action() } catch { status = error.localizedDescription }
    }
    @MainActor private func refresh() async throws {
        image = try await engine.preview(view: view, channel: channel, automatic: automatic).uiImage
    }
    @MainActor private func changedSamples() async throws {
        markers = try await engine.samples(); selected = nil; computed = false; output = nil; view = 0
        try await refresh()
    }
    @MainActor private func tapped(_ x: Double, _ y: Double) {
        let nearest = markers.min { hypot($0.x - x, $0.y - y) < hypot($1.x - x, $1.y - y) }
        if editMode == 1 { selected = nearest?.id; return }
        if editMode == 2 { if let nearest { delete(nearest.id) }; return }
        Task { await perform {
            try await engine.add(x: x, y: y, descent: settings.gradientDescent)
            try await changedSamples()
        } }
    }
    @MainActor private func delete(_ index: Int) {
        Task { await perform { try await engine.remove(index); try await changedSamples() } }
    }
}
