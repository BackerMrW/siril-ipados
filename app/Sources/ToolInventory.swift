// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UpstreamFeature: Decodable, Identifiable {
    let id: String
    let title: String
    let group: String
    let status: String
    var currentStatus: String {
        switch id {
        case "win.color-calib-processing":
            return "原版背景中和、白参考及手动 RGB 系数已接入；真机未验收。"
        case "win.linearmatch-processing", "win.rgradient-processing":
            return "原版计算、参数与独立结果已接入；真机未验收。"
        case "win.evaluate-noise":
            return "原版背景噪声已接入统计、选区/CFA与复制报告；真机未验收。"
        case "win.ccd-inspector", "win.show-tilt":
            return "单张和普通/FITSEQ/SER 当前帧分析、参与帧平均倾斜与来源保护已通过数值和页面检查；真机未验收。"
        case "win.show-disto":
            return "图像 WCS 前置畸变模型、原版采样网格与 5 倍向量已通过数值和页面检查；完整畸变解算仍待补齐。"
        default: return status
        }
    }
}
struct UpstreamInventory: Decodable {
    let entries: [UpstreamFeature]
    static var bundled: [UpstreamFeature] {
        guard let url = Bundle.main.url(forResource: "UpstreamFeatures", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return [] }
        return value.entries
    }
}

struct ToolInventoryView: View {
    let onBackground: () -> Void
    let onProcessing: () -> Void
    let onAnalysis: (Int) -> Void
    let onNativeTool: (NativeTool) -> Void
    let canUseNativeTools: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let features = UpstreamInventory.bundled
    private var filtered: [UpstreamFeature] {
        features.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("已接入的入口") {
                    Button("背景提取 · Background Extraction") { dismiss(); onBackground() }
                    Button("批处理与单张工具") { dismiss(); onProcessing() }
                    Button("统计 · Statistics") { dismiss(); onAnalysis(0) }
                    Button("背景噪声估计 · Noise Estimation") { dismiss(); onAnalysis(0) }.disabled(!canUseNativeTools)
                    Button("直方图与像素读数") { dismiss(); onAnalysis(1) }
                    Button("动态 PSF 与孔径测光") { dismiss(); onAnalysis(3) }.disabled(!canUseNativeTools)
                    Button("传感器倾斜 · Sensor Tilt") { dismiss(); onAnalysis(4) }.disabled(!canUseNativeTools)
                    Button("像差九宫格 · Aberration Inspector") { dismiss(); onAnalysis(5) }.disabled(!canUseNativeTools)
                    Button("WCS 畸变显示 · Distortions") { dismiss(); onAnalysis(6) }.disabled(!canUseNativeTools)
                    Button("FITS 文件头 · FITS Header") { dismiss(); onAnalysis(2) }
                }
                ForEach(["拉伸", "颜色", "滤镜", "几何", "曲线与表达式", "频谱", "反卷积", "天文分析"], id: \.self) { group in
                    Section(group) {
                        ForEach(NativeTool.allCases.filter { $0.group == group }) { tool in
                            Button(tool.title) { dismiss(); onNativeTool(tool) }.disabled(!canUseNativeTools)
                        }
                        if !canUseNativeTools { Text("先从图库打开一张图像。").font(.caption) }
                    }
                }
                Section("原版功能对应情况") {
                    Text("下面按所移植的 Siril 1.5 源码列出原版动作。当前版本仍在移植，未完成的工具会显示真实状态。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            if let tool = NativeTool.actions[entry.id] {
                                Button(entry.title) { dismiss(); onNativeTool(tool) }.disabled(!canUseNativeTools)
                            } else if ["win.psf", "win.dyn-psf", "win.photometry"].contains(entry.id) {
                                Button(entry.title) { dismiss(); onAnalysis(3) }.disabled(!canUseNativeTools)
                            } else if entry.id == "win.show-tilt" {
                                Button(entry.title) { dismiss(); onAnalysis(4) }.disabled(!canUseNativeTools)
                            } else if entry.id == "win.ccd-inspector" {
                                Button(entry.title) { dismiss(); onAnalysis(5) }.disabled(!canUseNativeTools)
                            } else if entry.id == "win.show-disto" {
                                Button(entry.title) { dismiss(); onAnalysis(6) }.disabled(!canUseNativeTools)
                            } else if entry.id == "win.evaluate-noise" {
                                Button(entry.title) { dismiss(); onAnalysis(0) }.disabled(!canUseNativeTools)
                            } else { Text(entry.title).font(.headline) }
                            Text(entry.currentStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Link("查看完整功能核对表", destination: URL(string: "https://github.com/BackerMrW/siril-ipados/blob/main/docs/FUNCTIONAL-PARITY.md")!)
                }
            }
            .searchable(text: $query, prompt: "搜索原版工具")
            .navigationTitle("Siril 图像处理与分析")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
