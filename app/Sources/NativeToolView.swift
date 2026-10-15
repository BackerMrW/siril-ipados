// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct ToolFieldControls: View {
    let fields: [ToolField]
    @Binding var values: [String: Double]
    var body: some View {
        ForEach(fields) { field in
            let binding = Binding(get: { values[field.id] ?? field.value }, set: { values[field.id] = $0 })
            if field.boolean {
                Toggle(field.title, isOn: Binding(get: { binding.wrappedValue == 1 }, set: { binding.wrappedValue = $0 ? 1 : 0 }))
            } else if !field.choices.isEmpty {
                Picker(field.title, selection: binding) { ForEach(field.choices.indices, id: \.self) { i in Text(field.choices[i]).tag(Double(i)) } }
            } else {
                HStack {
                    Text(field.title); Spacer()
                    TextField(field.title, value: binding, format: .number).multilineTextAlignment(.trailing).frame(width: 115).keyboardType(.numbersAndPunctuation)
                    Stepper(field.title, value: binding, in: field.lower...field.upper, step: field.integer ? 1 : 0.01).labelsHidden()
                }
            }
        }
    }
}

struct NativeToolView: View {
    let file: FITSRecord
    let initialTool: NativeTool
    let engine: SirilEngine
    let onOutput: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session = NativeToolSession()
    @State private var recipe: NativeToolRecipe
    @State private var history: NativeToolHistory?
    @State private var library: [FITSRecord] = []
    @State private var sourceOptics: [String: Double] = [:]
    @State private var kernelWidth = 1
    @State private var kernelHeight = 1
    @State private var originalImage: UIImage?
    @State private var resultImage: UIImage?
    @State private var maskImage: UIImage?
    @State private var resultWidth = 1
    @State private var resultHeight = 1
    @State private var view = 0
    @State private var channel = -1
    @State private var displaySettings = NativeDisplaySettings(mode: .linear)
    @State private var selecting = false
    @State private var region: ImageSelection?
    @State private var busy = false
    @State private var loaded = false
    @State private var curvePipette = false
    @State private var curveTone: Double?
    @State private var originalCurveHistograms: [[UInt64]] = []
    @State private var resultCurveHistograms: [[UInt64]] = []
    @State private var validPreview = false
    @State private var message = ""
    @State private var log = ""
    @State private var importingICC = false
    @State private var exportedICC: URL?
    @State private var iccDiagram: ICCChromaticity?
    @State private var persistTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?
    @State private var logTask: Task<Void, Never>?
    init(file: FITSRecord, tool: NativeTool, engine: SirilEngine, onOutput: @escaping (URL) -> Void) {
        self.file = file; self.initialTool = tool; self.engine = engine; self.onOutput = onOutput
        _recipe = State(initialValue: NativeToolRecipe(tool: tool, file: file))
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > 850 {
                    HStack(spacing: 0) { canvas; controls.frame(width: 440) }
                } else {
                    VStack(spacing: 0) { canvas.frame(height: geometry.size.height * 0.45); controls }
                }
            }
            .navigationTitle(recipe.tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("应用并另存") { apply() }.disabled(busy || !validPreview) }
                if busy { ToolbarItem { Button("中止", role: .destructive) { siril_cancel_processing() } } }
            }
            .interactiveDismissDisabled(busy)
            .task { await open() }
            .sheet(item: $iccDiagram) { ICCChromaticityView(profile: $0) }
            .fileImporter(isPresented: $importingICC, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard ((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw EngineError.failed("ICC 文件最大为16 MiB。") }
                    let resource = ICCProfileResource(name: url.lastPathComponent, data: try Data(contentsOf: url))
                    try resource.validate(channels: file.channels)
                    recipe.iccProfile = resource; recipe.values["profile"] = 5
                } catch { message = error.localizedDescription }
            }
            .onChange(of: recipe) { _, value in edited(value) }
            .onChange(of: recipe.previewRegion) { _, value in
                if recipe.tool.supportsPreviewRegion { region = value }
            }
            .onChange(of: recipe.tool) { _, tool in
                region = recipe.previewRegion; selecting = false
                if tool == .curves && originalCurveHistograms.isEmpty {
                    Task {
                        do { originalCurveHistograms = try await session.curveHistograms(view: 0) }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            .onChange(of: view) { _, _ in refresh() }
            .onChange(of: channel) { _, _ in refresh() }
            .onChange(of: displaySettings) { _, _ in refresh() }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                previewTask?.cancel(); logTask?.cancel()
                let pending = persistTask
                Task { await pending?.value; await session.close() }
            }
        }
    }
    private var canvas: some View {
        VStack(spacing: 8) {
            Picker("预览", selection: $view) {
                Text("原图").tag(0); Text("处理结果").tag(1); Text("蒙版").tag(2); if recipe.tool == .fftDirect { Text("相位谱").tag(3) }; if recipe.tool == .deconvolution { Text("PSF").tag(4) }
            }.pickerStyle(.segmented).padding(.horizontal)
            let image = view == 0 ? originalImage : (view == 2 || view == 3 || view == 4) ? maskImage : resultImage
            if let image {
                ZoomableImageCanvas(image: image, samples: [], imageWidth: Double(view == 0 ? file.width : view == 4 ? kernelWidth : resultWidth), imageHeight: Double(view == 0 ? file.height : view == 4 ? kernelHeight : resultHeight), region: view == 0 ? region : nil, selecting: selecting && view == 0,
                    onSelection: { selection in
                        region = selection
                        if recipe.tool == .crop {
                            recipe.values["x"] = Double(selection.x); recipe.values["y"] = Double(selection.y)
                            recipe.values["width"] = Double(selection.width); recipe.values["height"] = Double(selection.height)
                        }
                        if recipe.tool.supportsPreviewRegion { recipe.previewRegion = selection }
                    }, onTap: recipe.tool == .curves && curvePipette && view == 0 ? { x, y in pickCurveTone(x: x, y: y) } : nil)
                    .background(.black)
            } else { ContentUnavailableView(view == 2 ? "当前没有蒙版预览" : "请计算预览", systemImage: "photo") }
            HStack {
                Picker("显示通道", selection: $channel) { Text("RGB / 灰度").tag(-1); if file.channels == 3 { Text("红").tag(0); Text("绿").tag(1); Text("蓝").tag(2) } }
            }.padding(.horizontal)
            NativeDisplayControls(settings: $displaySettings).padding(.horizontal)
            if recipe.tool == .crop { Toggle("在原图上拖出裁剪选区", isOn: $selecting).padding(.horizontal) }
            if recipe.tool.supportsPreviewRegion {
                Toggle("在原图拖动选择预览 ROI", isOn: Binding(get: { selecting }, set: { selecting = $0; if $0 { view = 0 } })).padding(.horizontal)
                if recipe.previewRegion != nil {
                    Button("清除预览 ROI") { recipe.previewRegion = nil; region = nil; selecting = false }
                }
                Text("ROI 用于选区预览；应用并另存时从输入快照重新计算整张图，输出保留原图尺寸。")
                    .font(.caption).padding(.horizontal)
            }
            if recipe.tool == .colorCalibration && recipe.number("operation") != 0 {
                Toggle("在原图拖出参考选区", isOn: $selecting).padding(.horizontal)
                HStack {
                    ForEach(recipe.number("operation") == 1 ? ["background"] : ["background", "white"], id: \.self) { prefix in
                        Button(prefix == "background" ? "设为背景参考" : "设为白参考") {
                            guard let region else { return }
                            recipe.values[prefix + "X"] = Double(region.x); recipe.values[prefix + "Y"] = Double(region.y)
                            recipe.values[prefix + "Width"] = Double(region.width); recipe.values[prefix + "Height"] = Double(region.height)
                        }.disabled(region == nil)
                    }
                }
                Text("背景中和与白参考校准分别执行。白参考按上下限排除像素；手动系数直接缩放 RGB。原图和保存的蒙版保留。")
                    .font(.caption).padding(.horizontal)
            }
            if recipe.tool == .rotationalGradient {
                Toggle("在原图选择中心星点", isOn: $selecting).padding(.horizontal)
                Button("以选区内星点拟合中心") {
                    guard let region else { return }
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let star = try await session.fitGradientCenter(region)
                            recipe.values["xc"] = star.x; recipe.values["yc"] = star.y
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(region == nil || busy).padding(.horizontal)
            }
            if let region { Text(region.description).font(.caption) }
        }.disabled(busy)
    }
    private var controls: some View {
        Form {
            Section("原版工具") {
                Picker("工具", selection: Binding(get: { recipe.tool }, set: { recipe = NativeToolRecipe(tool: $0, file: file) })) {
                    ForEach(NativeTool.allCases) { tool in Text(tool.title).tag(tool) }
                }
                Text("每次预览从未修改的输入计算。改参数会清除旧预览；应用保存当前计算结果和蒙版，原图保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if recipe.tool == .deconvolution {
                DeconvolutionEditor(recipe: $recipe, library: library, optics: sourceOptics)
            } else if recipe.tool == .curves {
                CurveEditor(settings: Binding(get: { recipe.curveSettings }, set: { recipe.curveSettings = $0 }),
                            pipetteEnabled: $curvePipette, pipetteValue: curveTone,
                            histograms: validPreview && view != 0 ? resultCurveHistograms : originalCurveHistograms,
                            isRGB: file.channels == 3)
            } else if recipe.tool == .pixelMath {
                PixelMathEditor(settings: Binding(get: { recipe.mathSettings }, set: { recipe.mathSettings = $0 }), library: library, file: file)
            } else if recipe.tool == .colorCalibration {
                Section("颜色校准操作") {
                    Picker("操作", selection: Binding(get: { recipe.number("operation") }, set: { recipe.values["operation"] = $0 })) {
                        Text("手动 RGB 系数").tag(0.0); Text("背景中和").tag(1.0); Text("白参考校准").tag(2.0)
                    }
                }
                if recipe.number("operation") == 0 {
                    Section("手动 RGB 系数") { ToolFieldControls(fields: recipe.tool.fields.filter { ["red", "green", "blue"].contains($0.id) }, values: $recipe.values) }
                } else {
                    Section("背景参考选区") { ToolFieldControls(fields: recipe.tool.fields.filter { $0.id.hasPrefix("background") }, values: $recipe.values) }
                    if recipe.number("operation") == 2 {
                        Section("白参考与拒绝范围") { ToolFieldControls(fields: recipe.tool.fields.filter { $0.id.hasPrefix("white") || ["low", "high"].contains($0.id) }, values: $recipe.values) }
                    }
                }
            } else if !recipe.tool.fields.isEmpty {
                Section("参数") { ToolFieldControls(fields: visibleToolFields, values: $recipe.values) }
            }
            if recipe.tool == .fftInverse {
                Section("配对频谱") {
                    Text("当前图像作为幅度谱；选择相同尺寸、通道、位深和频谱顺序的相位谱。由原版 FITS 头中的 DFT 归一化系数恢复幅度。")
                    Picker("相位谱", selection: $recipe.phaseID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(library.filter { $0.width == file.width && $0.height == file.height && $0.channels == file.channels }) { item in Text(item.displayName).tag(Optional(item.id)) }
                    }
                }
            }
            if recipe.tool == .fftDirect {
                Section { Text("应用会分别保存幅度谱和相位谱并加入图库。幅度谱作为处理结果，原图保留；逆变换时打开幅度谱并选择配对相位谱。") }
            }
            if recipe.tool == .plateSolve {
                Section("解算") {
                    Text("使用原版 Siril 星点匹配和 WCS 求解。在线星表需要联网；目标坐标、焦距和像元可从文件头读取，也可手动填写。赤经、赤纬的十进制单位均为度。")
                    Text("已有 WCS 默认保留；打开重新解算可重新匹配。畸变模型随处理记录保存，原始 FITS 保留。")
                }
            }
            if recipe.tool == .colorManagement {
                Section("颜色管理") {
                    Text("分配与移除配置文件保留像素值。转换使用原版 LittleCMS 引擎，需先有源 ICC 配置文件；灰度图保持单通道。应用保存独立 FITS 和操作记录。")
                    if recipe.number("profile") == 5 && recipe.number("action") != 2 {
                        Button("选择 ICC 文件") { importingICC = true }
                        if let profile = recipe.iccProfile { Text(profile.name).font(.caption) }
                        Text("配置文件随参数和处理记录保存，重新打开或重放不需要再次选择原文件。支持与图像匹配的 RGB / 灰度配置文件，最大16 MiB。").font(.caption)
                    }
                    Button("导出原图 ICC") { exportICC(result: false) }
                    Button("查看原图色域") { showICC(result: false) }
                    if validPreview { Button("导出结果 ICC") { exportICC(result: true) } }
                    if validPreview { Button("查看结果色域") { showICC(result: true) } }
                    if let exportedICC { ShareLink("保存 / 分享 ICC", item: exportedICC) }
                }
            }
            if recipe.tool == .spcc {
                SpectralEditor(settings: Binding(get: { recipe.spectralSettings }, set: { recipe.spectralSettings = $0 }),
                    mono: recipe.number("mono") == 1, dslr: true)
            }
            if [.pcc, .spcc].contains(recipe.tool) {
                Section("测光颜色校准") { Text("需要具有 WCS 解算结果的 RGB 图像。原版引擎执行星表测光、颜色系数拟合与背景中和，处理日志保留结果。在线星表需要联网。") }
            }
            if recipe.tool == .guided {
                Section("引导图") {
                    Picker("引导来源", selection: $recipe.guideID) {
                        Text("当前图像自身").tag(UUID?.none)
                        ForEach(library.filter { $0.width == file.width && $0.height == file.height }) { item in Text(item.displayName).tag(Optional(item.id)) }
                    }
                }
            }
            if recipe.tool == .linearMatch {
                Section("线性匹配参考图") {
                    Picker("参考图", selection: $recipe.guideID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(library.filter { $0.width == file.width && $0.height == file.height && $0.channels == file.channels }) { item in
                            Text(item.displayName).tag(Optional(item.id))
                        }
                    }
                    Text("使用上下限内的参考像素逐通道拟合增益与偏移，然后应用于原图全体像素。另存独立结果，保留两张输入。")
                }
            }
            if recipe.tool.acceptsMask {
                Section("处理蒙版") {
                    ToolFieldControls(fields: visibleMaskFields, values: $recipe.mask.values)
                    if recipe.mask.number("mode") == 3 {
                        Picker("蒙版图像", selection: $recipe.mask.sourceID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(library.filter { $0.width == file.width && $0.height == file.height }) { item in Text(item.displayName).tag(Optional(item.id)) }
                        }
                    }
                    Text("亮度、通道、颜色、星点及图像蒙版使用原版生成器；阈值、模糊、羽化、反转与乘法在原版蒙版上执行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("编辑历史") {
                HStack {
                    Button("撤销参数", systemImage: "arrow.uturn.backward") { step(redo: false) }.disabled(history?.past.isEmpty != false)
                    Button("重做参数", systemImage: "arrow.uturn.forward") { step(redo: true) }.disabled(history?.future.isEmpty != false)
                }.buttonStyle(.borderless)
                Button("恢复此工具默认参数") { recipe = NativeToolRecipe(tool: recipe.tool, file: file) }
                Text("工具、参数和蒙版编辑历史跨关闭保存，最多30步；新的编辑清除重做分支。应用后的完整 FITS 可以在主工作区撤销。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("计算原版预览") { compute() }
                if busy { ProgressView("Siril 正在处理") }
                if !validPreview { Text("当前参数尚未完成预览，应用暂不可用。").font(.caption) }
            }
            if !message.isEmpty { Section("提示") { Text(message).textSelection(.enabled) } }
            if !log.isEmpty { Section("原版处理日志") { Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
        }.disabled(busy || !loaded)
    }
    private var visibleToolFields: [ToolField] {
        if recipe.tool == .colorManagement {
            return recipe.tool.fields.filter { $0.id == "action" || (recipe.number("action") != 2 && $0.id == "profile") || (recipe.number("action") == 1 && $0.id == "intent") }
        }
        if [.pcc, .spcc].contains(recipe.tool) {
            return recipe.tool.fields.filter {
                if $0.id == "magnitude" { return recipe.number("magnitudeMode") != 0 }
                if ["rwl", "gwl", "bwl", "rbw", "gbw", "bbw"].contains($0.id) { return recipe.number("narrowband") == 1 }
                if ["height", "pressure"].contains($0.id) { return recipe.number("atmosphere") == 1 }
                return true
            }
        }
        if recipe.tool == .plateSolve {
            return recipe.tool.fields.filter {
                if ["ra", "dec"].contains($0.id) { return recipe.number("headerPosition") == 0 }
                if ["focal", "pixel"].contains($0.id) { return recipe.number("headerOptics") == 0 }
                if $0.id == "magnitude" { return recipe.number("magnitudeMode") != 0 }
                return true
            }
        }
        guard recipe.tool == .resample else { return recipe.tool.fields }
        let mode = recipe.number("mode")
        let names: Set<String> = mode == 0 ? ["mode", "scale", "interp", "clamp"] : mode == 4 ? ["mode", "width", "height", "interp", "clamp"] : ["mode", "size", "interp", "clamp"]
        return recipe.tool.fields.filter { names.contains($0.id) }
    }
    private var visibleMaskFields: [ToolField] {
        let mode = recipe.mask.number("mode")
        let names: Set<String>
        switch mode {
        case 0: names = ["mode"]
        case 1: names = ["mode", "luminance", "depth", "stretch"]
        case 2: names = ["mode", "channel", "depth", "stretch"]
        case 3: names = ["mode", "luminance", "depth", "stretch"]
        case 6: names = ["mode", "depth", "stretch"]
        case 4: names = ["mode", "red", "green", "blue", "tolerance", "lumLow", "lumHigh", "colourFeather", "depth", "stretch"]
        default: names = ["mode", "channel", "starRadius", "starFeather", "depth", "stretch"]
        }
        return ToolMask.fields.filter { field in
            if names.contains(field.id) { return true }
            guard mode != 0 else { return false }
            if ["threshold", "blur", "feather", "invert", "factor"].contains(field.id) { return true }
            if ["low", "high", "range"].contains(field.id) { return recipe.mask.number("threshold") == 1 }
            if field.id == "radius" { return recipe.mask.number("blur") == 1 }
            if ["distance", "featherMode"].contains(field.id) { return recipe.mask.number("feather") == 1 }
            return false
        }
    }
    @MainActor private func open() async {
        do {
            library = await engine.loadLibrary()
            history = try await engine.nativeToolHistory(file, tool: initialTool)
            recipe = history!.current
            if recipe.tool == .fftInverse, recipe.phaseID == nil, let pair = file.spectrumPairID {
                recipe.phaseID = library.first(where: { $0.spectrumPairID == pair && $0.url.lastPathComponent.hasSuffix("fft-phase.fits") })?.id
                history?.record(recipe)
            }
            try await session.open(file)
            let opticalInfo = try await session.info(view: 0)
            sourceOptics = ["diameter": opticalInfo.aperture, "focal": opticalInfo.focal_length, "pixelSize": opticalInfo.pixel_size_x]
            let bytes = try await session.preview(view: 0, channel: channel, settings: displaySettings)
            originalImage = bytes.uiImage; loaded = true
            if recipe.tool == .curves { originalCurveHistograms = try await session.curveHistograms(view: 0) }
            if ProcessInfo.processInfo.environment["SIRIL_NATIVE_TOOL_VIEW_CHECK"] == "1" {
                let section = ProcessInfo.processInfo.environment["SIRIL_NATIVE_TOOL_SECTION"] ?? "ghs"
                recipe = NativeToolRecipe(tool: section.hasPrefix("icc") ? .colorManagement : section == "platesolve" ? .plateSolve : section == "pcc" ? .pcc : section == "spcc" ? .spcc : section.hasPrefix("deconv") ? .deconvolution : section == "fft-inverse" ? .fftInverse : section.hasPrefix("fft") ? .fftDirect : section == "curves" ? .curves : section == "pixelmath" ? .pixelMath : section == "masks" ? .negative : section == "filters" ? .bilateral : section == "geometry" ? .crop : .ghs, file: file)
                if section == "linear-match" {
                    recipe = NativeToolRecipe(tool: .linearMatch, file: file); recipe.guideID = file.id
                }
                if section == "color-calibration" {
                    recipe = NativeToolRecipe(tool: .colorCalibration, file: file)
                    recipe.values["red"] = 0.8; recipe.values["green"] = 0.6; recipe.values["blue"] = 0.4
                }
                if section == "roi" {
                    recipe = NativeToolRecipe(tool: .mtf, file: file); recipe.values["mid"] = 0.25
                    recipe.previewRegion = ImageSelection(x: file.width / 4, y: file.height / 4, width: max(1, file.width / 2), height: max(1, file.height / 2))
                }
                if section == "guided-roi" {
                    recipe = NativeToolRecipe(tool: .guided, file: file); recipe.guideID = file.id
                    recipe.values["diameter"] = 3; recipe.values["amount"] = 0.7
                    recipe.previewRegion = ImageSelection(x: file.width / 4, y: file.height / 4, width: max(1, file.width / 2), height: max(1, file.height / 2))
                    region = recipe.previewRegion
                }
                if section == "rotational-gradient" {
                    recipe = NativeToolRecipe(tool: .rotationalGradient, file: file)
                    recipe.values["xc"] = Double(file.width) / 2; recipe.values["yc"] = Double(file.height) / 2
                    recipe.values["radial"] = 1.5; recipe.values["angle"] = 13
                }
                if ["platesolve", "pcc", "spcc"].contains(section) {
                    if section == "spcc" {
                        var selected = recipe.spectralSettings
                        selected.oscSensor = SpectralModels.names("OSC_SENSOR").first ?? ""
                        recipe.spectralSettings = selected
                        try selected.validate(mono: false, dslr: true)
                    }
                    guard originalImage != nil else { throw EngineError.failed("Astrometry source preview missing") }
                    try? await Task.sleep(for: .milliseconds(500))
                    let marker = await engine.documents.appendingPathComponent("simulator-tools-\(section)-ready.txt")
                    try "PASS: native \(section) workspace loaded original input and parameter controls; spectral selections validated. Calculation verified separately.\n".write(to: marker, atomically: true, encoding: .utf8)
                    return
                }
                if section.hasPrefix("deconv") {
                    recipe.values["psfSource"] = 2; recipe.values["ks"] = 9
                    recipe.values["profile"] = section == "deconv-psf" ? 1 : 0
                    recipe.values["estimateOnly"] = section == "deconv-psf" ? 1 : 0
                    recipe.values["method"] = 1; recipe.values["iterations"] = 2
                    if section == "deconv-roi" {
                        recipe.previewRegion = ImageSelection(x: file.width / 4, y: file.height / 4, width: max(1, file.width / 2), height: max(1, file.height / 2))
                        region = recipe.previewRegion
                    }
                }
                if section == "fft-inverse" { recipe.phaseID = library.last(where: { $0.url.lastPathComponent.hasSuffix("fft-phase.fits") })?.id }
                if section == "ghs" { recipe.values["D"] = 1.2; recipe.values["SP"] = 0.1 }
                if section == "masks" { recipe.mask.values["mode"] = 1; recipe.mask.values["invert"] = 1 }
                if section == "geometry" { recipe.values["x"] = 16; recipe.values["y"] = 24; recipe.values["width"] = 96; recipe.values["height"] = 80 }
                if section == "curves-roi" { recipe = NativeToolRecipe(tool: .curves, file: file) }
                if section.hasPrefix("curves") {
                    recipe.curveSettings.current.channels[0].points.insert(CurveKnot(x: 0.5, y: 0.8), at: 1)
                    recipe.curveSettings.current.channels[0].rangeEnabled = true
                    recipe.curveSettings.current.channels[0].low = 0.05
                    if section == "curves-roi" {
                        recipe.previewRegion = ImageSelection(x: file.width / 4, y: file.height / 4, width: max(1, file.width / 2), height: max(1, file.height / 2))
                        region = recipe.previewRegion
                    }
                }
                if section == "pixelmath" {
                    recipe.mathSettings.expressions[0] = "$T * gain"
                    recipe.mathSettings.parameters = [PMParameter(name: "gain", expression: "1.2")]
                }
                history?.record(recipe)
                try await session.compute(recipe, library: library)
                let info = try await session.info(view: 1); resultWidth = Int(info.width); resultHeight = Int(info.height)
                if recipe.tool == .curves { resultCurveHistograms = try await session.curveHistograms(view: 1) }
                resultImage = try await session.preview(view: 1, channel: -1, settings: displaySettings).uiImage
                if recipe.mask.number("mode") != 0 || section.hasPrefix("curves") { maskImage = try await session.preview(view: 2, channel: -1, automatic: false).uiImage }
                if recipe.tool == .deconvolution {
                    let kernel = try await session.info(view: 4); kernelWidth = Int(kernel.width); kernelHeight = Int(kernel.height)
                    maskImage = try await session.preview(view: 4, channel: -1, automatic: false).uiImage
                }
                view = section == "deconv-psf" ? 4 : section == "fft-phase" ? 3 : section == "masks" ? 2 : section == "geometry" ? 0 : 1; validPreview = true
                if section == "icc-plot" {
                    let diagram = try ICCChromaticity(data: await session.iccProfile(view: 1))
                    guard file.channels == 3, diagram.channels == 3 else { throw EngineError.failed("RGB ICC diagram fixture missing") }
                    iccDiagram = diagram
                }
                if section == "geometry" { region = ImageSelection(x: 16, y: 24, width: 96, height: 80); selecting = true }
                guard originalImage != nil, resultImage != nil, section != "masks" || maskImage != nil else { throw EngineError.failed("Native tool preview image missing") }
                try? await Task.sleep(for: .milliseconds(500))
                guard validPreview, resultImage != nil, !["fft-phase", "deconv-psf"].contains(section) || maskImage != nil else { throw EngineError.failed("Native tool controls invalidated the computed preview") }
                let marker = await engine.documents.appendingPathComponent("simulator-tools-\(section)-ready.txt")
                try "PASS: native tools \(section) loaded original parameters, computed pixels and preview/apply controls.\n".write(to: marker, atomically: true, encoding: .utf8)
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func edited(_ value: NativeToolRecipe) {
        guard loaded, history?.current != value else { return }
        history?.record(value); invalidate(); saveHistory()
    }
    @MainActor private func invalidate() {
        exportedICC = nil
        validPreview = false; resultImage = nil; maskImage = nil; view = 0; message = ""
        curveTone = nil; resultCurveHistograms = []
        previewTask?.cancel()
    }
    @MainActor private func exportICC(result: Bool) {
        busy = true; exportedICC = nil
        Task {
            do {
                let data = try await session.iccProfile(view: result ? 1 : 0)
                exportedICC = try await engine.exportICCProfile(file, data: data, result: result)
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    @MainActor private func showICC(result: Bool) {
        Task {
            do { iccDiagram = try ICCChromaticity(data: await session.iccProfile(view: result ? 1 : 0)) }
            catch { message = error.localizedDescription }
        }
    }
    @MainActor private func pickCurveTone(x: Double, y: Double) {
        let current = recipe.curveSettings
        Task {
            do {
                let tone = try await session.curvePipette(current, x: Int(x), y: Int(y))
                if current == recipe.curveSettings { curveTone = tone }
            } catch { message = error.localizedDescription }
        }
    }
    @MainActor private func saveHistory() {
        persistTask?.cancel()
        guard let history else { return }
        persistTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); try await engine.saveNativeToolHistory(history, file: file) }
            catch is CancellationError { } catch { message = error.localizedDescription }
        }
    }
    @MainActor private func step(redo: Bool) {
        history?.step(redo: redo); if let value = history?.current { recipe = value }
        invalidate(); saveHistory()
    }
    @MainActor private func refresh() {
        previewTask?.cancel()
        let selectedView = view, selectedChannel = channel, stretch = displaySettings
        previewTask = Task {
            do {
                let bytes = try await session.preview(view: selectedView, channel: selectedChannel, settings: stretch)
                try Task.checkCancellation()
                if selectedView == 0 { originalImage = bytes.uiImage } else if selectedView == 1 { resultImage = bytes.uiImage } else { maskImage = bytes.uiImage }
            } catch is CancellationError { } catch { if selectedView == 0 || validPreview { message = error.localizedDescription } }
        }
    }
    @MainActor private func compute() {
        guard !busy else { return }; busy = true; message = ""; validPreview = false
        UIApplication.shared.isIdleTimerDisabled = true
        logTask = Task { while !Task.isCancelled { log = SirilEngine.processingLog(); try? await Task.sleep(for: .milliseconds(300)) } }
        let current = recipe
        Task {
            defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false; logTask?.cancel(); log = SirilEngine.processingLog() }
            do {
                await persistTask?.value
                try await session.compute(current, library: library)
                let info = try await session.info(view: 1); resultWidth = Int(info.width); resultHeight = Int(info.height)
                if current.tool == .curves { resultCurveHistograms = try await session.curveHistograms(view: 1) }
                resultImage = try await session.preview(view: 1, channel: channel, settings: displaySettings).uiImage
                if current.mask.number("mode") != 0 || (current.tool == .curves && current.curveSettings.current.channels[current.curveSettings.selectedChannel].rangeEnabled) {
                    maskImage = try await session.preview(view: 2, channel: -1, automatic: false).uiImage
                } else { maskImage = nil }
                if current.tool == .deconvolution {
                    let kernel = try await session.info(view: 4); kernelWidth = Int(kernel.width); kernelHeight = Int(kernel.height)
                    maskImage = try await session.preview(view: 4, channel: -1, automatic: false).uiImage
                }
                validPreview = recipe == current; view = current.tool == .deconvolution && current.number("estimateOnly") == 1 ? 4 : 1
            } catch { message = error.localizedDescription; resultImage = nil; maskImage = nil; view = 0 }
        }
    }
    @MainActor private func apply() {
        guard !busy, validPreview else { return }; busy = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
            do {
                await persistTask?.value
                let job = try await engine.prepareNativeToolJob(file: file, recipe: recipe, library: library)
                do {
                    let output = try await session.export(recipe, to: job)
                    _ = try await engine.preview(output, automatic: false)
                    try await engine.writeJobState(job.folder, state: "已完成", message: recipe.tool.title)
                    try? SirilEngine.processingLog().write(to: job.folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
                    onOutput(output); dismiss()
                } catch { try? await engine.writeJobState(job.folder, state: "输出验证失败", message: error.localizedDescription); throw error }
            } catch { message = error.localizedDescription }
        }
    }
}
