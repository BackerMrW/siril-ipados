// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum NativeTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case mtf, inverseMTF, asinh, ghs, inverseGHS, modifiedAsinh, inverseModifiedAsinh, linearStretch, automatic, automaticGHS
    case saturation, greenNoise, negative, unpurple, ccm
    case median, gaussian, unsharp, clahe, banding, bilateral, guided, denoise, wavelets
    case crop, rotate, rotate90, rotate270, rotate180, mirrorHorizontal, mirrorVertical, binning, resample
    var id: String { rawValue }
    var title: String { switch self {
    case .mtf: return "直方图变换 · MTF"; case .inverseMTF: return "反向 MTF"
    case .asinh: return "Asinh 拉伸"; case .ghs: return "广义双曲拉伸 · GHS"; case .inverseGHS: return "反向 GHS"
    case .modifiedAsinh: return "修正 Asinh"; case .inverseModifiedAsinh: return "反向修正 Asinh"
    case .linearStretch: return "线性拉伸"; case .automatic: return "自动 MTF"; case .automaticGHS: return "自动 GHS"
    case .saturation: return "颜色饱和度"; case .greenNoise: return "去绿色噪声 · SCNR"; case .negative: return "负片变换"
    case .unpurple: return "去紫色边缘 · Unpurple"; case .ccm: return "颜色转换矩阵 · CCM"
    case .median: return "中值滤波"; case .gaussian: return "高斯模糊"; case .unsharp: return "反锐化遮罩"; case .clahe: return "局部直方图均衡 · CLAHE"
    case .banding: return "条纹消除"; case .bilateral: return "双边滤波"; case .guided: return "引导滤波"; case .denoise: return "降噪 · NL-Bayes"; case .wavelets: return "À trous 小波"
    case .crop: return "裁剪"; case .rotate: return "旋转与裁剪"; case .rotate90: return "顺时针旋转90°"; case .rotate270: return "逆时针旋转90°"; case .rotate180: return "旋转180°"
    case .mirrorHorizontal: return "水平镜像"; case .mirrorVertical: return "垂直镜像"; case .binning: return "合并像素 · Binning"; case .resample: return "重采样"
    } }
    var group: String { switch self {
    case .mtf, .inverseMTF, .asinh, .ghs, .inverseGHS, .modifiedAsinh, .inverseModifiedAsinh, .linearStretch, .automatic, .automaticGHS: return "拉伸"
    case .saturation, .greenNoise, .negative, .unpurple, .ccm: return "颜色"
    case .median, .gaussian, .unsharp, .clahe, .banding, .bilateral, .guided, .denoise, .wavelets: return "滤镜"
    default: return "几何"
    } }
    var rgbOnly: Bool { [.saturation, .greenNoise, .unpurple, .ccm].contains(self) }
    var acceptsMask: Bool { ![.inverseMTF, .ccm, .banding, .wavelets].contains(self) && group != "几何" }
    static let actions: [String: Self] = ["win.histo-processing": .mtf, "win.asinh-processing": .asinh, "win.payne-processing": .ghs,
        "win.saturation-processing": .saturation, "win.remove-green-processing": .greenNoise, "win.negative-processing": .negative,
        "win.unpurple-processing": .unpurple, "win.ccm-processing": .ccm, "win.medianfilter-processing": .median,
        "win.clahe-processing": .clahe, "win.fix-banding-processing": .banding, "win.epf-processing": .bilateral,
        "win.denoise-processing": .denoise, "win.wavelets-processing": .wavelets, "win.crop": .crop,
        "win.rotation-processing": .rotate, "win.rotation90-processing": .rotate90, "win.rotation270-processing": .rotate270,
        "win.mirrorx-processing": .mirrorHorizontal, "win.mirrory-processing": .mirrorVertical, "win.binning-processing": .binning, "win.resample-processing": .resample]
}

struct ToolField: Identifiable, Sendable {
    let id: String, title: String
    let value: Double, lower: Double, upper: Double
    var integer = false
    var choices: [String] = []
    var boolean = false
    static func number(_ id: String, _ title: String, _ value: Double, _ lower: Double, _ upper: Double, integer: Bool = false) -> Self {
        Self(id: id, title: title, value: value, lower: lower, upper: upper, integer: integer)
    }
    static func toggle(_ id: String, _ title: String, _ enabled: Bool) -> Self { Self(id: id, title: title, value: enabled ? 1 : 0, lower: 0, upper: 1, integer: true, boolean: true) }
    static func choice(_ id: String, _ title: String, _ titles: [String], _ selected: Int = 0) -> Self { Self(id: id, title: title, value: Double(selected), lower: 0, upper: Double(titles.count - 1), integer: true, choices: titles) }
    func valid(_ v: Double) -> Bool { v.isFinite && (lower...upper).contains(v) && (!integer || v.rounded() == v) }
}

extension NativeTool {
    var fields: [ToolField] {
        let n = ToolField.number, b = ToolField.toggle, c = ToolField.choice
        let channels = c("channels", "处理通道", ["RGB / 灰度", "R", "G", "B", "RG", "RB", "GB"], 0)
        let clipping = c("clip", "高光溢出", ["裁切", "逐通道重缩放", "全局重缩放", "RGB 混合"], 3)
        let colour = c("colour", "颜色拉伸模型", ["独立通道", "人眼加权亮度", "等权亮度", "饱和度"], 0)
        let interp = c("interp", "插值", ["最近邻", "双线性", "双三次", "像素面积", "Lanczos4"], 4)
        switch self {
        case .mtf, .inverseMTF: return [n("low", "黑点", 0, 0, 1, false), n("mid", "中间调", 0.5, 0.000001, 0.999999, false), n("high", "白点", 1, 0, 1, false), channels]
        case .asinh: return [n("stretch", "拉伸系数", 1, 1, 1000, false), n("offset", "黑点偏移", 0, 0, 0.2, false), b("human", "人眼加权亮度", true), clipping]
        case .ghs, .inverseGHS, .modifiedAsinh, .inverseModifiedAsinh:
            var f = [n("D", "拉伸量 D", 0, 0, 10, false), n("LP", "阴影保护 LP", 0, 0, 1, false), n("SP", "对称点 SP", 0, 0, 1, false), n("HP", "高光保护 HP", 1, 0, 1, false), colour, channels, clipping]
            if self == .ghs || self == .inverseGHS { f.insert(n("B", "局部强度 B", 0.5, -5, 15, false), at: 1) }; return f
        case .linearStretch: return [n("BP", "黑点 BP", 0, 0, 0.999999, false), channels, b("sat", "作用于饱和度", false)]
        case .automatic: return [n("shadow", "阴影剪切 Sigma", -2.8, -20, 0, false), n("target", "目标背景", 0.25, 0.000001, 0.999999, false), b("linked", "链接 RGB 通道", true)]
        case .automaticGHS: return [n("shadow", "阴影剪切 Sigma", -2.8, -20, 0, false), n("amount", "拉伸量", 2, 0, 10, false), n("B", "局部强度 B", 13, -5, 15, false), n("LP", "阴影保护 LP", 0, 0, 1, false), n("HP", "高光保护 HP", 0.7, 0, 1, false), b("linked", "链接 RGB 通道", true), clipping]
        case .saturation: return [n("amount", "饱和度调整", 0, -1, 1, false), n("background", "背景保护系数", 1, 0, 2, false), c("hue", "色相范围", ["粉红—红 / 红—橙", "橙—棕 / 黄", "黄—绿 / 绿—青", "青", "青—蓝 / 蓝—品红", "品红 / 粉红", "全部色相"], 6)]
        case .greenNoise: return [c("type", "保护模型", ["平均中性", "最大中性", "最大蒙版", "加法蒙版"], 0), n("amount", "蒙版强度", 1, 0, 1, false), b("preserve", "保留明度", true)]
        case .unpurple: return [n("mod", "蓝通道调节量", 1, 0, 1, false), n("threshold", "阈值", 0, 0, 1, false), b("stars", "使用星点蒙版", false)]
        case .ccm: return (0..<9).map { i in n("m\(i)", "矩阵 \(i / 3 + 1),\(i % 3 + 1)", i % 4 == 0 ? 1 : 0, -100, 100, false) } + [n("gamma", "Gamma / 幂", 1, 0, 10, false)]
        case .median: return [c("kernel", "核尺寸", ["3", "5", "7", "9", "11", "13", "15"], 0), n("amount", "调节量", 1, 0, 1, false), n("iterations", "迭代次数", 1, 1, 10, true)]
        case .gaussian: return [n("sigma", "Sigma", 1, 0.001, 100, false)]
        case .unsharp: return [n("sigma", "Sigma", 1, 0.001, 100, false), n("amount", "锐化系数", 1, 0, 100, false)]
        case .clahe: return [n("cliplimit", "对比度限制", 2, 0.01, 50, false), n("tiles", "网格尺寸", 8, 1, 128, true)]
        case .banding: return [n("amount", "强度", 1, 0.001, 4, false), b("protect", "保护高光", false), n("sigma", "高光 Sigma", 1, 0.01, 5, false), b("vertical", "竖向条纹", false)]
        case .bilateral, .guided: return [n("diameter", self == .guided ? "窗口半径" : "窗口直径", 0, 0, 20, false), n("intensity", "强度 Sigma", 11, 0.000001, 65535, false), n("spatial", "空间 Sigma", 11, 0.000001, 32, false), n("amount", "调节量", 1, 0, 1, false)]
        case .denoise: return [n("amount", "调节量", 1, 0.000001, 1, false), b("cosmetic", "去椒盐噪声", true), b("independent", "独立通道", false), b("vst", "Anscombe VST", true), c("secondary", "第二阶段", ["无", "DA3D", "SOS"], 0), n("iterations", "SOS 迭代", 3, 1, 100, true), n("rho", "SOS rho", 0.2, 0.000001, 0.999999, false)]
        case .wavelets: return [n("layers", "小波层数", 6, 2, 6, true), c("type", "变换", ["线性", "B 样条"], 1), b("vst", "Anscombe VST", false), b("denoise", "小波降噪", false), c("method", "降噪方法", ["BiShrink", "阈值"], 0), b("soft", "软阈值", true), b("perband", "逐尺度测量噪声", false), n("k", "阈值 k", 3, 0, 10, false)] + (0..<6).flatMap { i in [n("c\(i)", "第\(i + 1)层系数", 1, 0.01, 100, false), n("f\(i)", "第\(i + 1)层降噪强度", 1, 0, 5, false)] }
        case .crop: return [n("x", "左上角 X", 0, 0, 100000, true), n("y", "左上角 Y", 0, 0, 100000, true), n("width", "宽", 100, 1, 100000, true), n("height", "高", 100, 1, 100000, true)]
        case .rotate: return [n("angle", "角度", 0, -180, 180, false), b("crop", "裁切旋转边缘", true), interp, b("clamp", "插值钳位", true)]
        case .binning: return [n("factor", "合并系数", 2, 1, 50, true), c("method", "合并方法", ["均值", "求和"], 0)]
        case .resample: return [c("mode", "尺寸指定", ["倍率", "宽度（保持比例）", "高度（保持比例）", "最长边", "独立宽与高"], 0), n("scale", "倍率", 1, 0.01, 10, false), n("size", "目标像素数", 2048, 1, 100000, true), n("width", "宽", 2048, 1, 100000, true), n("height", "高", 2048, 1, 100000, true), interp, b("clamp", "插值钳位", true)]
        default: return []
        }
    }
}

struct ToolMask: Codable, Equatable, Sendable {
    var values: [String: Double] = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.value) })
    var sourceID: UUID?
    static var fields: [ToolField] { [
        .choice("mode", "蒙版来源", ["关闭", "当前图像亮度", "当前图像通道", "图库中的图像", "颜色", "星点", "图像保存的蒙版"]),
        .choice("channel", "通道", ["R / 灰度", "G", "B"]), .choice("luminance", "亮度权重", ["人眼加权", "等权"]),
        .choice("depth", "蒙版位深", ["8", "16", "32"], 2), .toggle("stretch", "自动拉伸蒙版", false),
        .number("red", "颜色中心 R", 1, 0, 1), .number("green", "颜色中心 G", 0, 0, 1), .number("blue", "颜色中心 B", 0, 0, 1), .number("tolerance", "颜色容差", 0.1, 0.000001, 1),
        .number("lumLow", "最低亮度", 0, 0, 1), .number("lumHigh", "最高亮度", 1, 0, 1), .number("colourFeather", "颜色羽化像素", 0, 0, 100, integer: true),
        .number("starRadius", "星点半径系数", 1, 0.01, 10), .number("starFeather", "星点羽化", 0, 0, 100),
        .toggle("threshold", "阈值处理", false), .number("low", "蒙版下阈值", 0, 0, 1), .number("high", "蒙版上阈值", 1, 0, 1), .number("range", "阈值过渡", 0, 0, 1),
        .toggle("blur", "模糊蒙版", false), .number("radius", "模糊半径", 1, 0.000001, 100),
        .toggle("feather", "羽化蒙版", false), .number("distance", "羽化距离", 1, 0.000001, 1000), .choice("featherMode", "羽化方向", ["双向", "向内", "向外"]),
        .toggle("invert", "反转蒙版", false), .number("factor", "蒙版乘数", 1, 0, 100)] }
    func number(_ key: String) -> Double { values[key] ?? 0 }
}
struct NativeToolRecipe: Codable, Equatable, Sendable {
    var tool: NativeTool
    var values: [String: Double]
    var mask = ToolMask()
    var guideID: UUID?
    init(tool: NativeTool, file: FITSRecord) {
        self.tool = tool; values = Dictionary(uniqueKeysWithValues: tool.fields.map { ($0.id, $0.value) })
        if file.hasMask == true { mask.values["mode"] = 6 }
        if tool == .crop { values["width"] = Double(file.width); values["height"] = Double(file.height) }
        if tool == .resample { values["width"] = Double(file.width); values["height"] = Double(file.height) }
        if tool == .wavelets { values["layers"] = Double(max(2, min(6, Int(log2(Double(min(file.width, file.height)))) - 2))) }
    }
    func number(_ key: String) -> Double { values[key] ?? 0 }
    func validate(file: FITSRecord) throws {
        guard !tool.rgbOnly || file.channels == 3 else { throw EngineError.failed("此工具需要 RGB 三通道图像。") }
        guard Set(values.keys) == Set(tool.fields.map(\.id)), tool.fields.allSatisfy({ $0.valid(number($0.id)) }),
              Set(mask.values.keys) == Set(ToolMask.fields.map(\.id)), ToolMask.fields.allSatisfy({ $0.valid(mask.number($0.id)) }) else { throw EngineError.failed("工具参数超出原版范围或不是有限数值。") }
        if [.mtf, .inverseMTF].contains(tool), number("low") >= number("high") { throw EngineError.failed("黑点必须小于白点。") }
        if [.ghs, .inverseGHS, .modifiedAsinh, .inverseModifiedAsinh].contains(tool), !(number("LP") <= number("SP") && number("SP") <= number("HP")) { throw EngineError.failed("保护点必须满足 LP ≤ SP ≤ HP。") }
        if tool == .automaticGHS, number("LP") > number("HP") { throw EngineError.failed("阴影保护不能高于高光保护。") }
        if tool == .crop, number("x") + number("width") > Double(file.width) || number("y") + number("height") > Double(file.height) { throw EngineError.failed("裁剪区域超出原图。") }
        if tool == .binning, number("factor") > Double(min(file.width, file.height)) { throw EngineError.failed("合并系数大于图像尺寸。") }
        if tool == .wavelets, number("layers") > log2(Double(min(file.width, file.height))) - 2 { throw EngineError.failed("图像太小，无法使用所选小波层数。") }
        if mask.number("mode") != 0 {
            guard tool.acceptsMask || mask.number("mode") == 6 else { throw EngineError.failed("这个工具当前入口不支持蒙版。") }
            if [2, 5].contains(mask.number("mode")), mask.number("channel") >= Double(file.channels) { throw EngineError.failed("蒙版通道不存在。") }
            if mask.number("mode") == 4 && file.channels != 3 { throw EngineError.failed("颜色蒙版需要 RGB 图像。") }
            if mask.number("mode") == 3 && mask.sourceID == nil { throw EngineError.failed("请选择蒙版图像。") }
            guard mask.number("low") <= mask.number("high"), mask.number("lumLow") <= mask.number("lumHigh") else { throw EngineError.failed("蒙版上下限顺序无效。") }
        }
    }
    func commands(file: FITSRecord, topDown: Bool) throws -> String {
        try validate(file: file)
        func n(_ key: String) -> String { Self.format(number(key)) }
        func on(_ key: String) -> Bool { number(key) == 1 }
        let channel = ["", "R", "G", "B", "RG", "RB", "GB"][Int(number("channels"))]
        let clip = ["clip", "rescale", "globalrescale", "rgbblend"][Int(number("clip"))]
        let colour = ["-independent", "-human", "-even", "-sat"][Int(number("colour"))]
        let interp = ["nearest", "linear", "cubic", "area", "lanczos4"][Int(number("interp"))]
        var command: String
        switch tool {
        case .mtf, .inverseMTF: command = "\(tool == .mtf ? "mtf" : "invmtf") \(n("low")) \(n("mid")) \(n("high")) \(channel)"
        case .asinh: command = "asinh \(on("human") ? "-human " : "")\(n("stretch")) \(n("offset")) -clipmode=\(clip)"
        case .ghs, .inverseGHS, .modifiedAsinh, .inverseModifiedAsinh:
            let name: String = [.ghs: "ght", .inverseGHS: "invght", .modifiedAsinh: "modasinh", .inverseModifiedAsinh: "invmodasinh"][tool]!
            command = "\(name) -D=\(n("D")) -LP=\(n("LP")) -SP=\(n("SP")) -HP=\(n("HP")) \(colour) \(channel) -clipmode=\(clip)"
            if tool == .ghs || tool == .inverseGHS { command += " -B=\(n("B"))" }
        case .linearStretch: command = "linstretch -BP=\(n("BP")) \(channel)\(on("sat") ? " -sat" : "")"
        case .automatic: command = "autostretch \(on("linked") ? "-linked " : "")\(n("shadow")) \(n("target"))"
        case .automaticGHS: command = "autoghs \(on("linked") ? "-linked " : "")\(n("shadow")) \(n("amount")) -b=\(n("B")) -lp=\(n("LP")) -hp=\(n("HP")) -clipmode=\(clip)"
        case .saturation: command = "satu \(n("amount")) \(n("background")) \(n("hue"))"
        case .greenNoise: command = "rmgreen \(n("type"))\(number("type") >= 2 ? " " + n("amount") : "")\(on("preserve") ? "" : " -nopreserve")"
        case .negative: command = "neg"
        case .unpurple: command = "unpurple -mod=\(n("mod")) -thresh=\(n("threshold"))\(on("stars") ? " -starmask" : "")"
        case .ccm: command = "ccm " + (0..<9).map { n("m\($0)") }.joined(separator: " ") + " " + n("gamma")
        case .median: command = "fmedian \(3 + 2 * Int(number("kernel"))) \(n("amount"))"
        case .gaussian: command = "gauss \(n("sigma"))"
        case .unsharp: command = "unsharp \(n("sigma")) \(n("amount"))"
        case .clahe: command = "clahe \(n("cliplimit")) \(n("tiles"))"
        case .banding: command = "fixbanding \(n("amount")) \(on("protect") ? n("sigma") : "0")\(on("vertical") ? " -vertical" : "")"
        case .bilateral, .guided: command = "epf \(tool == .guided ? "-guided " : "")-d=\(n("diameter")) -si=\(n("intensity")) -ss=\(n("spatial")) -mod=\(n("amount"))\(guideID != nil && tool == .guided ? " -guideimage=guide.fits" : "")"
        case .denoise: command = "denoise -mod=\(n("amount"))\(on("cosmetic") ? "" : " -nocosmetic")\(on("independent") ? " -indep" : "")\(on("vst") ? " -vst" : "")"
            if number("secondary") == 1 { command += " -da3d" }; if number("secondary") == 2 { command += " -sos=\(n("iterations")) -rho=\(n("rho"))" }
        case .wavelets:
            command = "atrous \(n("layers")) \(Int(number("type")) + 1) " + (0..<Int(number("layers"))).map { n("c\($0)") }.joined(separator: " ")
            if on("vst") { command += " -anscombe" }
            if on("denoise") { command += " -denoise \(number("method") == 0 ? "-bishrink" : "-threshold") \(on("soft") ? "-soft" : "-hard") -k=\(n("k"))\(on("perband") ? " -perband" : "") " + (0..<Int(number("layers"))).map { "-f\($0 + 1)=\(n("f\($0)"))" }.joined(separator: " ") }
        case .crop:
            // The original crop always indexes ry-y-h, while the native canvas
            // follows the FITS ROWORDER keyword. Convert only at this boundary.
            let cropY = topDown ? Double(file.height) - number("y") - number("height") : number("y")
            command = "crop \(n("x")) \(Self.format(cropY)) \(n("width")) \(n("height"))"
        case .rotate:
            let angle = number("angle") < 0 ? number("angle") + 360 : number("angle")
            command = "rotate \(Self.format(angle)) -interp=\(interp)\(on("crop") ? "" : " -nocrop")\(on("clamp") ? "" : " -noclamp")"
        case .rotate90: command = "rotate 90 -nocrop"; case .rotate270: command = "rotate 270 -nocrop"; case .rotate180: command = "rotatePi"
        // Siril mirrorx flips rows, mirrory flips columns.
        case .mirrorHorizontal: command = "mirrory"; case .mirrorVertical: command = "mirrorx"
        case .binning: command = "binxy \(n("factor"))\(number("method") == 1 ? " -sum" : "")"
        case .resample:
            let size = [n("scale"), "-width=" + n("size"), "-height=" + n("size"), "-maxdim=" + n("size"), "-width=" + n("width") + " -height=" + n("height")][Int(number("mode"))]
            command = "resample \(size) -interp=\(interp)\(on("clamp") ? "" : " -noclamp")"
        }
        let masks = try maskCommands(file: file)
        if !masks.isEmpty && tool.acceptsMask { command += " -mask" }
        let repeats = tool == .median ? Int(number("iterations")) : 1
        return (["set32bits", "load input.fits"] + masks + Array(repeating: command.trimmingCharacters(in: .whitespaces), count: repeats)).joined(separator: "\n") + "\n"
    }
    private func maskCommands(file: FITSRecord) throws -> [String] {
        let m = mask
        func n(_ k: String) -> String { Self.format(m.number(k)) }
        let depth = [8, 16, 32][Int(m.number("depth"))]
        var commands: [String] = []
        switch Int(m.number("mode")) {
        case 0: return []
        case 1: commands = ["mask_from_lum \(m.number("luminance") == 0 ? "-human" : "-even") -bitdepth=\(depth)"]
        case 2: commands = ["mask_from_channel -channel=\(n("channel")) -bitdepth=\(depth)"]
        case 3: commands = ["mask_from_lum \(m.number("luminance") == 0 ? "-human" : "-even") -filename=mask-source.fits -bitdepth=\(depth)"]
        case 6: commands = ["mask_from_channel -channel=0 -filename=mask-source.fits -bitdepth=\(depth)"]
        case 4: commands = ["mask_from_color -cr=\(n("red")) -cg=\(n("green")) -cb=\(n("blue")) -tol=\(n("tolerance")) -lum_min=\(n("lumLow")) -lum_max=\(n("lumHigh")) -fr=\(n("colourFeather")) -bitdepth=\(depth)"]
        case 5: commands = ["findstar -layer=\(n("channel"))", "mask_from_stars -r=\(n("starRadius")) -feather=\(n("starFeather")) -bitdepth=\(depth)"]
        default: throw EngineError.failed("蒙版来源无效。")
        }
        if m.number("stretch") == 1 { commands.append("mask_autostretch") }
        if m.number("threshold") == 1 { commands.append("mask_threshold -lo=\(n("low")) -hi=\(n("high")) -fr=\(n("range"))") }
        if m.number("blur") == 1 { commands.append("mask_blur -r=\(n("radius"))") }
        if m.number("feather") == 1 { commands.append("mask_feather -dist=\(n("distance")) -mode=\(["edge", "inner", "outer"][Int(m.number("featherMode"))])") }
        if m.number("invert") == 1 { commands.append("mask_invert") }
        if m.number("factor") != 1 { commands.append("mask_fmul \(n("factor"))") }
        return commands
    }
    static func format(_ value: Double) -> String { String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value) }
}
