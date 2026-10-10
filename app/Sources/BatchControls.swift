// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

protocol BatchChoice: RawRepresentable, CaseIterable, Identifiable, Codable, Sendable where RawValue == String {
    var title: String { get }
}
extension BatchChoice { var id: String { rawValue } }
enum DarkOptimization: String, BatchChoice {
    case none, noise, exposure
    var title: String { switch self { case .none: return "不缩放"; case .noise: return "最小化背景噪声"; case .exposure: return "按曝光时间缩放" } }
}
enum RegistrationTransform: String, BatchChoice {
    case homography, affine, similarity, shift
    var title: String { switch self { case .homography: return "单应性"; case .affine: return "仿射"; case .similarity: return "相似变换"; case .shift: return "仅平移" } }
}
enum RegistrationInterpolation: String, BatchChoice {
    case lanczos4, cubic, linear, nearest, area, none
    var title: String { switch self { case .lanczos4: return "Lanczos-4"; case .cubic: return "双三次"; case .linear: return "双线性"; case .nearest: return "最近邻"; case .area: return "区域"; case .none: return "不插值（仅平移）" } }
    var supportsClamp: Bool { self == .lanczos4 || self == .cubic }
}
enum RegistrationFraming: String, BatchChoice {
    case current, min, max, cog
    var title: String { switch self { case .current: return "参考帧范围"; case .min: return "共同重叠范围"; case .max: return "全部图像范围"; case .cog: return "图像中心" } }
}
enum DrizzleKernel: String, BatchChoice {
    case point, turbo, square, gaussian, lanczos2, lanczos3
    var title: String { switch self { case .point: return "Point"; case .turbo: return "Turbo"; case .square: return "Square"; case .gaussian: return "Gaussian"; case .lanczos2: return "Lanczos-2"; case .lanczos3: return "Lanczos-3" } }
}
struct DrizzleOptions: Codable, Sendable {
    var enabled = false
    var kernel: DrizzleKernel = .square
    var pixelFraction = 1.0
    var useFlat = false
    var matchWeightBitDepth = false
}
enum StackMethod: String, BatchChoice {
    case mean, median, sum, min, max
    var title: String { switch self { case .mean: return "平均值"; case .median: return "中位数"; case .sum: return "求和"; case .min: return "最小值"; case .max: return "最大值" } }
    var supportsNormalization: Bool { self == .mean || self == .median }
}
enum StackRejection: String, BatchChoice {
    case winsorized, sigma, mad, median, linear, generalized, percentile, none
    var title: String { switch self { case .winsorized: return "Winsorized Sigma"; case .sigma: return "Sigma"; case .mad: return "MAD"; case .median: return "Median Sigma"; case .linear: return "线性拟合"; case .generalized: return "广义 ESD"; case .percentile: return "百分位"; case .none: return "不剔除" } }
    var defaults: (Double, Double) { self == .generalized ? (0.3, 0.05) : self == .percentile ? (0.2, 0.1) : (3, 3) }
    var fractional: Bool { self == .generalized || self == .percentile }
}
enum StackNormalization: String, BatchChoice {
    case addscale, add, mulscale, mul, none
    var title: String { switch self { case .addscale: return "加法与缩放"; case .add: return "加法"; case .mulscale: return "乘法与缩放"; case .mul: return "乘法"; case .none: return "不归一化" } }
}
enum StackWeight: String, BatchChoice {
    case none, noise, nbstars, wfwhm, nbstack
    var title: String { switch self { case .none: return "等权"; case .noise: return "噪声"; case .nbstars: return "星点数量"; case .wfwhm: return "加权 FWHM"; case .nbstack: return "已叠加帧数" } }
}
enum RejectionMaps: String, BatchChoice {
    case none, merged, separate
    var title: String { switch self { case .none: return "不保存"; case .merged: return "合并高低剔除图"; case .separate: return "分别保存高低剔除图" } }
}
enum QualityMetric: String, BatchChoice {
    case fwhm, wfwhm, round, bkg, nbstars
    var title: String { switch self { case .fwhm: return "FWHM"; case .wfwhm: return "加权 FWHM"; case .round: return "圆度"; case .bkg: return "背景"; case .nbstars: return "星点数量" } }
}
enum QualityLimit: String, BatchChoice {
    case percentage, threshold, sigma
    var title: String { switch self { case .percentage: return "保留最佳百分比"; case .threshold: return "绝对阈值"; case .sigma: return "Sigma 阈值" } }
    var suffix: String { self == .percentage ? "%" : self == .sigma ? "k" : "" }
}
struct QualityFilter: Codable, Sendable {
    var enabled = false
    var metric: QualityMetric = .fwhm
    var limit: QualityLimit = .percentage
    var value = 90.0
}
struct BatchOptions: Codable, Sendable {
    var debayer = false
    var register = true
    var cfa = false
    var equalizeCFA = false
    var fixXTrans = false
    var darkOptimization: DarkOptimization = .none
    var cosmetic = false
    var coldSigma = 0.0
    var hotSigma = 3.0
    var twoPass = false
    var transform: RegistrationTransform = .homography
    var interpolation: RegistrationInterpolation = .lanczos4
    var clamp = true
    var minimumPairs = 10
    var maximumStars = 2000
    var layer = 1
    var scale = 1.0
    var framing: RegistrationFraming = .current
    var referenceID: UUID?
    // Optional storage keeps 0.7 JSON readable without discarding saved settings.
    var drizzle: DrizzleOptions?
    var drizzleOptions: DrizzleOptions {
        get { drizzle ?? DrizzleOptions() }
        set { drizzle = newValue }
    }
    var method: StackMethod = .mean
    var rejection: StackRejection = .winsorized
    var low = 3.0
    var high = 3.0
    var normalization: StackNormalization = .addscale
    var outputNormalization = true
    var fastNormalization = false
    var equalizeRGB = false
    var weight: StackWeight = .none
    var maps: RejectionMaps = .none
    var filters = QualityMetric.allCases.map { QualityFilter(metric: $0) }

    // JSON stores the UI configuration; processing.ssf is the executed source
    // of truth and is saved separately even when the user edits it manually.
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "batch-options-v1"),
              let options = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return options
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "batch-options-v1") } }
}

struct BatchPicker<Choice: BatchChoice>: View where Choice.AllCases: RandomAccessCollection, Choice: Hashable {
    let title: String
    @Binding var value: Choice
    var body: some View { Picker(title, selection: $value) { ForEach(Choice.allCases) { Text($0.title).tag($0) } } }
}
struct BatchNumber: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        HStack { Text(title); Spacer(); TextField(title, value: $value, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110) }
    }
}
struct BatchControls: View {
    @Binding var options: BatchOptions
    let lights: [FITSRecord]
    var body: some View {
        Section("校准") {
            Toggle("CFA 原始马赛克数据", isOn: $options.cfa)
            Toggle("校准后去马赛克", isOn: $options.debayer)
            if options.cfa || options.debayer {
                Toggle("平场 CFA 通道均衡", isOn: $options.equalizeCFA)
                Toggle("修复 X-Trans 暗场模式", isOn: $options.fixXTrans)
            }
            BatchPicker(title: "暗场优化", value: $options.darkOptimization)
            if options.darkOptimization != .none {
                Text("优化会先从暗场扣除主偏置；亮场也单独扣除偏置。请导入偏置帧。有辉光的 CMOS 暗场通常应保持不缩放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("主暗场坏点修正", isOn: $options.cosmetic)
            if options.cosmetic {
                BatchNumber(title: "冷像素 Sigma（0 关闭）", value: $options.coldSigma)
                BatchNumber(title: "热像素 Sigma（0 关闭）", value: $options.hotSigma)
            }
            Text("一张偏置、暗场或暗平场按现成主帧使用；多张生成中位数主帧。平场仍会先扣除偏置或暗平场，再生成主平场。")
                .font(.caption).foregroundStyle(.secondary)
        }.id("calibration")
        Section("全局星点配准") {
            Toggle("启用配准", isOn: $options.register)
            if options.register {
                Toggle("两遍配准", isOn: $options.twoPass)
                Picker("参考亮场", selection: $options.referenceID) {
                    Text("Siril 自动选择").tag(UUID?.none)
                    ForEach(lights) { Text($0.displayName).tag(Optional($0.id)) }
                }
                BatchPicker(title: "变换模型", value: $options.transform)
                if !options.drizzleOptions.enabled {
                    BatchPicker(title: "插值", value: $options.interpolation)
                    if options.interpolation.supportsClamp { Toggle("插值钳位", isOn: $options.clamp) }
                }
                Stepper("最少匹配星对：\(options.minimumPairs)", value: $options.minimumPairs, in: 4...2000)
                Stepper("最多检测星点：\(options.maximumStars)", value: $options.maximumStars, in: 100...2000, step: 100)
                Picker("检测通道", selection: $options.layer) {
                    Text("红 / 单色").tag(0); Text("绿").tag(1); Text("蓝").tag(2)
                }
                BatchNumber(title: "输出倍率（0.1–3）", value: $options.scale)
                if options.twoPass { BatchPicker(title: "输出范围", value: $options.framing) }
                Text("两遍模式会执行 register -2pass 后再执行 seqapplyreg，生成可叠加的实际图像。单色数据自动使用通道 0。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.id("batch-registration")
        Section("Drizzle / Bayer Drizzle") {
            Toggle("使用 Drizzle 应用配准", isOn: $options.drizzleOptions.enabled)
            if options.drizzleOptions.enabled {
                BatchPicker(title: "Drizzle 核", value: $options.drizzleOptions.kernel)
                BatchNumber(title: "像素比例（0.1–10）", value: $options.drizzleOptions.pixelFraction)
                Toggle("主平场用于初始像素权重", isOn: $options.drizzleOptions.useFlat)
                Toggle("权重位深匹配输出（32 位）", isOn: $options.drizzleOptions.matchWeightBitDepth)
                Text("关闭时沿用原版默认的 8 位权重；开启时保存 32 位浮点权重，保留更高精度并增加存储占用。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("输出倍率使用上方配准设置（0.1–3）。原版像素比例默认 1；通常可从倍率的倒数开始尝试。主平场仍正常用于校准，此开关额外用于像素权重。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("单色使用普通 Drizzle；带 BAYERPAT 的单通道 Bayer 数据由原版自动生成 RGB。Bayer 模式请开启 CFA、关闭校准后去马赛克。RGB 与 X-Trans 输入不能使用此流程。建议用平均值或求和叠加，以利用像素权重。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("提高倍率会增加输出及权重文件占用；例如 2 倍生成约 4 倍像素。权重保存在任务 process/drizztmp 中，删除整份任务时一并处理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.id("batch-drizzle").disabled(!options.register)
        StackControls(options: $options)
    }
}

struct StackControls: View {
    @Binding var options: BatchOptions
    var body: some View {
        Section("叠加") {
            BatchPicker(title: "合成方法", value: $options.method)
            if options.method == .mean {
                BatchPicker(title: "异常值剔除", value: $options.rejection)
                    .onChange(of: options.rejection) { _, algorithm in
                        (options.low, options.high) = algorithm.defaults
                    }
                if options.rejection != .none {
                    BatchNumber(title: options.rejection == .generalized ? "最大异常值比例" : "低阈值", value: $options.low)
                    BatchNumber(title: options.rejection == .generalized ? "显著性水平" : "高阈值", value: $options.high)
                    BatchPicker(title: "剔除图", value: $options.maps)
                }
                BatchPicker(title: "图像权重", value: $options.weight)
            }
            if options.method.supportsNormalization {
                BatchPicker(title: "输入归一化", value: $options.normalization)
                if options.normalization != .none {
                    Toggle("快速归一化", isOn: $options.fastNormalization)
                    Toggle("RGB 通道均衡", isOn: $options.equalizeRGB)
                }
                Toggle("输出归一化", isOn: $options.outputNormalization)
            }
            Text("剔除参数与算法对应；百分位和广义 ESD 的两个参数必须在 0–1 之间。结果使用 32 位 FITS，保留校准及叠加精度。")
                .font(.caption).foregroundStyle(.secondary)
        }.id("batch-stacking")
        QualityFilterControls(options: $options, title: "叠加质量筛选")
    }
}

struct QualityFilterControls: View {
    @Binding var options: BatchOptions
    let title: String
    var body: some View {
        Section(title) {
            if options.register {
                ForEach(options.filters.indices, id: \.self) { index in
                    Toggle(options.filters[index].metric.title, isOn: $options.filters[index].enabled)
                    if options.filters[index].enabled {
                        BatchPicker(title: "筛选方式", value: $options.filters[index].limit)
                        BatchNumber(title: "阈值", value: $options.filters[index].value)
                    }
                }
                Text("同时启用的条件取交集。FWHM 与背景保留较低值；圆度与星数保留较高值。筛选后不足两张时，Siril 会停止处理并保留日志。")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("启用星点配准后，可使用配准测得的质量参数筛选图像。") }
        }
    }
}
