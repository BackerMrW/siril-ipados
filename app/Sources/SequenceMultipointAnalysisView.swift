// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct SequenceMultipointAnalysisView: View {
    let location: SequenceLocation
    let engine: SirilEngine
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [SequenceMultipointRun] = []
    @State private var runID: String?
    @State private var snapshot: SequenceMultipointAnalysisSnapshot?
    @State private var selected: Int?
    @State private var display = NativeDisplaySettings.load()
    @State private var message = ""
    @State private var loading = false
    @State private var adding = false
    @State private var moving = false
    @State private var halfBox = 16
    @State private var diagnosticFrame = 0
    @State private var showShifts = false
    @State private var shiftScale = 1.0
    @State private var stackOptions = SequenceMultipointSettings()
    @State private var showStackOptions = false
    private var fixtureSection: String { ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] ?? "" }
    private var fixture: Bool { ["multipoint-points", "multipoint-edit", "multipoint-shifts"].contains(fixtureSection) }
    private var point: SequenceMultipointPoint? { snapshot?.points.first { $0.id == selected } }
    private var selectedShift: SequenceMultipointShift? { snapshot?.shifts.first { $0.id == selected } }
    private var displacementMarkers: [DisplacementMarker] {
        guard showShifts, let snapshot else { return [] }
        return snapshot.shifts.compactMap { shift in
            guard shift.included, snapshot.points.indices.contains(shift.id) else { return nil }
            let point = snapshot.points[shift.id]
            return DisplacementMarker(x: Double(point.x), y: Double(point.y), dx: shift.dx * shiftScale, dy: shift.dy * shiftScale, success: shift.success)
        }
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > 800 { HStack(spacing: 0) { imagePanel; controls.frame(width: 380) } }
                else { VStack(spacing: 0) { imagePanel.frame(height: geometry.size.height * 0.48); controls } }
            }
            .navigationTitle("多点参考图与对齐点").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { Button("关闭") { dismiss() } }
            .task { await open() }
            .onChange(of: runID) { _, _ in selected = nil; diagnosticFrame = 0; if !loading { Task { await refresh() } } }
            .onChange(of: diagnosticFrame) { _, _ in if !loading { Task { await refresh() } } }
            .onChange(of: display) { _, _ in display.save(); Task { await refresh() } }
            .sheet(isPresented: $showStackOptions) {
                NavigationStack {
                    Form {
                        SequenceMultipointStackControls(settings: $stackOptions)
                        Section("叠加高级参数") {
                            SequenceMultipointStackAdvancedControls(settings: Binding(
                                get: { stackOptions.advanced ?? SequenceMultipointAdvanced() }, set: { stackOptions.advanced = $0 }))
                        }
                        Section { Button("复用配准并生成新叠加结果") {
                            showStackOptions = false
                            Task { await restack(phase: 3, settings: stackOptions) }
                        } }
                    }.navigationTitle("多点叠加参数")
                        .toolbar { Button("取消") { showStackOptions = false } }
                }
            }
        }
    }
    private var imagePanel: some View {
        VStack {
            if let snapshot, let image = snapshot.preview.uiImage {
                ZoomableImageCanvas(image: image,
                    samples: snapshot.points.map { SampleMarker(id: $0.id, x: Double($0.x), y: Double($0.y), size: 8, median: []) },
                    imageWidth: Double(snapshot.width), imageHeight: Double(snapshot.height), selected: selected, region: point?.box,
                    displacements: displacementMarkers,
                    movingSamples: moving && !loading && !fixture,
                    onSampleMove: { index, x, y in Task { await edit(.move(index: index, x: Int(x.rounded()), y: Int(y.rounded()))) } },
                    onTap: { x, y in
                        if adding && !loading && !fixture {
                            Task { await edit(.add(x: Int(x.rounded()), y: Int(y.rounded()), halfBox: halfBox)) }; return
                        }
                        selected = snapshot.points.min { a, b in
                            pow(Double(a.x) - x, 2) + pow(Double(a.y) - y, 2) < pow(Double(b.x) - x, 2) + pow(Double(b.y) - y, 2)
                        }?.id
                    }).background(.black).clipped()
                Text("原版平均参考图 · \(snapshot.width) × \(snapshot.height) · 点击选择最近对齐点")
                    .font(.caption).padding(.horizontal)
                NativeDisplayControls(settings: $display).padding(.horizontal)
            } else if loading { ProgressView("读取保存的分析").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView("尚无参考图", systemImage: "scope", description: Text("先生成一次多点配准结果，再打开其分析记录。")) }
        }
    }
    private var controls: some View {
        ScrollViewReader { proxy in
        Form {
            if !message.isEmpty { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if !fixture {
                Section("保存的分析") {
                    Picker("运行记录", selection: $runID) {
                        ForEach(runs) { run in Text(run.created.formatted(date: .abbreviated, time: .shortened) + " · " + run.state).tag(Optional(run.id)) }
                    }.disabled(loading)
                }
            }
            if let snapshot {
                Section("原版分析") {
                    LabeledContent("参与 / 总帧数", value: "\(snapshot.included) / \(snapshot.frames)")
                    LabeledContent("参考帧", value: "\(snapshot.reference + 1)")
                    LabeledContent("对齐点", value: "\(snapshot.points.count)")
                    LabeledContent("局部配准", value: snapshot.registered ? "已保存" : "尚待计算")
                }
                if snapshot.registered && (!fixture || fixtureSection == "multipoint-shifts") {
                    Section("局部位移诊断") {
                        Toggle("在参考图上显示位移", isOn: $showShifts)
                        Stepper("帧：\(diagnosticFrame + 1) / \(snapshot.frames)", value: $diagnosticFrame, in: 0...max(0, snapshot.frames - 1))
                            .disabled(loading)
                        Slider(value: $shiftScale, in: 1...200, step: 1)
                        Text("箭头放大 \(Int(shiftScale)) 倍；绿：收敛，红：失败。方向按图像 X 向右、Y 向下。")
                            .font(.caption)
                        if let first = snapshot.shifts.first {
                            if first.included {
                                LabeledContent("收敛对齐点", value: "\(snapshot.shifts.filter { $0.success }.count) / \(snapshot.shifts.count)")
                                LabeledContent("全局位移", value: displacementText(first.globalDX, first.globalDY))
                            } else { Text("该帧未参与分析与配准，不显示位移箭头。") }
                        }
                        if let selectedShift, selectedShift.included {
                            LabeledContent("选中点局部位移", value: displacementText(selectedShift.dx, selectedShift.dy))
                            LabeledContent("选中点状态", value: selectedShift.success ? "收敛" : "失败")
                        }
                    }
                }
                if !fixture || fixtureSection == "multipoint-edit" {
                    Section("编辑对齐点") {
                        Text("首次编辑创建副本。原分析与原叠加结果保留；编辑后需重新计算局部配准。")
                            .font(.caption)
                        Toggle("点击添加对齐点", isOn: $adding)
                        Toggle("拖动移动对齐点", isOn: $moving)
                        Stepper("框半宽：\(halfBox) px", value: $halfBox, in: 8...128)
                        if let point {
                            Button("应用框大小到选中点") { Task { await edit(.resize(index: point.id, halfBox: halfBox)) } }
                            Button("删除选中点") { Task { await edit(.remove(index: point.id)) } }
                        }
                        HStack {
                            Button("撤销") { Task { await edit(.undo) } }
                            Button("重做") { Task { await edit(.redo) } }
                        }
                        Button("按原参数重新自动布点") { Task { await edit(.auto) } }
                        Button("清空对齐点") { Task { await edit(.clear) } }
                        Button("仅重新计算局部配准") { Task { await restack(phase: 2) } }
                            .disabled(snapshot.points.isEmpty)
                        Button("使用已保存配准叠加") { Task { await restack(phase: 3) } }
                            .disabled(!snapshot.registered)
                        Button("调整叠加参数后生成新结果") { Task { await openStackOptions() } }
                            .disabled(!snapshot.registered)
                        Button("重新配准并叠加为新结果") { Task { await restack() } }
                            .disabled(snapshot.points.isEmpty)
                    }.disabled(loading || fixture).id("editing")
                }
                if let point {
                    Section("对齐点 \(point.id + 1)") {
                        LabeledContent("中心", value: "X \(point.x)，Y \(point.y)")
                        Text("测量框：\(point.box.description)")
                        Text("合并区域：\(point.patch.description)")
                        LabeledContent("结构", value: point.structure.formatted(.number.precision(.fractionLength(4))))
                    }
                }
                Section("选择对齐点") {
                    ForEach(snapshot.points) { point in
                        Button("\(point.id + 1) · X \(point.x)，Y \(point.y)") { selected = point.id }
                    }
                }
            }
        }
        .onChange(of: snapshot?.points.count) { _, _ in
            if fixtureSection == "multipoint-edit" { proxy.scrollTo("editing", anchor: .top) }
        }
        }
    }
    @MainActor private func open() async {
        do {
            if fixtureSection == "multipoint-shifts" {
                showShifts = true; shiftScale = 20
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                diagnosticFrame = try JSONDecoder().decode(Int.self, from: Data(contentsOf: root.appendingPathComponent("native-multipoint-warp-frame.json")))
            }
            if !fixture { runs = try await engine.multipointRuns(location); runID = runs.first?.id }
            await refresh()
            if fixture, snapshot != nil {
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? await Task.sleep(for: .milliseconds(400))
                try "PASS: original saved multipoint reference, AP centres, selected bounds and analysis metadata loaded in native UI\n"
                    .write(to: root.appendingPathComponent("simulator-sequence-\(fixtureSection)-ready.txt"), atomically: true, encoding: .utf8)
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        guard fixture || runID != nil else { return }
        let current = runID, settings = display, frame = diagnosticFrame; loading = true
        defer { loading = false }
        do {
            let value: SequenceMultipointAnalysisSnapshot
            if fixture { value = try await engine.multipointAnalysisFixture(display: settings, frame: frame) }
            else if let current { value = try await engine.multipointAnalysis(location, runID: current, display: settings, frame: frame) }
            else { return }
            if current == runID && settings == display && frame == diagnosticFrame {
                snapshot = value
                if !value.points.contains(where: { $0.id == selected }) { selected = value.points.first?.id }
                message = ""
            }
        } catch { if current == runID { message = error.localizedDescription; snapshot = nil } }
    }
    private func displacementText(_ dx: Double, _ dy: Double) -> String {
        String(format: "X %.4f，Y %.4f px", locale: Locale(identifier: "en_US_POSIX"), dx, dy)
    }
    @MainActor private func edit(_ change: SequenceMultipointEdit) async {
        guard let runID, !loading else { return }
        loading = true
        do {
            let edited = try await engine.editMultipoint(location, runID: runID, edit: change)
            runs = try await engine.multipointRuns(location); self.runID = edited
            await refresh()
        } catch { message = error.localizedDescription }
        loading = false
    }
    @MainActor private func openStackOptions() async {
        guard let runID, !loading else { return }
        loading = true; defer { loading = false }
        do { stackOptions = try await engine.savedMultipointSettings(location, runID: runID); showStackOptions = true }
        catch { message = error.localizedDescription }
    }
    @MainActor private func restack(phase: Int32 = 0, settings: SequenceMultipointSettings? = nil) async {
        guard let runID, !loading else { return }
        loading = true
        do {
            let output = try await engine.resumeMultipoint(location, runID: runID, phase: phase, stackSettings: settings)
            runs = try await engine.multipointRuns(location); self.runID = output.deletingLastPathComponent().lastPathComponent
            await refresh()
        } catch { message = error.localizedDescription }
        loading = false
    }
}
