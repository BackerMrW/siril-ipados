// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

extension ImageSelection {
    var native: SirilRegion { SirilRegion(x: Int32(x), y: Int32(y), width: Int32(width), height: Int32(height)) }
}

struct ImageDetails: Sendable {
    let width: Int, height: Int, channels: Int, bitpix: Int, gain: Int, offset: Int
    let exposure: Double, temperature: Double
    let object: String, bayer: String, header: String
    var hasCFA: Bool { channels == 1 && !bayer.isEmpty }
}
struct ChannelStatistics: Sendable {
    let total: UInt64, good: UInt64
    let values: [Double]
    let norm: Double
}
struct AnalysisSnapshot: Sendable {
    let statistics: [ChannelStatistics]
    let histograms: [[Double]]
}
struct PixelReading: Sendable {
    let x: Int, y: Int
    let values: [Float]
}

// Own one full-resolution image for the entire workspace session. Repeated
// pixel taps never reload FITS or read from the stretched/downsized preview.
actor ImageAnalysisEngine {
    private var image: OpaquePointer?
    deinit { if let image { siril_image_free(image) } }

    func open(_ url: URL) throws -> ImageDetails {
        if let image { siril_image_free(image); self.image = nil }
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        guard let image = url.path.withCString({ siril_image_read($0, &error, capacity) }) else {
            throw EngineError.failed(String(cString: error))
        }
        self.image = image
        var info = SirilImageInfo()
        guard siril_image_info(image, &info) != 0 else { throw EngineError.failed("无法读取图像信息") }
        let object = withUnsafePointer(to: &info.object) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        let bayer = withUnsafePointer(to: &info.bayer) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
        let required = siril_image_copy_header(image, nil, 0)
        let headerCapacity = max(1, Int(required))
        var header = [CChar](repeating: 0, count: headerCapacity)
        guard siril_image_copy_header(image, &header, headerCapacity) == required else {
            throw EngineError.failed("无法读取完整 FITS 文件头")
        }
        return ImageDetails(width: Int(info.width), height: Int(info.height), channels: Int(info.channels),
            bitpix: Int(info.working_bitpix), gain: Int(info.gain), offset: Int(info.offset),
            exposure: info.exposure, temperature: info.temperature, object: object, bayer: bayer,
            header: String(cString: header))
    }
    func preview(channel: Int, automatic: Bool) throws -> PreviewBytes {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var p = SirilPreview()
        guard siril_image_preview_display(image, 2048, Int32(channel), automatic ? 1 : 0, &p) != 0,
              let bytes = p.rgba else { throw EngineError.failed("无法生成图像预览") }
        defer { siril_preview_free(&p) }
        return PreviewBytes(data: Data(bytes: bytes, count: Int(p.width) * Int(p.height) * 4), width: Int(p.width), height: Int(p.height))
    }
    func analyze(region: ImageSelection?, perCFA: Bool) throws -> AnalysisSnapshot {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var raw = [SirilChannelStatistics](repeating: SirilChannelStatistics(), count: 3)
        var area = region?.native ?? SirilRegion()
        let count = region == nil ? siril_image_statistics(image, nil, perCFA ? 1 : 0, &raw) :
            siril_image_statistics(image, &area, perCFA ? 1 : 0, &raw)
        guard count > 0 else { throw EngineError.failed("Siril 统计计算失败，请检查图像和选区") }
        let stats = raw.prefix(Int(count)).map { s in
            ChannelStatistics(total: s.total, good: s.good,
                values: [s.mean, s.median, s.sigma, s.average_deviation, s.mad, s.sqrt_bwmv, s.minimum, s.maximum], norm: s.norm)
        }
        var info = SirilImageInfo()
        _ = siril_image_info(image, &info)
        var histograms: [[Double]] = []
        for channel in 0..<Int(info.channels) {
            var bins = [Double](repeating: 0, count: 512)
            let ok = region == nil ? siril_image_histogram(image, nil, Int32(channel), &bins, 512) :
                siril_image_histogram(image, &area, Int32(channel), &bins, 512)
            guard ok != 0 else { throw EngineError.failed("Siril 直方图计算失败") }
            histograms.append(bins)
        }
        return AnalysisSnapshot(statistics: stats, histograms: histograms)
    }
    func pixel(x: Int, y: Int) throws -> PixelReading {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var values = [Float](repeating: 0, count: 3)
        let channels = siril_image_pixel(image, Int32(x), Int32(y), &values)
        guard channels > 0 else { throw EngineError.failed("像素坐标超出图像范围") }
        return PixelReading(x: x, y: y, values: Array(values.prefix(Int(channels))))
    }
}

struct ImageAnalysisView: View {
    let file: FITSRecord
    @Binding var selection: ImageSelection?
    var initialTab = 0
    @Environment(\.dismiss) private var dismiss
    @State private var engine = ImageAnalysisEngine()
    @State private var details: ImageDetails?
    @State private var image: UIImage?
    @State private var snapshot: AnalysisSnapshot?
    @State private var pixel: PixelReading?
    @State private var selecting = false
    @State private var normalized = false // Original StatWindow defaults.
    @State private var perCFA = true
    @State private var channel = -1
    @State private var automatic = true
    @State private var logarithmic = false
    @State private var histogramChannel = -1
    @State private var headerQuery = ""
    @State private var tab = 0
    @State private var busy = false
    @State private var message = ""
    private let statNames = ["mean", "median", "sigma", "avgDev", "MAD", "sqrt(BWMV)", "min", "max"]

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if geometry.size.width > 800 {
                        HStack(spacing: 0) { imagePanel; controls.frame(width: 380) }
                    } else {
                        VStack(spacing: 0) { imagePanel.frame(height: geometry.size.height * 0.45); controls }
                    }
                }
            }
            .navigationTitle("图像统计与分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) } }
            .task {
                tab = ProcessInfo.processInfo.environment["SIRIL_ANALYSIS_TAB"].flatMap { Int($0) } ?? initialTab
                await open()
            }
            .onChange(of: perCFA) { _, _ in Task { await analyze() } }
            .onChange(of: channel) { _, _ in Task { await refreshPreview() } }
            .onChange(of: automatic) { _, _ in Task { await refreshPreview() } }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
    private var imagePanel: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("通道", selection: $channel) {
                    Text("RGB / 灰度").tag(-1)
                    if file.channels == 3 { Text("R").tag(0); Text("G").tag(1); Text("B").tag(2) }
                }.pickerStyle(.segmented)
                Toggle("自动拉伸", isOn: $automatic)
            }.disabled(busy).padding(.horizontal)
            if let image {
                ZoomableImageCanvas(image: image, samples: [], imageWidth: Double(file.width), imageHeight: Double(file.height),
                    region: selection, selecting: selecting && !busy,
                    onSelection: { value in
                        selection = value
                        Task { await analyze() }
                    }, onTap: { x, y in
                        guard !busy else { return }
                        Task {
                            do { pixel = try await engine.pixel(x: Int(floor(x)), y: Int(floor(y))) }
                            catch { message = error.localizedDescription }
                        }
                    }).background(.black)
            } else { ProgressView("读取原始图像").frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack {
                Toggle("矩形选区", isOn: $selecting)
                Button("清除选区") { selection = nil; Task { await analyze() } }.disabled(selection == nil)
            }.disabled(busy).padding(.horizontal)
            Text(selecting ? "单指拖动框选，双指缩放和平移；轻点读取原始像素。" : "双指缩放，拖动平移；轻点读取原始像素。")
                .font(.caption).foregroundStyle(.secondary)
            if let pixel {
                Text("x=\(pixel.x) y=\(pixel.y) · " + pixel.values.enumerated().map { i, v in
                    "\(pixel.values.count == 1 ? "灰度" : ["R", "G", "B"][i])=\(String(format: "%.7g", v))"
                }.joined(separator: "  "))
                .font(.caption.monospaced()).textSelection(.enabled)
            }
            Text("像素读数使用原始浮点值；自动拉伸只改变显示。")
                .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
        }
    }
    private var controls: some View {
        Form {
            Section {
                Text(file.displayName).lineLimit(2)
                Text(selection?.description ?? "整张图像 · 无选区").font(.caption)
                Picker("分析", selection: $tab) {
                    Text("统计").tag(0); Text("直方图").tag(1); Text("文件头").tag(2)
                }.pickerStyle(.segmented)
            }
            if tab == 0 { statisticsControls }
            if tab == 1 { histogramControls }
            if tab == 2 { headerControls }
            if let details {
                Section("文件信息") {
                    Text("\(details.width) × \(details.height) · \(details.channels) 通道 · 工作 BITPIX \(details.bitpix)")
                    LabeledContent("曝光", value: String(format: "%.3g 秒", details.exposure))
                    LabeledContent("温度", value: String(format: "%.3g ℃", details.temperature))
                    LabeledContent("增益 / 偏置", value: "\(details.gain) / \(details.offset)")
                    if !details.object.isEmpty { LabeledContent("目标", value: details.object) }
                    if details.hasCFA { LabeledContent("CFA", value: details.bayer) }
                }.font(.caption)
            }
            Section {
                if busy { ProgressView("Siril 正在计算") }
                if !message.isEmpty { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                Button("重新计算") { Task { await analyze() } }.disabled(busy || details == nil)
            }
        }
    }
    private var statisticsControls: some View {
        Section("Statistics · 原版 STATS_MAIN") {
            Toggle("归一化实数 [0, 1]", isOn: $normalized).disabled(busy)
            Toggle("按 CFA 通道统计", isOn: $perCFA).disabled(busy || details?.hasCFA != true)
            if let snapshot {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Name")
                        ForEach(snapshot.statistics.indices, id: \.self) { c in
                            Text(snapshot.statistics.count == 1 ? "灰度" : ["Red", "Green", "Blue"][c])
                        }
                    }.bold()
                    ForEach(statNames.indices, id: \.self) { i in
                        GridRow {
                            Text(statNames[i])
                            ForEach(snapshot.statistics.indices, id: \.self) { c in
                                Text(formatted(snapshot.statistics[c], index: i)).textSelection(.enabled)
                            }
                        }
                    }
                }.font(.system(size: 11, design: .monospaced))
                Text(snapshot.statistics.enumerated().map { c, s in
                    "\(snapshot.statistics.count == 1 ? "灰度" : ["R", "G", "B"][c])：\(s.total) 像素，\(s.good) 有效"
                }.joined(separator: "\n")).font(.caption2)
                Button("复制统计数据") { UIPasteboard.general.string = statisticsText(snapshot) }
                Text("非归一化浮点图像按原版显示为 16 位标度。零值和无效像素的处理遵循 Siril 原版统计。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var histogramControls: some View {
        Section("原始像素直方图") {
            Toggle("对数纵轴", isOn: $logarithmic)
            if file.channels == 3 {
                Picker("曲线", selection: $histogramChannel) {
                    Text("RGB").tag(-1); Text("R").tag(0); Text("G").tag(1); Text("B").tag(2)
                }.pickerStyle(.segmented)
            }
            if let snapshot {
                HistogramPlot(histograms: snapshot.histograms, channel: histogramChannel, logarithmic: logarithmic)
                    .frame(height: 220)
                HStack { Text("0"); Spacer(); Text("归一化像素值"); Spacer(); Text("1") }
                    .font(.caption2)
                Text("直方图来自原始像素，显示拉伸不改变此图。整图与选区的零值和范围边界处理遵循 Siril 原版。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("复制直方图 CSV") {
                    UIPasteboard.general.string = "bin_start," + (snapshot.histograms.count == 1 ? "gray" : "R,G,B") + "\n" +
                        (0..<512).map { i in
                            String(format: "%.9f", Double(i) / 512) + "," + snapshot.histograms.map { String(format: "%.0f", $0[i]) }.joined(separator: ",")
                        }.joined(separator: "\n")
                }
            }
        }
    }
    private var filteredHeader: String {
        guard let header = details?.header else { return "" }
        return headerQuery.isEmpty ? header : header.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains(headerQuery) }.joined(separator: "\n")
    }
    private var headerControls: some View {
        Section("FITS Header") {
            TextField("查找关键字或内容", text: $headerQuery).autocorrectionDisabled()
            Button("复制显示的文件头") { UIPasteboard.general.string = filteredHeader }.disabled(filteredHeader.isEmpty)
            ScrollView(.horizontal) {
                Text(filteredHeader.isEmpty ? "没有匹配的文件头内容" : filteredHeader)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("当前可查看完整原始文件头；原版关键字新增、修改、删除和序列编辑尚待移植。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func formatted(_ stat: ChannelStatistics, index: Int) -> String {
        let value = stat.values[index]
        guard value.isFinite, value != -999999, stat.norm > 0 else { return "--" }
        if normalized { return String(format: value > 0 && value < 1e-5 ? "%.5e" : "%.7f", value / stat.norm) }
        return String(format: "%.1f", value * 65535)
    }
    private func statisticsText(_ data: AnalysisSnapshot) -> String {
        file.displayName + "\n" + (selection?.description ?? "Full image") + "\nName," +
            (data.statistics.count == 1 ? "Gray" : "R,G,B") + "\n" + statNames.indices.map { i in
                statNames[i] + "," + data.statistics.map { formatted($0, index: i) }.joined(separator: ",")
            }.joined(separator: "\n")
    }
    @MainActor private func open() async {
        busy = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            details = try await engine.open(file.url)
            image = try await engine.preview(channel: channel, automatic: automatic).uiImage
            snapshot = try await engine.analyze(region: selection, perCFA: perCFA)
            if ProcessInfo.processInfo.environment["SIRIL_SELF_TEST"] == "1" {
                let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-analysis-ready.txt")
                guard image != nil, snapshot != nil else { throw EngineError.failed("Analysis view did not load") }
                try "PASS: native analysis workspace tab \(tab) loaded the image, original statistics, histogram and header.\n".write(to: report, atomically: true, encoding: .utf8)
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func analyze() async {
        guard !busy, details != nil else { return }
        busy = true; message = ""
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do { snapshot = try await engine.analyze(region: selection, perCFA: perCFA) }
        catch { snapshot = nil; message = error.localizedDescription }
    }
    @MainActor private func refreshPreview() async {
        guard !busy, details != nil else { return }
        busy = true
        defer { busy = false }
        do { image = try await engine.preview(channel: channel, automatic: automatic).uiImage }
        catch { message = error.localizedDescription }
    }
}

private struct HistogramPlot: View {
    let histograms: [[Double]]
    let channel: Int
    let logarithmic: Bool
    private var visible: [Int] { histograms.indices.filter { channel < 0 || channel == $0 } }
    private func magnitude(_ value: Double) -> Double { logarithmic ? log1p(value) : value }
    var body: some View {
        Canvas { context, size in
            let maximum = max(1, visible.flatMap { histograms[$0] }.map(magnitude).max() ?? 1)
            for c in visible {
                var path = Path()
                let bins = histograms[c]
                for i in bins.indices {
                    let p = CGPoint(x: Double(i) / Double(max(1, bins.count - 1)) * size.width,
                                    y: (1 - magnitude(bins[i]) / maximum) * size.height)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(histograms.count == 1 ? .primary : [.red, .green, .blue][c]), lineWidth: 1)
            }
        }.background(Color.secondary.opacity(0.08))
    }
}
