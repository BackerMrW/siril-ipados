// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

func attachSavedDisplayMask(_ image: OpaquePointer, url: URL) throws {
    let mask = url.appendingPathExtension("mask.fits")
    guard FileManager.default.fileExists(atPath: mask.path) else { return }
    guard (try mask.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
          mask.resolvingSymlinksInPath().deletingLastPathComponent() == url.resolvingSymlinksInPath().deletingLastPathComponent(),
          mask.path.withCString({ siril_image_load_mask(image, $0) }) != 0 else { throw EngineError.failed("保存的显示蒙版无效或与图像尺寸不匹配。") }
}

enum NativeDisplayMode: Int32, CaseIterable, Codable, Identifiable, Sendable {
    case linear = 0, logarithmic, squareRoot, squared, asinh, automatic, histogram
    var id: Int32 { rawValue }
    var title: String { switch self { case .linear: return "线性"; case .logarithmic: return "对数"; case .squareRoot: return "平方根"; case .squared: return "平方"; case .asinh: return "Asinh"; case .automatic: return "自动拉伸 STF"; case .histogram: return "直方图均衡" } }
}
struct NativeDisplaySettings: Codable, Equatable, Sendable {
    var mode: NativeDisplayMode = .automatic
    var low = 0.0, high = 1.0
    var unlinked = false, inverted = false
    var colorManaged: Bool?
    var rainbow: Bool?, maskOverlay: Bool?
    var renderingIntent: Int?, proofingIntent: Int?, softProof: Int?
    var blackPoint: Bool?, gamutCheck: Bool?
    var proofProfile: ICCProfileResource?
    var useICC: Bool { get { colorManaged ?? true } set { colorManaged = newValue } }
    var useRainbow: Bool { get { rainbow ?? false } set { rainbow = newValue } }
    var showMask: Bool { get { maskOverlay ?? false } set { maskOverlay = newValue } }
    var native: SirilDisplayOptions {
        var options = SirilDisplayOptions()
        options.mode = mode.rawValue; options.low = low; options.high = high
        options.unlinked = unlinked ? 1 : 0; options.inverted = inverted ? 1 : 0
        options.icc = useICC ? 1 : 0; options.rainbow = useRainbow ? 1 : 0; options.mask_overlay = showMask ? 1 : 0
        options.rendering_intent = Int32(clamping: renderingIntent ?? 1); options.proofing_intent = Int32(clamping: proofingIntent ?? 1)
        options.black_point = (blackPoint ?? true) ? 1 : 0; options.gamut_check = (gamutCheck ?? false) ? 1 : 0
        options.proof = Int32(clamping: softProof ?? 0)
        return options
    }
    func withNative<T>(_ body: (inout SirilDisplayOptions) throws -> T) throws -> T {
        var options = native
        guard (0...3).contains(renderingIntent ?? 1), (0...3).contains(proofingIntent ?? 1), (0...4).contains(softProof ?? 0) else { throw EngineError.failed("ICC 显示参数无效。") }
        if useICC && softProof == 4 {
            guard let proofProfile else { throw EngineError.failed("请选择软打样 ICC 配置文件。") }
            try proofProfile.validate(channels: 0)
            return try proofProfile.data.withUnsafeBytes {
                options.proof_data = $0.baseAddress; options.proof_size = $0.count
                return try body(&options)
            }
        }
        return try body(&options)
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "native-display-settings"), let settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.low.isFinite, settings.high.isFinite, settings.low >= 0, settings.high <= 1, settings.high > settings.low,
              (0...3).contains(settings.renderingIntent ?? 1), (0...3).contains(settings.proofingIntent ?? 1), (0...4).contains(settings.softProof ?? 0) else { return Self() }
        return settings
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "native-display-settings") } }
}
struct NativeDisplayControls: View {
    @Binding var settings: NativeDisplaySettings
    @State private var importingProof = false
    @State private var message = ""
    private let intents = ["感知", "相对色度", "饱和度", "绝对色度"]
    var body: some View {
        DisclosureGroup("显示：\(settings.mode.title)") {
            Picker("显示模式", selection: $settings.mode) { ForEach(NativeDisplayMode.allCases) { Text($0.title).tag($0) } }
            if settings.mode.rawValue < 5 {
                HStack {
                    Text("低值"); TextField("低值", value: $settings.low, format: .number).keyboardType(.numbersAndPunctuation)
                    Text("高值"); TextField("高值", value: $settings.high, format: .number).keyboardType(.numbersAndPunctuation)
                }
            }
            if settings.mode == .automatic { Toggle("各通道独立拉伸", isOn: $settings.unlinked) }
            Toggle("反转显示", isOn: $settings.inverted)
            Toggle("按图像 ICC 显示颜色", isOn: Binding(get: { settings.useICC }, set: { settings.useICC = $0 }))
            if settings.useICC {
                Picker("屏幕渲染意图", selection: Binding(get: { settings.renderingIntent ?? 1 }, set: { settings.renderingIntent = $0 })) {
                    ForEach(intents.indices, id: \.self) { Text(intents[$0]).tag($0) }
                }
                Toggle("黑点补偿", isOn: Binding(get: { settings.blackPoint ?? true }, set: { settings.blackPoint = $0 }))
                Picker("软打样", selection: Binding(get: { settings.softProof ?? 0 }, set: { settings.softProof = $0 })) {
                    Text("关闭").tag(0); Text("sRGB").tag(1); Text("Rec.2020").tag(2); Text("工作颜色空间").tag(3); Text("自定义 ICC").tag(4)
                }
                if (settings.softProof ?? 0) != 0 {
                    Picker("打样意图", selection: Binding(get: { settings.proofingIntent ?? 1 }, set: { settings.proofingIntent = $0 })) {
                        ForEach(intents.indices, id: \.self) { Text(intents[$0]).tag($0) }
                    }
                    Toggle("色域外警示（品红）", isOn: Binding(get: { settings.gamutCheck ?? false }, set: { settings.gamutCheck = $0 }))
                    if settings.softProof == 4 {
                        Button("选择软打样 ICC") { importingProof = true }
                        if let profile = settings.proofProfile { Text(profile.name).font(.caption) }
                        Text("支持 RGB、灰度或 CMYK 打样配置文件，最大16 MiB；所选文件随显示设置保存。").font(.caption)
                    }
                }
            }
            Toggle("灰度 / 单通道伪彩色", isOn: Binding(get: { settings.useRainbow }, set: { settings.useRainbow = $0 }))
            Toggle("叠加当前处理蒙版", isOn: Binding(get: { settings.showMask }, set: { settings.showMask = $0 }))
            Text("伪彩色用于灰度图或所选单通道；RGB 合成视图保留颜色。蒙版叠加使用原版红色提示，仅在图像已有活动蒙版时显示。").font(.caption).foregroundStyle(.secondary)
            Text("ICC 显示转为 sRGB，由 iPadOS 映射到屏幕；灰度/单通道 STF、独立 STF 与直方图均衡按原版规则跳过颜色转换。").font(.caption).foregroundStyle(.secondary)
            Text("显示模式不修改原始像素。低值和高值范围为0–1，且高值必须大于低值。").font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $importingProof, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get(); let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw EngineError.failed("ICC 文件最大为16 MiB。") }
                let profile = ICCProfileResource(name: url.lastPathComponent, data: try Data(contentsOf: url)); try profile.validate(channels: 0)
                settings.proofProfile = profile; settings.softProof = 4; message = ""
            } catch { message = error.localizedDescription }
        }
    }
}
extension SirilEngine {
    func preview(_ url: URL, channel: Int, settings: NativeDisplaySettings) throws -> PreviewBytes {
        let image = try read(url); defer { siril_image_free(image) }
        if settings.showMask { try attachSavedDisplayMask(image, url: url) }
        var preview = SirilPreview()
        let success = try settings.withNative { siril_image_preview_mode(image, 2048, Int32(channel), &$0, &preview) }
        guard success != 0, let bytes = preview.rgba else { throw EngineError.failed("显示生成失败，请检查显示范围。") }
        defer { siril_preview_free(&preview) }
        return PreviewBytes(data: Data(bytes: bytes, count: Int(preview.width) * Int(preview.height) * 4), width: Int(preview.width), height: Int(preview.height))
    }
}
extension ImageAnalysisEngine {
    func preview(channel: Int, settings: NativeDisplaySettings) throws -> PreviewBytes {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var preview = SirilPreview()
        let success = try settings.withNative { siril_image_preview_mode(image, 2048, Int32(channel), &$0, &preview) }
        guard success != 0, let bytes = preview.rgba else { throw EngineError.failed("显示生成失败，请检查显示范围。") }
        defer { siril_preview_free(&preview) }
        return PreviewBytes(data: Data(bytes: bytes, count: Int(preview.width) * Int(preview.height) * 4), width: Int(preview.width), height: Int(preview.height))
    }
}
