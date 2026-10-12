// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// Matches reset_conv_args and bdeconv_fill_estk_from_gui in the pinned source.
// Keep all GUI parameters in history, including currently hidden method fields.
enum DeconvolutionFields {
    static var all: [ToolField] {
        let n = ToolField.number, c = ToolField.choice, b = ToolField.toggle
        return [c("psfSource", "PSF 来源", ["盲估计", "图像星点", "手动模型", "图库 PSF"]),
            b("estimateOnly", "仅生成 PSF", false), n("ks", "PSF 尺寸（奇数）", 15, 3, 9999, true),
            c("profile", "手动模型", ["Gaussian", "Moffat", "Disc", "Airy"]),
            n("fwhm", "FWHM / Disc 直径（像素）", 3, 0.5, 10, false), n("ratio", "轴比", 1, 0.5, 2, false),
            n("angle", "PSF 角度（度）", 0, 0, 360, false), n("beta", "Moffat β", 4.5, 1.5, 10, false),
            n("diameter", "口径（mm）", 1, 1, 2000, false), n("focal", "焦距（mm）", 1, 1, 60000, false),
            n("wavelength", "波长（nm）", 525, 100, 30000, false), n("pixelSize", "像元（µm）", 0.1, 0.1, 30, false), n("obstruction", "中心遮挡（%）", 0, 0, 99, false),
            b("symmetric", "对称星点 PSF", false), b("autoSize", "按星点自动增大 PSF", false),
            c("blindMethod", "盲估计方法", ["Spectral Irregularity", "ℓ0 descent"], 1), n("weight", "盲估计正则化权重", 3000, 1, 5000, false),
            b("multiscale", "多尺度盲估计", false), n("gamma", "γ", 20, 0, 100, false), n("blindIterations", "盲估计迭代", 3, 1, 50, true),
            n("lambdaRatio", "λ 缩放比例", 1 / 1.1, 0, 1, false), n("lambdaMin", "最低 λ", 0.001, 0.0001, 0.01, false),
            n("scaleFactor", "尺度比例", 0.5, 0, 1, false), n("upBlur", "上采样模糊", 0, 0, 5, false), n("downBlur", "下采样模糊", 1.6, 0, 5, false),
            n("kernelThreshold", "核阈值", 0, 0, 1, false), b("betterKernel", "改进 PSF 核", true), n("kL1", "核 ℓ1", 0.5, 0, 1, false),
            n("compensation", "补偿系数", 2.1, 1, 100, false), n("tries", "估计尝试次数", 30, 4, 128, true),
            n("outer", "外层迭代", 3, 1, 10, true), n("inner", "内层迭代", 300, 1, 500, true),
            c("method", "反卷积方法", ["Split Bregman", "Richardson-Lucy", "Wiener"], 1), n("alpha", "反卷积正则化权重", 3000, 1, 50000, false),
            n("iterations", "反卷积迭代", 10, 1, 10000, true), c("rlMethod", "RL 算法", ["乘法", "梯度下降"], 1),
            c("regularization", "RL 正则化", ["Total Variation", "Frobenius of Hessian", "无"]),
            b("stopping", "启用停止条件", false), n("stop", "停止距离", 0.002, 0.00001, 0.1, false), n("step", "梯度步长", 0.0003, 0.0001, 0.1, false)]
    }
    static func visible(_ values: [String: Double]) -> [ToolField] {
        var names: Set<String> = ["psfSource", "estimateOnly"]
        let source = values["psfSource"] ?? 0
        if source != 3 { names.insert("ks") }
        if source == 1 { names.formUnion(["symmetric", "autoSize"]) }
        if source == 2 {
            names.insert("profile")
            let profile = values["profile"] ?? 0
            if profile == 3 { names.formUnion(["diameter", "focal", "wavelength", "pixelSize", "obstruction"]) }
            else { names.insert("fwhm"); if profile != 2 { names.formUnion(["ratio", "angle"]) }; if profile == 1 { names.insert("beta") } }
        }
        if source == 0 {
            names.formUnion(["blindMethod", "weight"])
            if values["blindMethod"] == 1 {
                names.formUnion(["multiscale", "gamma", "blindIterations", "lambdaRatio", "lambdaMin", "kernelThreshold", "betterKernel", "kL1"])
                if values["multiscale"] == 1 { names.formUnion(["scaleFactor", "upBlur", "downBlur"]) }
            } else { names.formUnion(["compensation", "tries", "outer", "inner"]) }
        }
        if values["estimateOnly"] != 1 {
            names.insert("alpha")
            let method = values["method"] ?? 1
            if method != 2 { names.insert("iterations") }
            if method == 1 {
                names.formUnion(["rlMethod", "regularization", "stopping"])
                if values["stopping"] == 1 { names.insert("stop") }
                if values["rlMethod"] == 1 { names.insert("step") }
            }
        }
        return all.filter { names.contains($0.id) }
    }
}
struct DeconvolutionEditor: View {
    @Binding var recipe: NativeToolRecipe
    let library: [FITSRecord]
    let header: String
    var body: some View {
        Section("PSF 与反卷积参数") {
            if recipe.number("estimateOnly") != 1 {
                Picker("反卷积方法", selection: Binding(get: { recipe.number("method") }, set: { method in
                    var next = recipe; next.values["method"] = method
                    next.values["alpha"] = method == 2 ? 500 : 3000
                    next.values["iterations"] = method == 0 ? 1 : 10; recipe = next
                })) { Text("Split Bregman").tag(0.0); Text("Richardson-Lucy").tag(1.0); Text("Wiener").tag(2.0) }
            }
            ToolFieldControls(fields: DeconvolutionFields.visible(recipe.values), values: $recipe.values)
            if recipe.number("psfSource") == 3 {
                Picker("PSF 图像", selection: $recipe.psfID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(library.filter { $0.width == $0.height && [1, 3].contains($0.channels) }) { item in Text(item.displayName).tag(Optional(item.id)) }
                }
            }
            if recipe.number("psfSource") == 2 && recipe.number("profile") == 3 {
                Button("读取 FITS 光学参数") {
                    var next = recipe
                    for (field, key) in [("diameter", "APERTURE"), ("focal", "FOCALLEN"), ("pixelSize", "XPIXSZ")] {
                        let row = header.components(separatedBy: .newlines).first { $0.prefix(8).trimmingCharacters(in: .whitespaces) == key }
                        if let row, let separator = row.firstIndex(of: "="), let text = row[row.index(after: separator)...].split(separator: "/").first,
                           let value = Double(text.trimmingCharacters(in: .whitespaces)), let fieldInfo = DeconvolutionFields.all.first(where: { $0.id == field }), fieldInfo.valid(value) { next.values[field] = value }
                    }
                    recipe = next
                }
            }
            Text("计算调用原版 PSF 生成器与反卷积 worker。生成的 PSF 与结果分别保存，可在图库重新载入。固定上游的“从选区生成 PSF”尚未实现。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
