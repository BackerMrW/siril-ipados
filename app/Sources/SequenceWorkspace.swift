// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts
import SirilCore

struct SequenceBrowserView: View {
    let engine: SirilEngine
    var job: String? = nil
    let onPreview: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var locations: [SequenceLocation] = []
    var body: some View {
        NavigationStack {
            List {
                if locations.isEmpty { ContentUnavailableView("还没有序列", systemImage: "square.stack", description: Text("可在处理页用勾选的亮场建立序列，或运行转换、校准和配准流程。")) }
                ForEach(locations) { location in
                    NavigationLink {
                        SequenceWorkspace(location: location, engine: engine, onPreview: onPreview)
                    } label: {
                        VStack(alignment: .leading) { Text(location.name); Text("任务 \(location.job.prefix(8))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("原版序列")
            .toolbar { Button("完成") { dismiss() } }
            .onAppear { Task { locations = await engine.sequenceLocations(job: job) } }
        }
    }
}

struct SequenceWorkspace: View {
    let location: SequenceLocation
    let engine: SirilEngine
    let onPreview: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: SequenceSnapshot?
    @State private var editHistory: SequenceEditHistory?
    @State private var index = 0
    @State private var layer = 0
    @State private var channel = -1
    @State private var displaySettings = NativeDisplaySettings.load()
    @State private var image: UIImage?
    @State private var previewTask: Task<Void, Never>?
    @State private var xMetric: SequenceMetric = .frame
    @State private var yMetric: SequenceMetric = .fwhm
    @State private var plotFrame: Double?
    @State private var from = 1
    @State private var to = 1
    @State private var busy = false
    @State private var message = ""
    @State private var options = BatchOptions.load()
    @State private var export: URL?
    @State private var result: URL?
    @State private var log = ""
    @State private var logTask: Task<Void, Never>?
    @State private var showStack = false
    @State private var showApply = false
    @State private var showBackground = false
    @State private var showStretch = false
    @State private var sequenceTool = NativeTool.mtf
    @State private var stretchSource: SequenceLocation?
    @State private var showPhotometry = false
    @State private var ccdSource: CCDImageSource?
    @State private var ccdTilt = true
    @State private var showComet = false
    @State private var showMultipoint = false
    @State private var showMultipointAnalysis = false
    @State private var multipointSettings = SequenceMultipointSettings()
    @State private var cometSource: SequenceLocation?
    @State private var backgroundRuns: [SequenceBackgroundRun] = []
    @State private var generated: SequenceLocation?
    @State private var flats: [FITSRecord] = []
    @State private var flatID: UUID?
    @State private var initializedLayer = false
    @State private var showDelete = false
    @State private var showOutputs = false
    @State private var selectingCrop = false
    @State private var cropRegion: ImageSelection?
    @State private var patternMethod: SequencePatternMethod = .dft
    @State private var patternMoved = 25.0
    @State private var selectingPattern = false
    @State private var patternRegion: ImageSelection?
    @State private var manualStarRegions: [ImageSelection] = []
    @State private var manualStarRotation = true
    @State private var manualStarFollow = false
    @State private var resultStatus: SequenceResultStatus?
    @State private var backgroundSource: SequenceLocation?
    private var currentLocation: SequenceLocation { resultStatus?.history.current ?? location }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section("处理结果撤销") {
                Text("当前：\(currentLocation.name)").font(.caption).textSelection(.enabled)
                HStack {
                    Button("撤销处理结果", systemImage: "arrow.uturn.backward") { perform {
                        let status = try await engine.replaySequenceResult(location, redo: false); await adopt(status)
                    } }.disabled(resultStatus?.canUndo != true)
                    Spacer()
                    Button("重做处理结果", systemImage: "arrow.uturn.forward") { perform {
                        let status = try await engine.replaySequenceResult(location, redo: true); await adopt(status)
                    } }.disabled(resultStatus?.canRedo != true)
                }.buttonStyle(.borderless)
                Button("回到入口序列") { perform { let status = try await engine.selectSequenceResult(entry: location, target: location); await adopt(status) } }
                    .disabled(currentLocation == location && resultStatus != nil)
                Text("切换整组图像，保留旧文件与权重。历史跨关闭保存，最多30步；新处理清除重做分支。帧勾选与参考帧的撤销位于下方。")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = resultStatus?.note, !note.isEmpty { Text(note).font(.caption) }
            }.id("sequence-results")
            if let snapshot {
                Section("PSF、测光与光学分析") {
                    Button("选星、序列 PSF 与光变") { showPhotometry = true }
                    Button("当前帧传感器倾斜") {
                        perform { ccdTilt = true; ccdSource = try await engine.ccdFrameSource(currentLocation, index: index) }
                    }
                    Button("参与帧平均倾斜") {
                        perform { ccdTilt = true; ccdSource = try await engine.ccdSequenceSource(currentLocation) }
                    }
                    Button("当前帧像差九宫格") {
                        perform { ccdTilt = false; ccdSource = try await engine.ccdFrameSource(currentLocation, index: index) }
                    }
                }

                Section("序列") {
                    Text(currentLocation.name).font(.headline)
                    LabeledContent("参与 / 总数", value: "\(snapshot.info.included) / \(snapshot.info.count)")
                    if snapshot.info.drizzle != 0 { Text("Drizzle 序列：叠加继续使用原版逐帧像素权重。") }
                    Picker("质量通道", selection: $layer) {
                        ForEach(0..<Int(snapshot.info.layers), id: \.self) { Text(snapshot.info.layers == 1 ? "单色" : ["红", "绿", "蓝"][$0]).tag($0) }
                    }
                }
                framePreview(snapshot)
                Section("序列裁剪") {
                    Toggle("拖动选择裁剪区域", isOn: $selectingCrop)
                    if let cropRegion { Text(cropRegion.description).textSelection(.enabled) }
                    HStack {
                        Button("当前帧全图") {
                            cropRegion = ImageSelection(x: 0, y: 0, width: Int(snapshot.frames[index].native.width), height: Int(snapshot.frames[index].native.height))
                        }
                        Button("清除选区") { cropRegion = nil; selectingCrop = false }
                    }.buttonStyle(.borderless)
                    Button("裁剪当前参与帧") {
                        guard let cropRegion else { return }
                        perform {
                            let source = currentLocation
                            let output = try await engine.cropSequence(source, region: cropRegion)
                            generated = output; log = SirilEngine.processingLog()
                            let status = try await engine.recordSequenceResult(entry: location, source: source, output: output)
                            await adopt(status)
                        }
                    }.disabled(cropRegion == nil)
                    Text("生成独立裁剪序列，保留输入帧与参考帧对应；Drizzle 权重同步裁剪，可通过处理结果历史撤销。")
                        .font(.caption).foregroundStyle(.secondary)
                }.id("sequence-crop")
                Section("参与帧和参考帧") {
                    Toggle("当前帧参与处理", isOn: Binding(get: { snapshot.frames[index].included }, set: { includeCurrent($0) }))
                    Picker("参考帧", selection: Binding(get: { Int(snapshot.info.reference) }, set: { reference in
                        var selection = snapshot.selection; selection.reference = reference
                        if reference >= 0 { selection.included[reference] = true }
                        change(selection)
                    })) {
                        Text("自动选择").tag(-1)
                        ForEach(snapshot.frames) { Text("第 \($0.id + 1) 帧").tag($0.id) }
                    }
                    HStack {
                        Button("撤销参与选择", systemImage: "arrow.uturn.backward") { perform { try await engine.editSequence(currentLocation, undo: true); await reload() } }.disabled(editHistory?.past.isEmpty != false)
                        Button("重做参与选择", systemImage: "arrow.uturn.forward") { perform { try await engine.editSequence(currentLocation, redo: true); await reload() } }.disabled(editHistory?.future.isEmpty != false)
                    }.buttonStyle(.borderless)
                    Text("排除只改变是否参与处理，原图仍保留。参考帧会自动设为参与；排除参考帧后改为自动选择。修改可以跨重启撤销、重做；新的修改会清除重做分支。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("序号"); TextField("从", value: $from, format: .number).keyboardType(.numberPad)
                        Text("至"); TextField("到", value: $to, format: .number).keyboardType(.numberPad)
                    }
                    HStack {
                        Button("包含范围") { includeRange(true) }; Button("排除范围") { includeRange(false) }
                        Button("全部包含") { includeRange(true, all: true) }
                    }.buttonStyle(.borderless)
                }
                qualityPlot(snapshot).id("sequence-quality")
                Section("图案与星点配准") {
                    BatchPicker(title: "方法", value: $patternMethod)
                    Toggle("在参考帧拖动选择图案或星点", isOn: $selectingPattern)
                    if let patternRegion { Text(patternRegion.description).textSelection(.enabled) }
                    Button("清除图案选区") { patternRegion = nil; selectingPattern = false }
                    Button("使用居中正方形选区") {
                        let side = max(8, min(Int(snapshot.info.width), Int(snapshot.info.height)) / 2)
                        patternRegion = ImageSelection(x: (Int(snapshot.info.width) - side) / 2,
                            y: (Int(snapshot.info.height) - side) / 2, width: side, height: side)
                        selectingPattern = true
                        index = snapshot.info.reference >= 0 ? Int(snapshot.info.reference) : snapshot.frames.first(where: \.included)?.id ?? 0
                    }.disabled(min(snapshot.info.width, snapshot.info.height) < 8)
                    if patternMethod == .kombat {
                        Stepper("最大移动：\(Int(patternMoved))%", value: $patternMoved, in: 5...100, step: 1)
                    }
                    if patternMethod == .manualStars {
                        Toggle("允许旋转", isOn: $manualStarRotation)
                        Toggle("逐帧跟随星点", isOn: $manualStarFollow)
                        Button("保存当前选区为星点 \(manualStarRegions.count + 1)") {
                            if let patternRegion { manualStarRegions.append(patternRegion) }
                        }.disabled(patternRegion == nil || manualStarRegions.count >= 3 ||
                            index != (snapshot.info.reference >= 0 ? Int(snapshot.info.reference) : snapshot.frames.first(where: \.included)?.id ?? 0))
                        ForEach(Array(manualStarRegions.enumerated()), id: \.offset) { item in
                            Text("星点 \(item.offset + 1)：\(item.element.description)").font(.caption)
                        }
                        Button("清除已保存星点") { manualStarRegions = [] }
                        Text("先切到参考帧，分别圈选两颗或三颗星并保存选区。选区必须不重叠；选区应覆盖各帧中的星点，或开启逐帧跟随。失败会恢复原序列元数据。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("测量参与帧配准") {
                        guard let patternRegion else { return }
                        perform {
                            try await engine.measurePatternRegistration(currentLocation,
                                recipe: SequencePatternRecipe(method: patternMethod, region: patternRegion, layer: layer, moved: patternMoved / 100,
                                    stars: manualStarRegions, rotation: manualStarRotation, follow: manualStarFollow))
                            options.transform = patternMethod == .manualStars && manualStarRotation ? .similarity : .shift
                            log = SirilEngine.processingLog(); await reload()
                        }
                    }.disabled(patternRegion == nil || snapshot.info.included < 2 ||
                        (patternMethod == .manualStars && (manualStarRegions.count < 2 || snapshot.info.drizzle != 0)))
                    Text("选区用于参考帧。DFT 需要正方形；KOMBAT 支持矩形。单星 PSF 需圈住同一颗星，跟随模式按上一张拟合位置移动选区并顺序处理。只测量矩阵与质量，原帧像素保留；完成后可在下方应用配准或叠加。")
                        .font(.caption).foregroundStyle(.secondary)
                }.id("sequence-pattern")
                Section("移动目标配准") {
                    Button("彗星／小行星：设置两次目标位置") { cometSource = currentLocation; showComet = true }
                        .disabled(snapshot.info.included < 2 || snapshot.info.drizzle != 0)
                    Text("按两帧位置与拍摄时间计算轨迹，可叠加已有星点配准；生成独立序列后应用矩阵或叠加。")
                        .font(.caption).foregroundStyle(.secondary)
                }.id("sequence-comet")
                Section("行星多点配准") {
                    Button("多点分析、局部对齐与叠加") { showMultipoint = true }
                        .disabled(snapshot.info.included < 2 || snapshot.info.drizzle != 0)
                    Button("打开保存的参考图与对齐点") { showMultipointAnalysis = true }
                    Text("适合行星整盘或表面纹理；沿用原版自动对齐点和专用叠加流程。")
                        .font(.caption).foregroundStyle(.secondary)
                }.id("sequence-multipoint")
                Section("原版测量与处理") {
                    BatchPicker(title: "配准变换", value: $options.transform)
                    Stepper("最少匹配星对：\(options.minimumPairs)", value: $options.minimumPairs, in: 4...2000)
                    Stepper("最多检测星点：\(options.maximumStars)", value: $options.maximumStars, in: 100...2000, step: 100)
                    Button("两遍星点配准：测量质量") { perform {
                        try await engine.measureSequence(currentLocation, options: options, layer: layer)
                        log = SirilEngine.processingLog(); await reload()
                    } }
                    Text("测量保存星点质量和变换矩阵。调整参与帧后，可在下方应用已有变换；新加入的未测量帧需重新测量。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("序列背景提取", systemImage: "square.3.layers.3d") { backgroundSource = currentLocation; showBackground = true }
                        .disabled(snapshot.info.included < 1)
                    Button("序列拉伸 · MTF / GHS / 修正 Asinh") { sequenceTool = .mtf; stretchSource = currentLocation; showStretch = true }
                        .disabled(snapshot.info.included < 1)
                    Button("序列滤镜 · 条纹消除 / 小波") { sequenceTool = .banding; stretchSource = currentLocation; showStretch = true }
                        .disabled(snapshot.info.included < 1)
                    Button("应用配准 / Drizzle 参数", systemImage: "arrow.triangle.branch") { showApply = true }
                        .disabled(snapshot.info.included < 2 || !snapshot.frames.filter(\.included).allSatisfy { $0.native.has_registration != 0 })
                    if let generated {
                        Button("切换到本次处理输出") { perform { let status = try await engine.selectSequenceResult(entry: location, target: generated); await adopt(status) } }
                        Text("已生成 \(generated.name)").font(.caption).textSelection(.enabled)
                    }
                    Button("计算原版序列统计") { perform { export = try await engine.sequenceStatistics(currentLocation); log = SirilEngine.processingLog(); await reload() } }
                    Button("导出质量数据 CSV") { perform { export = try await engine.exportSequenceQuality(currentLocation, layer: layer) } }
                    if let export { ShareLink("分享 CSV", item: export) }
                    Button("设置参数并按当前选择叠加", systemImage: "square.stack.3d.up") { showStack = true }
                    Text("重新叠加会保存新的结果和日志，保留之前的结果，并复用该任务的序列文件。原始、校准后和配准后的序列彼此独立；请确认当前选择的是要叠加的序列。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let result {
                        Button("查看本次叠加结果") { onPreview(result) }
                        ShareLink("导出本次 FITS", item: result)
                    }
                }.id("sequence-registration")
                if !backgroundRuns.isEmpty {
                    Section("背景处理记录") {
                        ForEach(backgroundRuns) { run in
                            DisclosureGroup("\(run.state.created.formatted(date: .abbreviated, time: .shortened)) · \(run.state.state)") {
                                Text("\(run.state.inputCount) 张参与帧 · \(run.state.message)").textSelection(.enabled)
                                if let output = run.output {
                                    Button("切换到这次校正序列") { perform { let status = try await engine.selectSequenceResult(entry: location, target: output); await adopt(status) } }
                                }
                                ShareLink("导出完整背景参数", item: run.folder.appendingPathComponent("background.json"))
                                ShareLink("导出这次处理日志", item: run.folder.appendingPathComponent("processing.log"))
                            }
                        }
                    }
                }
                Section("逐帧列表") {
                    ForEach(snapshot.frames) { frame in
                        Button { index = frame.id } label: {
                            HStack {
                                Image(systemName: frame.included ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(frame.included ? .blue : .gray)
                                VStack(alignment: .leading) {
                                    Text("第 \(frame.id + 1) 帧 · 原编号 \(frame.native.file_number)")
                                    Text("\(yMetric.title)：\(formatted(frame.value(yMetric)))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if frame.id == Int(snapshot.info.reference) { Image(systemName: "star.fill").foregroundStyle(.purple) }
                                if frame.id == index { Image(systemName: "eye").foregroundStyle(.blue) }
                            }
                        }.foregroundStyle(.primary)
                    }
                }
                Section("任务存储") {
                    NavigationLink("编辑参与帧 FITS 关键字") {
                        FITSKeywordEditorView(files: [], engine: engine, onOutput: onPreview, sequence: currentLocation)
                    }
                    NavigationLink("输出删除与恢复") { SequenceOutputManagementView(job: currentLocation.job, engine: engine, onPreview: onPreview) }
                    Button("删除本任务及全部序列", role: .destructive) { showDelete = true }
                    Text("移入最近删除后可以恢复。任务的输入副本、所有配准输出和 Drizzle 权重会一并移动；图库原图独立保留。永久删除后释放空间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !message.isEmpty {
                Section {
                    ContentUnavailableView("序列暂不可用", systemImage: "tray", description: Text("已删除的输出可在最近删除中恢复。"))
                    NavigationLink("输出删除与恢复") { SequenceOutputManagementView(job: currentLocation.job, engine: engine, onPreview: onPreview) }
                }
            } else { ProgressView("读取原版序列") }
            if busy { Section { ProgressView("Siril 正在处理") } }
            if !message.isEmpty { Section("提示") { Text(message).textSelection(.enabled) } }
            if !log.isEmpty { Section("本次日志") { Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
        }
        .disabled(busy)
        .navigationBarBackButtonHidden(busy)
        .interactiveDismissDisabled(busy)
        .toolbar { if busy { Button("中止", role: .destructive) { siril_cancel_processing() } } }
        .navigationTitle("序列工作区")
        .navigationDestination(isPresented: $showOutputs) { SequenceOutputManagementView(job: currentLocation.job, engine: engine, onPreview: onPreview) }
        .task {
            do { let status = try await engine.sequenceResultStatus(location); await adopt(status) }
            catch { message = error.localizedDescription; await reload() }
            to = snapshot?.frames.count ?? 1
            if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_VIEW_CHECK"] == "1", snapshot != nil {
                for _ in 0..<60 where image == nil { try? await Task.sleep(for: .milliseconds(50)) }
                guard image != nil else { return }
                let section = ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] ?? "frames"
                if ["stretch", "filters"].contains(section) { sequenceTool = section == "filters" ? .banding : .mtf; stretchSource = currentLocation; showStretch = true; return }
                if ["tilt", "tilt-average", "inspector"].contains(section) {
                    do {
                        ccdTilt = section != "inspector"
                        index = 1
                        if section == "tilt-average" {
                            try await engine.editSequence(currentLocation, selection: SequenceSelection(included: [true, true], reference: 1))
                            ccdSource = try await engine.ccdSequenceSource(currentLocation)
                        } else { ccdSource = try await engine.ccdFrameSource(currentLocation, index: index) }
                    } catch { message = error.localizedDescription }
                    return
                }
                if section == "comet" { cometSource = currentLocation; showComet = true; return }
                if section == "crop", let snapshot {
                    cropRegion = ImageSelection(x: Int(snapshot.info.width) / 4, y: Int(snapshot.info.height) / 4,
                        width: max(1, Int(snapshot.info.width) / 2), height: max(1, Int(snapshot.info.height) / 2))
                    selectingCrop = true
                    try? await Task.sleep(for: .milliseconds(400)); proxy.scrollTo("sequence-crop", anchor: .center)
                }
                if ["pattern", "pattern-kombat", "pattern-single-star", "pattern-manual-stars"].contains(section), let snapshot {
                    patternMethod = section == "pattern-kombat" ? .kombat : section == "pattern-single-star" ? .followStar : section == "pattern-manual-stars" ? .manualStars : .dft
                    let side = max(8, min(Int(snapshot.info.width), Int(snapshot.info.height)) / 2)
                    patternRegion = ImageSelection(x: (Int(snapshot.info.width) - side) / 2,
                        y: (Int(snapshot.info.height) - side) / 2, width: side, height: side)
                    selectingPattern = true
                    if section == "pattern-manual-stars" {
                        let box = max(8, min(Int(snapshot.info.width), Int(snapshot.info.height)) / 8)
                        manualStarRegions = [ImageSelection(x: box, y: box, width: box, height: box),
                            ImageSelection(x: box * 3, y: box, width: box, height: box),
                            ImageSelection(x: box * 2, y: box * 3, width: box, height: box)]
                    }
                    try? await Task.sleep(for: .milliseconds(400)); proxy.scrollTo("sequence-pattern", anchor: .center)
                }
                if section == "results" {
                    do {
                        let outputs = try await engine.sequenceOutputRecords(job: location.job)
                        var candidate: SequenceLocation?
                        for output in outputs where output.available {
                            let inspected = try await engine.inspectSequence(output.location)
                            if inspected.info.drizzle != 0 { candidate = output.location; break }
                        }
                        guard let drizzle = candidate else { throw EngineError.failed("Simulator Drizzle result missing") }
                        var settings = BackgroundSettings.sequenceDefaults
                        settings.perLine = 10; settings.tolerance = 3; settings.dither = false
                        let corrected = try await engine.applySequenceBackground(drizzle, settings: settings)
                        _ = try await engine.recordSequenceResult(entry: location, source: drizzle, output: corrected)
                        let status = try await engine.replaySequenceResult(location, redo: false)
                        await adopt(status)
                        for _ in 0..<60 where image == nil { try? await Task.sleep(for: .milliseconds(50)) }
                        guard image != nil, snapshot?.info.layers == 3, snapshot?.info.drizzle != 0, status.canUndo, status.canRedo else { throw EngineError.failed("Simulator result undo did not load actual RGB Drizzle pixels and both history directions") }
                    } catch { message = error.localizedDescription; return }
                }
                if section == "quality" || section == "registration" || section == "results" {
                    try? await Task.sleep(for: .milliseconds(400)); proxy.scrollTo("sequence-" + section, anchor: .top)
                } else if section == "outputs" {
                    showOutputs = true
                    return // The output manager checks live and recoverable files.
                } else if section == "photometry" {
                    showPhotometry = true
                    return
                } else if section == "background" {
                    backgroundSource = currentLocation; showBackground = true
                    return // The sheet writes readiness after its own real preview.
                } else if section == "apply" {
                    options.drizzleOptions.enabled = true; options.scale = 2; showApply = true
                } else if section == "multipoint" {
                    showMultipoint = true
                } else if ["multipoint-points", "multipoint-edit", "multipoint-shifts"].contains(section) {
                    showMultipointAnalysis = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let check = section == "results" ? "PASS: native sequence results workspace loaded actual RGB Drizzle pixels after background-result undo, with undo and redo available.\n" : "PASS: native sequence \(section) workspace loaded original frames, preview and quality.\n"
                try? check.write(to: root.appendingPathComponent("simulator-sequence-\(section)-ready.txt"), atomically: true, encoding: .utf8)
            }
        }
        .onChange(of: index) { _, _ in refreshPreview() }
        .onChange(of: patternMethod) { _, method in
            if method == .manualStars, let snapshot {
                index = snapshot.info.reference >= 0 ? Int(snapshot.info.reference) : snapshot.frames.first(where: \.included)?.id ?? 0
            }
        }
        .onChange(of: selectingCrop) { _, value in if value { selectingPattern = false; patternRegion = nil } }
        .onChange(of: selectingPattern) { _, value in if value { selectingCrop = false; cropRegion = nil } }
        .onChange(of: channel) { _, _ in refreshPreview() }
        .onChange(of: displaySettings) { _, _ in refreshPreview() }
        .onChange(of: layer) { _, _ in Task { await reload() } }
        .onAppear { if resultStatus != nil { perform { let status = try await engine.sequenceResultStatus(location); await adopt(status) } } }
        .onDisappear { previewTask?.cancel(); logTask?.cancel() }
        .alert("删除本任务？", isPresented: $showDelete) {
            Button("移入最近删除", role: .destructive) { perform {
                guard let task = await engine.jobHistory().first(where: { $0.id == currentLocation.job }) else { throw EngineError.failed("任务已不存在。") }
                try await engine.trashJob(task); dismiss()
            } }
            Button("取消", role: .cancel) { }
        } message: { Text("该任务中的所有序列和结果都将移入最近删除，可在存储管理中恢复。") }
        .fullScreenCover(isPresented: $showPhotometry) { SequencePhotometryView(location: currentLocation, engine: engine) }
        .fullScreenCover(isPresented: $showStretch, onDismiss: { perform { let status = try await engine.sequenceResultStatus(location); await adopt(status) } }) {
            SequenceStretchView(location: stretchSource ?? currentLocation, engine: engine, initialTool: sequenceTool) { output in
                generated = output
                _ = try await engine.recordSequenceResult(entry: location, source: stretchSource ?? currentLocation, output: output)
            }
        }
        .fullScreenCover(isPresented: $showBackground, onDismiss: { perform { let status = try await engine.sequenceResultStatus(location); await adopt(status) } }) {
            SequenceBackgroundView(location: backgroundSource ?? currentLocation, engine: engine) { output in
                generated = output
                do { _ = try await engine.recordSequenceResult(entry: location, source: backgroundSource ?? currentLocation, output: output) }
                catch { throw EngineError.failed("校正输出已保存，但结果历史保存失败：" + error.localizedDescription) }
            }
        }
        .fullScreenCover(isPresented: $showComet, onDismiss: { perform { let status = try await engine.sequenceResultStatus(location); await adopt(status) } }) {
            SequenceCometView(location: cometSource ?? currentLocation, engine: engine) { output in
                generated = output
                do { _ = try await engine.recordSequenceResult(entry: location, source: cometSource ?? currentLocation, output: output) }
                catch { throw EngineError.failed("新序列已保存，但结果历史保存失败：" + error.localizedDescription) }
            }
        }
        .fullScreenCover(isPresented: $showMultipointAnalysis) {
            SequenceMultipointAnalysisView(location: currentLocation, engine: engine)
        }
        .fullScreenCover(item: $ccdSource) { source in
            if ccdTilt { SensorTiltView(source: source) }
            else { AberrationInspectorView(source: source) }
        }
        .sheet(isPresented: $showApply) {
            SequenceApplyView(options: $options, flatID: $flatID, flats: flats) {
                showApply = false
                let flat = flats.first { $0.id == flatID }
                perform {
                    let source = currentLocation
                    let output = try await engine.applySequenceRegistration(source, options: options, layer: layer, flat: flat)
                    generated = output; log = SirilEngine.processingLog()
                    do { let status = try await engine.recordSequenceResult(entry: location, source: source, output: output); await adopt(status) }
                    catch { message = "配准输出已保存，但结果切换失败：" + error.localizedDescription; await reload() }
                }
            }
        }
        .sheet(isPresented: $showStack) {
            NavigationStack {
                Form {
                    StackControls(options: $options)
                    Section { Button("按当前参与帧叠加") {
                        showStack = false
                        perform { result = try await engine.stackSequence(currentLocation, options: options, layer: layer); log = SirilEngine.processingLog(); await reload() }
                    } }
                }.navigationTitle("序列叠加")
                .toolbar { Button("完成") { showStack = false } }
            }
        }
        .sheet(isPresented: $showMultipoint) {
            NavigationStack {
                Form {
                    SequenceMultipointControls(settings: $multipointSettings)
                    Section { Button("仅分析并编辑对齐点") {
                        showMultipoint = false
                        perform {
                            _ = try await engine.stackMultipoint(currentLocation, settings: multipointSettings, phase: 1)
                            log = SirilEngine.processingLog(); showMultipointAnalysis = true
                        }
                    } }
                    Section { Button("生成独立多点叠加结果") {
                        showMultipoint = false
                        perform {
                            result = try await engine.stackMultipoint(currentLocation, settings: multipointSettings)
                            log = SirilEngine.processingLog()
                        }
                    } }
                }.navigationTitle("原版多点配准")
                    .toolbar { Button("完成") { showMultipoint = false } }
            }
        }
        }
    }
    @ViewBuilder private func framePreview(_ snapshot: SequenceSnapshot) -> some View {
        Section("逐帧预览") {
            if let image {
                ZoomableImageCanvas(image: image, samples: [], imageWidth: Double(snapshot.frames[index].native.width), imageHeight: Double(snapshot.frames[index].native.height),
                    region: patternRegion ?? cropRegion, selecting: selectingCrop || selectingPattern,
                    onSelection: { if selectingPattern { patternRegion = $0 } else { cropRegion = $0 } }, onTap: nil)
                    .frame(height: 320).listRowInsets(EdgeInsets()).background(.black)
            } else { ProgressView("读取当前帧") }
            HStack {
                Button("上一帧", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0)
                Spacer(); Text("\(index + 1) / \(snapshot.frames.count)"); Spacer()
                Button("下一帧", systemImage: "chevron.right") { index += 1 }.disabled(index + 1 >= snapshot.frames.count)
            }.buttonStyle(.borderless)
            Picker("显示通道", selection: $channel) {
                Text("RGB / 灰度").tag(-1)
                if snapshot.info.layers == 3 { Text("红").tag(0); Text("绿").tag(1); Text("蓝").tag(2) }
            }
            NativeDisplayControls(settings: $displaySettings)
        }
    }
    @ViewBuilder private func qualityPlot(_ snapshot: SequenceSnapshot) -> some View {
        Section("质量图与当前帧数据") {
            BatchPicker(title: "横轴", value: $xMetric)
            BatchPicker(title: "纵轴", value: $yMetric)
            let points = snapshot.frames.filter { $0.value(xMetric) != nil && $0.value(yMetric) != nil }
            if points.isEmpty { Text("此通道尚未测得对应数据。可执行星点配准或序列统计；不会把缺失数据画成 0。") }
            else {
                Chart(points) { frame in
                    PointMark(x: .value(xMetric.title, frame.value(xMetric)!), y: .value(yMetric.title, frame.value(yMetric)!))
                        .foregroundStyle(frame.id == Int(snapshot.info.reference) ? Color.purple : frame.included ? .blue : .gray)
                        .symbolSize(frame.id == index ? 100 : 35)
                }.frame(height: 240)
                    .chartXSelection(value: $plotFrame)
                    .onChange(of: plotFrame) { _, value in
                        if xMetric == .frame, let value, value.isFinite {
                            let frame = Int(value.rounded())
                            if (1...snapshot.frames.count).contains(frame) { index = frame - 1 }
                        }
                    }
                Text("蓝色：参与；灰色：排除；紫色：参考帧。横轴为帧序号时可拖动图表查看对应帧。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let frame = snapshot.frames[index]
            ForEach(SequenceMetric.allCases.filter { $0 != .frame }) { metric in
                LabeledContent(metric.title, value: formatted(frame.value(metric)))
            }
        }
    }
    private func formatted(_ value: Double?) -> String { value.map { String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "未测得" }
    @MainActor private func adopt(_ status: SequenceResultStatus) async {
        if currentLocation != status.history.current {
            previewTask?.cancel(); image = nil; snapshot = nil
            index = 0; layer = 0; channel = -1; initializedLayer = false
            plotFrame = nil; from = 1; generated = nil; result = nil; export = nil
            cropRegion = nil; selectingCrop = false
            patternRegion = nil; selectingPattern = false
            manualStarRegions = []
        }
        resultStatus = status
        await reload(); to = snapshot?.frames.count ?? 1
    }
    @MainActor private func reload() async {
        do {
            snapshot = try await engine.inspectSequence(currentLocation, layer: layer)
            if !initializedLayer {
                initializedLayer = true
                if snapshot?.info.layers == 3 {
                    layer = 1; snapshot = try await engine.inspectSequence(currentLocation, layer: layer)
                }
            }
            if let snapshot {
                if let output = generated, !(await engine.sequenceLocations(job: currentLocation.job)).contains(output) { generated = nil }
                index = min(index, snapshot.frames.count - 1)
                backgroundRuns = try await engine.sequenceBackgroundRuns(currentLocation)
                editHistory = try await engine.sequenceHistory(currentLocation, snapshot: snapshot)
                options.register = snapshot.frames.contains { $0.native.has_registration != 0 }
                flats = await engine.loadLibrary().filter { $0.channels == 1 && $0.width == Int(snapshot.info.width) && $0.height == Int(snapshot.info.height) }
            }
            refreshPreview()
        } catch { snapshot = nil; image = nil; message = error.localizedDescription }
    }
    @MainActor private func refreshPreview() {
        previewTask?.cancel(); image = nil
        let current = index, display = channel, settings = displaySettings
        previewTask = Task {
            do {
                let bytes = try await engine.sequencePreview(currentLocation, index: current, channel: display, settings: settings)
                guard !Task.isCancelled else { return }
                image = bytes.uiImage
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    @MainActor private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = ""; previewTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = true
        logTask = Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)); log = SirilEngine.processingLog() } }
        Task {
            defer { busy = false; logTask?.cancel(); UIApplication.shared.isIdleTimerDisabled = false }
            do { try await action() } catch { message = error.localizedDescription }
        }
    }
    @MainActor private func change(_ selection: SequenceSelection) { perform { try await engine.editSequence(currentLocation, selection: selection); await reload() } }
    @MainActor private func includeCurrent(_ included: Bool) {
        guard var selection = snapshot?.selection else { return }
        selection.included[index] = included
        if !included && selection.reference == index { selection.reference = -1 }
        change(selection)
    }
    @MainActor private func includeRange(_ included: Bool, all: Bool = false) {
        guard var selection = snapshot?.selection else { return }
        let first = all ? 1 : from, last = all ? selection.included.count : to
        guard (1...selection.included.count).contains(first), last >= first, last <= selection.included.count else { message = "请输入有效的帧序号范围。"; return }
        for i in (first - 1)..<last { selection.included[i] = included }
        if selection.reference >= 0 && !selection.included[selection.reference] { selection.reference = -1 }
        change(selection)
    }
}

struct SequenceApplyView: View {
    @Binding var options: BatchOptions
    @Binding var flatID: UUID?
    let flats: [FITSRecord]
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("输出范围与采样") {
                    BatchPicker(title: "输出范围", value: $options.framing)
                    BatchNumber(title: "输出倍率（0.1–3）", value: $options.scale)
                    Toggle("Drizzle / Bayer Drizzle", isOn: $options.drizzleOptions.enabled)
                    if !options.drizzleOptions.enabled {
                        BatchPicker(title: "插值", value: $options.interpolation)
                        if options.interpolation.supportsClamp { Toggle("插值钳位", isOn: $options.clamp) }
                        Text("不插值只支持原版仅平移矩阵、倍率 1，以及参考帧范围或图像中心。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if options.drizzleOptions.enabled {
                    Section("Drizzle 参数") {
                        BatchPicker(title: "Drizzle 核", value: $options.drizzleOptions.kernel)
                        BatchNumber(title: "像素比例（0.1–10）", value: $options.drizzleOptions.pixelFraction)
                        Toggle("主平场用于初始像素权重", isOn: $options.drizzleOptions.useFlat)
                        if options.drizzleOptions.useFlat {
                            Picker("已校准的主平场", selection: $flatID) {
                                Text("使用本任务 master_flat.fits").tag(UUID?.none)
                                ForEach(flats) { Text($0.displayName).tag(Optional($0.id)) }
                            }
                            Text("请选择已扣除偏置或暗平场的主平场。此处只用于像素权重，不再次校准亮场。选中的主平场会随本次运行保存副本。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("权重位深匹配输出（32 位）", isOn: $options.drizzleOptions.matchWeightBitDepth)
                        Text("关闭时保存原版默认 8 位权重；开启后保存浮点权重。单色和 Bayer 原始图适用；RGB 与 X-Trans 输入不适用。2 倍输出约增加至 4 倍像素。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                QualityFilterControls(options: $options, title: "应用配准时的质量筛选")
                Section {
                    Button("应用当前参与帧的配准", action: apply)
                    Text("执行原版 seqapplyreg，生成独立命名的输出序列。当前排除帧不参与；原图和之前的输出继续保留。完成后打开输出序列再叠加。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("应用配准")
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}
