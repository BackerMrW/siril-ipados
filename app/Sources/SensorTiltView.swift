// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SensorTiltView: View {
    let source: CCDImageSource
    @Environment(\.dismiss) private var dismiss
    @State private var engine = ImageAnalysisEngine()
    @State private var image: UIImage?
    @State private var settings: StarSettings
    @State private var result: SensorTiltResult?
    @State private var display = NativeDisplaySettings.load()
    @State private var busy = false
    @State private var message = ""
    init(file: FITSRecord) {
        self.init(source: .file(file))
    }
    init(source: CCDImageSource) {
        self.source = source
        let channels = source.details.channels
        var defaults = StarSettings(); defaults.channel = channels == 3 ? 1 : 0; defaults.maximum = 2000
        var stored = UserDefaults.standard.data(forKey: "sensorTiltSettings").flatMap { try? JSONDecoder().decode(StarSettings.self, from: $0) } ?? defaults
        if ProcessInfo.processInfo.environment["SIRIL_ANALYSIS_VIEW_CHECK"] == "1" || ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_VIEW_CHECK"] == "1" {
            stored = defaults; stored.radius = 12
        }
        if !(0..<channels).contains(stored.channel) { stored.channel = defaults.channel }
        _settings = State(initialValue: stored)
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > 800 {
                    HStack(spacing: 0) { picture; controls.frame(width: 390) }
                } else { VStack { picture.frame(height: geometry.size.height * 0.45); controls } }
            }
            .navigationTitle("传感器倾斜分析").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .task { await open() }
            .onChange(of: settings) { _, _ in
                result = nil
                if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "sensorTiltSettings") }
                Task { await refresh() }
            }
            .onChange(of: display) { _, _ in Task { await refresh() } }
        }
    }
    private var picture: some View {
        VStack {
            if let image {
                ZoomableImageCanvas(image: image, samples: [], imageWidth: Double(source.details.width), imageHeight: Double(source.details.height),
                    sensorTilt: result, onTap: nil).background(.black)
            } else { ProgressView("读取原始图像").frame(maxWidth: .infinity, maxHeight: .infinity) }
            NativeDisplayControls(settings: $display).disabled(busy).padding(.horizontal)
            Text("双指缩放和平移；图形与数值均使用原图像素坐标。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var controls: some View {
        Form {
            Section {
                Text(source.details.title).font(.caption).textSelection(.enabled)
                Button("检测星点并计算倾斜") { Task { await calculate() } }.disabled(busy || image == nil)
                Button("恢复原版检测默认值") {
                    var value = StarSettings(); value.channel = source.details.channels == 3 ? 1 : 0; value.maximum = 2000
                    settings = value
                }.disabled(busy)
                if busy { ProgressView("原版星点拟合与分区统计") }
                if !message.isEmpty { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let result {
                Section("原版 CCD Inspector · 像素") {
                    LabeledContent("有效星点", value: String(result.stars))
                    metric("全图截尾均值 FWHM", result.mean)
                    metric("倾斜 FWHM 差", result.difference)
                    LabeledContent("倾斜比例", value: String(format: "%.0f%%", result.percent))
                    metric("中心 FWHM", result.centre); metric("外围 FWHM", result.outer)
                    metric("离轴像差 FWHM 差", result.offAxis)
                    ForEach(0..<4, id: \.self) { index in
                        metric(["左上", "右上", "左下", "右下"][index], result.quadrants[index])
                    }
                }
            }
            Section {
                Text("沿用原版 25% 截尾平均值；倾斜为四象限最大与最小 FWHM 之差，相对四象限均值计算比例。中心与外围采用对角半径的 25% 和 75% 分界，需要各区都有有效星点。修改检测参数后需重新计算。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            StarSettingsControls(settings: $settings, channels: source.details.channels, detectionOnly: true).disabled(busy)
        }
    }
    private func metric(_ name: String, _ value: Double) -> some View {
        LabeledContent(name, value: String(format: "%.4f px", value)).textSelection(.enabled)
    }
    @MainActor private func open() async {
        busy = true; defer { busy = false }
        do {
            _ = try await engine.openCCDSource(source)
            image = try await engine.preview(channel: settings.channel, settings: display).uiImage
            result = try await engine.sensorTilt(settings: settings)
            let environment = ProcessInfo.processInfo.environment
            let sequenceCheck = environment["SIRIL_SEQUENCE_VIEW_CHECK"] == "1" && environment["SIRIL_SEQUENCE_SECTION"] == "tilt"
            if (environment["SIRIL_ANALYSIS_VIEW_CHECK"] == "1" || sequenceCheck), image != nil, result != nil {
                let name = sequenceCheck ? "simulator-sequence-tilt-ready.txt" : "simulator-analysis-ready.txt"
                let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                let prefix = sequenceCheck ? "PASS: native sequence tilt" : "PASS: native analysis workspace tab 4"
                try (prefix + " loaded original star fit, original polygon and quadrant/central/outer FWHM values.\n")
                    .write(to: marker, atomically: true, encoding: .utf8)
            }
        } catch { result = nil; message = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        do { image = try await engine.preview(channel: settings.channel, settings: display).uiImage }
        catch { message = error.localizedDescription }
    }
    @MainActor private func calculate() async {
        guard !busy else { return }
        busy = true; message = ""; result = nil; defer { busy = false }
        do { result = try await engine.sensorTilt(settings: settings) }
        catch { message = error.localizedDescription }
    }
}
