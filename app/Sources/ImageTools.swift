// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum StretchMode: String, CaseIterable, Identifiable, Sendable {
    case none, automatic, asinh, mtf
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "保留线性数据"
        case .automatic: return "自动 MTF 拉伸"
        case .asinh: return "Asinh 拉伸"
        case .mtf: return "手动 MTF 拉伸"
        }
    }
}

struct ImageToolOptions: Sendable {
    var background = false
    var degree = 1
    var samples = 20
    var denoise = false
    var stretch: StretchMode = .automatic
    var asinh = 10.0
    var shadows = 0.0
    var midtones = 0.25
    var highlights = 1.0
    var saturation = false
    var saturationAmount = 0.2
    var rotation = 0
    var crop = false
    var x = 0
    var y = 0
    var width = 100
    var height = 100
}

enum ImageToolScript {
    static func make(files: [FITSRecord], options: ImageToolOptions) throws -> String {
        guard files.count == 1, let file = files.first else {
            throw EngineError.failed("请在图库中只勾选一张要处理的图像。")
        }
        if options.saturation && file.channels != 3 {
            throw EngineError.failed("饱和度调整需要三通道 RGB 图像，请先完成 CFA 去马赛克。")
        }
        if options.crop {
            guard options.x >= 0, options.y >= 0, options.width > 0, options.height > 0,
                  options.x <= file.width - options.width, options.y <= file.height - options.height else {
                throw EngineError.failed("裁剪区域超出图像范围。坐标从左上角开始，单位是像素。")
            }
        }
        if options.stretch == .mtf && options.shadows >= options.highlights {
            throw EngineError.failed("MTF 黑点必须小于白点。")
        }
        // POSIX decimal separator: device language must never change command syntax.
        func number(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
        var lines = ["# Siril 原生单张处理", "set32bits", "cd \(file.role.rawValue)", "load frame_00001.fits"]
        if options.crop { lines.append("crop \(options.x) \(options.y) \(options.width) \(options.height)") }
        if options.background { lines.append("subsky \(options.degree) -samples=\(options.samples)") }
        if options.denoise { lines.append("denoise") }
        switch options.stretch {
        case .none: break
        case .automatic: lines.append("autostretch -linked")
        case .asinh: lines.append("asinh \(number(options.asinh)) 0")
        case .mtf: lines.append("mtf \(number(options.shadows)) \(number(options.midtones)) \(number(options.highlights))")
        }
        if options.saturation { lines.append("satu \(number(options.saturationAmount))") }
        if options.rotation != 0 { lines.append("rotate \(options.rotation) -nocrop") }
        lines += ["save ../process/result.fits", "close"]
        return lines.joined(separator: "\n") + "\n"
    }
}

struct ImageToolControls: View {
    @Binding var options: ImageToolOptions
    var body: some View {
        Toggle("背景提取", isOn: $options.background)
        if options.background {
            Stepper("多项式阶数：\(options.degree)", value: $options.degree, in: 1...4)
            Stepper("每行采样点：\(options.samples)", value: $options.samples, in: 5...50, step: 5)
        }
        Toggle("Siril 降噪", isOn: $options.denoise)
        Picker("拉伸方式", selection: $options.stretch) {
            ForEach(StretchMode.allCases) { Text($0.title).tag($0) }
        }
        if options.stretch == .asinh {
            LabeledContent("Asinh 强度", value: options.asinh.formatted(.number.precision(.fractionLength(1))))
            Slider(value: $options.asinh, in: 1...100)
        }
        if options.stretch == .mtf {
            LabeledContent("黑点", value: options.shadows.formatted(.number.precision(.fractionLength(3))))
            Slider(value: $options.shadows, in: 0...0.99)
            LabeledContent("中间调", value: options.midtones.formatted(.number.precision(.fractionLength(3))))
            Slider(value: $options.midtones, in: 0.01...0.99)
            LabeledContent("白点", value: options.highlights.formatted(.number.precision(.fractionLength(3))))
            Slider(value: $options.highlights, in: 0.01...1)
        }
        Toggle("RGB 饱和度", isOn: $options.saturation)
        if options.saturation {
            LabeledContent("调整量", value: options.saturationAmount.formatted(.number.precision(.fractionLength(2))))
            Slider(value: $options.saturationAmount, in: -1...1)
        }
        Picker("旋转", selection: $options.rotation) {
            Text("保持方向").tag(0)
            Text("90°").tag(90)
            Text("180°").tag(180)
            Text("270°").tag(270)
        }
        Toggle("裁剪", isOn: $options.crop)
        if options.crop {
            Text("先裁剪，再处理背景与颜色，最后旋转。坐标为左上角，单位为像素。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("X", value: $options.x, format: .number)
                TextField("Y", value: $options.y, format: .number)
            }.keyboardType(.numberPad)
            HStack {
                TextField("宽", value: $options.width, format: .number)
                TextField("高", value: $options.height, format: .number)
            }.keyboardType(.numberPad)
        }
        Text("拉伸会写入输出像素；预览的自动拉伸只影响显示。")
            .font(.caption).foregroundStyle(.secondary)
    }
}
