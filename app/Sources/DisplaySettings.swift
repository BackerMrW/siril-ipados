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
    var useICC: Bool { get { colorManaged ?? true } set { colorManaged = newValue } }
    var useRainbow: Bool { get { rainbow ?? false } set { rainbow = newValue } }
    var showMask: Bool { get { maskOverlay ?? false } set { maskOverlay = newValue } }
    var native: SirilDisplayOptions { SirilDisplayOptions(mode: mode.rawValue, low: low, high: high, unlinked: unlinked ? 1 : 0, inverted: inverted ? 1 : 0, icc: useICC ? 1 : 0, rainbow: useRainbow ? 1 : 0, mask_overlay: showMask ? 1 : 0) }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "native-display-settings"), let settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.low.isFinite, settings.high.isFinite, settings.low >= 0, settings.high <= 1, settings.high > settings.low else { return Self() }
        return settings
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "native-display-settings") } }
}
struct NativeDisplayControls: View {
    @Binding var settings: NativeDisplaySettings
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
            Toggle("灰度 / 单通道伪彩色", isOn: Binding(get: { settings.useRainbow }, set: { settings.useRainbow = $0 }))
            Toggle("叠加当前处理蒙版", isOn: Binding(get: { settings.showMask }, set: { settings.showMask = $0 }))
            Text("伪彩色用于灰度图或所选单通道；RGB 合成视图保留颜色。蒙版叠加使用原版红色提示，仅在图像已有活动蒙版时显示。").font(.caption).foregroundStyle(.secondary)
            Text("ICC 显示转为 sRGB，由 iPadOS 映射到屏幕；灰度/单通道 STF、独立 STF 与直方图均衡按原版规则跳过颜色转换。").font(.caption).foregroundStyle(.secondary)
            Text("显示模式不修改原始像素。低值和高值范围为0–1，且高值必须大于低值。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
extension SirilEngine {
    func preview(_ url: URL, channel: Int, settings: NativeDisplaySettings) throws -> PreviewBytes {
        let image = try read(url); defer { siril_image_free(image) }
        if settings.showMask { try attachSavedDisplayMask(image, url: url) }
        var options = settings.native, preview = SirilPreview()
        guard siril_image_preview_mode(image, 2048, Int32(channel), &options, &preview) != 0, let bytes = preview.rgba else { throw EngineError.failed("显示生成失败，请检查显示范围。") }
        defer { siril_preview_free(&preview) }
        return PreviewBytes(data: Data(bytes: bytes, count: Int(preview.width) * Int(preview.height) * 4), width: Int(preview.width), height: Int(preview.height))
    }
}
extension ImageAnalysisEngine {
    func preview(channel: Int, settings: NativeDisplaySettings) throws -> PreviewBytes {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var options = settings.native, preview = SirilPreview()
        guard siril_image_preview_mode(image, 2048, Int32(channel), &options, &preview) != 0, let bytes = preview.rgba else { throw EngineError.failed("显示生成失败，请检查显示范围。") }
        defer { siril_preview_free(&preview) }
        return PreviewBytes(data: Data(bytes: bytes, count: Int(preview.width) * Int(preview.height) * 4), width: Int(preview.width), height: Int(preview.height))
    }
}
