// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SequenceMultipointControls: View {
    @Binding var settings: SequenceMultipointSettings
    private var advanced: Binding<SequenceMultipointAdvanced> {
        Binding(get: { settings.advanced ?? SequenceMultipointAdvanced() }, set: { settings.advanced = $0 })
    }
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
        SequenceMultipointStackControls(settings: $settings)
        SequenceMultipointAdvancedControls(settings: advanced)
        Section {
            Text("使用原版 MPP 分析、局部配准及专用叠加器。可先分析并编辑对齐点，再分别配准和叠加；每次处理独立保存，原结果保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SequenceMultipointAdvancedControls: View {
    @Binding var settings: SequenceMultipointAdvanced
    private let bayerNames = ["自动", "单色", "RGGB", "BGGR", "GBRG", "GRBG"]
    var body: some View {
        Section("高级参数") {
            DisclosureGroup("全局参考图") {
                Stepper("全局搜索：\(settings.globalSearch) px", value: $settings.globalSearch, in: 4...64)
                Stepper("参考帧比例：\(settings.referencePercent)%", value: $settings.referencePercent, in: 1...100)
                Toggle("快速变化目标", isOn: $settings.fastChanging)
                Toggle("使用已有平移作为起点", isOn: $settings.seed)
            }
            DisclosureGroup("对齐点与局部测量") {
                Stepper("最低亮度：\(settings.brightness)", value: $settings.brightness, in: 0...100)
                Stepper("最低对比度：\(settings.contrast)", value: $settings.contrast, in: 0...100)
                Stepper("点间距：\(settings.gridStep) px（0 自动）", value: $settings.gridStep, in: 0...500)
                Toggle("零均值相关", isOn: $settings.zeroMean)
                Stepper("细化参考帧：\(settings.referenceFrames)（0 自动）", value: $settings.referenceFrames, in: 0...500)
            }
            DisclosureGroup("叠加与去马赛克") {
                SequenceMultipointStackAdvancedControls(settings: $settings)
                Picker("无 Bayer 标记视频的排列", selection: $settings.aviBayer) {
                    ForEach(bayerNames.indices, id: \.self) { Text(bayerNames[$0]).tag($0) }
                }
            }
        }
    }
}

struct SequenceMultipointStackControls: View {
    @Binding var settings: SequenceMultipointSettings
    var body: some View {
        Section("专用叠加") {
            Stepper("每个对齐点叠加：\(settings.stackPercent)%", value: $settings.stackPercent, in: 1...100)
            Toggle("跳过局部测量失败的帧贡献", isOn: $settings.skipFailed)
            Toggle("32 位浮点结果", isOn: $settings.floatOutput)
            BatchNumber(title: "输出倍率（1–3）", value: $settings.scale)
            BatchNumber(title: "背景帧比例", value: $settings.backgroundFraction)
            BatchNumber(title: "背景混合阈值", value: $settings.backgroundBlend)
        }
    }
}

struct SequenceMultipointStackAdvancedControls: View {
    @Binding var settings: SequenceMultipointAdvanced
    private let debayerNames = ["Bilinear", "VNG", "AHD", "AMaZE", "DCB", "HPHD", "IGV", "LMMSE", "RCD"]
    var body: some View {
        Group {
                Stepper("每点叠加帧数：\(settings.stackFrames)（≤0 按比例）", value: $settings.stackFrames, in: -1...10000)
                Text("显式帧数优先于比例，最多使用已参与配准的帧数。").font(.caption).foregroundStyle(.secondary)
                Picker("叠加方式", selection: $settings.stackMethod) {
                    Text("局部图块融合").tag(0); Text("稠密形变（实验性）").tag(1)
                }
                Picker("CFA 去马赛克", selection: $settings.debayer) {
                    ForEach(debayerNames.indices, id: \.self) { Text(debayerNames[$0]).tag($0) }
                }
        }
    }
}
