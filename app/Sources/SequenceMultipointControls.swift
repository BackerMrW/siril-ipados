// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SequenceMultipointControls: View {
    @Binding var settings: SequenceMultipointSettings
    var body: some View {
        Section("全局对齐") {
            Toggle("行星整盘（关闭时为表面纹理）", isOn: $settings.planet)
            Toggle("帧亮度归一化", isOn: $settings.normalize)
        }
        Section("局部对齐点") {
            Stepper("对齐框半宽：\(settings.halfBox) px", value: $settings.halfBox, in: 8...128)
            Stepper("局部搜索：\(settings.search) px", value: $settings.search, in: 1...64)
            BatchNumber(title: "结构阈值", value: $settings.structure)
            Stepper("参与局部配准：\(settings.registerPercent)%", value: $settings.registerPercent, in: 1...100)
            Text("局部位移使用亚像素测量。").font(.caption).foregroundStyle(.secondary)
            Toggle("细化局部参考图", isOn: $settings.refine)
            Toggle("局部形变校正", isOn: $settings.dewarp)
            BatchNumber(title: "位移平滑半径（网格间距）", value: $settings.smoothRadius)
        }
        Section("专用叠加") {
            Stepper("每个对齐点叠加：\(settings.stackPercent)%", value: $settings.stackPercent, in: 1...100)
            Toggle("跳过局部测量失败的帧贡献", isOn: $settings.skipFailed)
            Toggle("32 位浮点结果", isOn: $settings.floatOutput)
            BatchNumber(title: "输出倍率（1–3）", value: $settings.scale)
            BatchNumber(title: "背景帧比例", value: $settings.backgroundFraction)
            BatchNumber(title: "背景混合阈值", value: $settings.backgroundBlend)
        }
        Section {
            Text("使用原版 MPP 分析、局部配准及专用叠加器。可先分析并编辑对齐点，再分别配准和叠加；每次处理独立保存，原结果保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
