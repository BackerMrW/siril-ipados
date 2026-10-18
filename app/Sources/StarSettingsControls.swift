// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StarSettingsControls: View {
    @Binding var settings: StarSettings
    let channels: Int
    var detectionOnly = false
    var body: some View {
        Group {
            Section("原版 PSF 拟合与星点检测") {
                Picker("通道", selection: $settings.channel) {
                    if channels == 1 { Text("灰度 / CFA 绿通道检测").tag(0) }
                    else { Text("R").tag(0); Text("G").tag(1); Text("B").tag(2) }
                }
                Picker("拟合模型", selection: $settings.profile) { Text("Gaussian").tag(0); Text("Moffat · 自由 β").tag(1) }
                Stepper("收敛精度 \(settings.convergence)", value: $settings.convergence, in: 1...3)
                Stepper("搜索半径 \(settings.radius) px", value: $settings.radius, in: 3...50)
                number("阈值 σ", $settings.sigma)
                number("最小圆度", $settings.minRoundness); number("最大圆度", $settings.maxRoundness)
                number("最小 Moffat β", $settings.minBeta)
                number("最小幅度", $settings.minAmplitude); number("最大幅度（0 为自动）", $settings.maxAmplitude)
                number("焦距 mm（0 读图像）", $settings.focal); number("像元 μm（0 读图像）", $settings.pixelSize)
                Toggle("放宽拟合检查", isOn: $settings.relax)
                Stepper("最多 \(settings.maximum) 颗星", value: $settings.maximum, in: 1...10000, step: 100)
                Text(detectionOnly ? "CFA 使用原版绿像素插值检测。FWHM 保持像素单位；固定 β 模型在所用原版中仍未实现。" : "检测会替换当前星表，可撤销；单星拟合添加一行。固定 β 模型在所用原版中仍未实现。CFA 自动检测遵循原版绿像素插值；单星拟合使用所选原始通道。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !detectionOnly { Section("孔径测光 · 原版 Photometry") {
                Toggle("单星拟合同时测光", isOn: $settings.photometry)
                Toggle("固定孔径半径", isOn: $settings.forceRadius)
                number("孔径半径 px", $settings.aperture)
                number("动态半径 / 半 FWHM", $settings.apertureFactor)
                number("背景环内半径 px", $settings.inner); number("背景环外半径 px", $settings.outer)
                number("转换增益 e⁻/ADU", $settings.gain)
                number("有效最小值（16 位标度）", $settings.minimum); number("有效最大值（16 位标度）", $settings.maximumPixel)
                Text("文件头 EGAIN 优先于转换增益；浮点像素范围和增益按原版换算。星等为仪器星等，未经过标准星校准。框选范围须包含足够背景环像素。")
                    .font(.caption2).foregroundStyle(.secondary)
            } }
        }
    }
    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).multilineTextAlignment(.trailing).frame(width: 100).keyboardType(.numbersAndPunctuation) }
    }
}
