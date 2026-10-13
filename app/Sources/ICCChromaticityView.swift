// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts
import SirilCore

struct ICCChromaticity: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let channels: Int
    let coordinates: [Double]
    init(data: Data) throws {
        var points = [Double](repeating: 0, count: 8), description = [CChar](repeating: 0, count: 512)
        let capacity = description.count
        let count = data.withUnsafeBytes { siril_icc_chromaticity($0.baseAddress, $0.count, &points, &description, capacity) }
        guard count > 0, count == 1 || points.allSatisfy(\.isFinite) else { throw EngineError.failed("此 ICC 配置文件无法生成色域图。") }
        channels = Int(count); coordinates = points; name = String(cString: description)
    }
}
private struct ICCPlotPoint: Identifiable {
    let id: Int, series: String
    let x: Double, y: Double
}
struct ICCChromaticityView: View {
    let profile: ICCChromaticity
    @Environment(\.dismiss) private var dismiss
    @State private var compareSRGB = true
    private var points: [ICCPlotPoint] {
        var locus = [Double](repeating: 0, count: 644)
        guard siril_icc_spectral_locus(&locus, locus.count) != 0 else { return [] }
        var result = (0..<322).map { ICCPlotPoint(id: $0, series: "CIE 1931", x: locus[2 * $0], y: locus[2 * $0 + 1]) }
        for index in 0..<4 {
            let c = index % 3
            result.append(ICCPlotPoint(id: 322 + index, series: "图像 ICC（D50）", x: profile.coordinates[2 * c], y: profile.coordinates[2 * c + 1]))
        }
        if compareSRGB {
            // Same reference vertices as the pinned original Siril plot.
            let srgb = [(0.639998686, 0.330010138), (0.300003784, 0.600003357), (0.150002046, 0.059997204)]
            for index in 0..<4 { result.append(ICCPlotPoint(id: 326 + index, series: "sRGB 参考", x: srgb[index % 3].0, y: srgb[index % 3].1)) }
        }
        return result
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(profile.name).font(.headline).textSelection(.enabled)
                    if profile.channels == 3 {
                        Toggle("对照 sRGB", isOn: $compareSRGB)
                        Chart {
                            ForEach(points) { point in
                                LineMark(x: .value("CIE x", point.x), y: .value("CIE y", point.y), series: .value("曲线", point.series))
                                    .foregroundStyle(by: .value("曲线", point.series))
                            }
                            PointMark(x: .value("CIE x", profile.coordinates[6]), y: .value("CIE y", profile.coordinates[7]))
                                .foregroundStyle(.blue).annotation(position: .top) { Text("D50 白点").font(.caption) }
                        }
                        .chartXScale(domain: 0...0.8).chartYScale(domain: 0...0.9)
                        .chartXAxisLabel("CIE x").chartYAxisLabel("CIE y")
                        .frame(minHeight: 360)
                        Text("使用原版 Siril 的 D50 色度转换与 CIE 1931 光谱轨迹；三角形和白点来自当前 ICC 配置文件。sRGB 参考坐标与原版色域图一致。").font(.caption).foregroundStyle(.secondary)
                    } else { Text("灰度配置文件没有 RGB 色域三角形。") }
                }.padding()
            }
            .navigationTitle("ICC 色域图").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
