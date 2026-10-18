// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AberrationInspectorView: View {
    let file: FITSRecord
    @Environment(\.dismiss) private var dismiss
    @State private var engine = ImageAnalysisEngine()
    @AppStorage("aberrationSamplingPixels") private var sampling = 256
    @AppStorage("aberrationWindowPixels") private var window = 381
    @State private var display = NativeDisplaySettings.load()
    @State private var channel = -1
    @State private var panels: [AberrationPanel] = []
    @State private var images: [UIImage] = []
    @State private var opened = false
    @State private var busy = false
    @State private var message = ""
    @State private var renderTask: Task<Void, Never>?
    private let titles = ["左上", "上中", "右上", "左中", "中心", "右中", "左下", "下中", "右下"]
    var body: some View {
        NavigationStack {
            Form {
                Section("原版像差九宫格") {
                    Stepper("采样区域边长：\(sampling) px", value: $sampling, in: 127...1024, step: 16)
                    Stepper("显示宽度设置：\(window) px", value: $window, in: 300...1600, step: 30)
                    Picker("通道", selection: $channel) {
                        Text("RGB / 灰度").tag(-1)
                        if file.channels == 3 { Text("R").tag(0); Text("G").tag(1); Text("B").tag(2) }
                    }
                    NativeDisplayControls(settings: $display)
                    Button("恢复原版面板尺寸") { sampling = 256; window = 381 }
                }.disabled(busy)
                if busy { ProgressView("读取原始区域并应用统一显示变换") }
                if !message.isEmpty { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                if images.count == 9 {
                    Section {
                        ScrollView(.horizontal) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(CGFloat(window / 3)), spacing: 6), count: 3), spacing: 6) {
                                ForEach(0..<9, id: \.self) { index in
                                    VStack(spacing: 3) {
                                        Image(uiImage: images[index]).resizable().interpolation(.none)
                                            .frame(width: CGFloat(window / 3), height: CGFloat(window / 3)).background(.black)
                                        Text(titles[index]).font(.caption)
                                        Text(panels[index].region.description).font(.caption2.monospaced()).lineLimit(2)
                                    }
                                }
                            }.frame(width: CGFloat(window / 3 * 3 + 12))
                        }
                    }
                }
                Section {
                    Text("按原版位置读取四角、四边和中心；所有面板使用整张图相同的 STF、范围及颜色管理设置。采样大于图像时，超出范围的像素显示为黑色。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("像差检查 · Aberration Inspector").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .task {
                do {
                    _ = try await engine.open(file.url); try Task.checkCancellation(); opened = true
                    if ProcessInfo.processInfo.environment["SIRIL_ANALYSIS_VIEW_CHECK"] == "1" {
                        sampling = 256; window = 381; channel = -1; display = NativeDisplaySettings()
                    }
                    if !(127...1024).contains(sampling) { sampling = 256 }
                    if !(300...1600).contains(window) { window = 381 }
                    schedule()
                } catch { message = error.localizedDescription }
            }
            .onChange(of: sampling) { _, _ in schedule() }
            .onChange(of: window) { _, _ in schedule() }
            .onChange(of: channel) { _, _ in schedule() }
            .onChange(of: display) { _, _ in display.save(); schedule() }
            .onDisappear { renderTask?.cancel() }
        }
    }
    @MainActor private func schedule() {
        guard opened else { return }
        renderTask?.cancel()
        let sampling = sampling, window = window, channel = channel, display = display
        renderTask = Task {
            guard !Task.isCancelled else { return }
            busy = true; message = ""; panels = []; images = []
            do {
                let result = try await engine.aberrationPanels(sampling: sampling, window: window, channel: channel, display: display)
                try Task.checkCancellation()
                let rendered = result.compactMap { $0.bytes.uiImage }
                guard rendered.count == 9 else { throw EngineError.failed("像差面板显示数据不完整。") }
                panels = result; images = rendered; busy = false
                if ProcessInfo.processInfo.environment["SIRIL_ANALYSIS_VIEW_CHECK"] == "1" {
                    let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-analysis-ready.txt")
                    try "PASS: native aberration inspector loaded all nine original pixel regions with one global display transform.\n"
                        .write(to: marker, atomically: true, encoding: .utf8)
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { busy = false; message = error.localizedDescription } }
        }
    }
}
