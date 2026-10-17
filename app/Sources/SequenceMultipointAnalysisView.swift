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
    private var fixture: Bool { ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] == "multipoint-points" }
    private var point: SequenceMultipointPoint? { snapshot?.points.first { $0.id == selected } }
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
            .onChange(of: runID) { _, _ in Task { await refresh() } }
            .onChange(of: display) { _, _ in display.save(); Task { await refresh() } }
        }
    }
    private var imagePanel: some View {
        VStack {
            if let snapshot, let image = snapshot.preview.uiImage {
                ZoomableImageCanvas(image: image,
                    samples: snapshot.points.map { SampleMarker(id: $0.id, x: Double($0.x), y: Double($0.y), size: 8, median: []) },
                    imageWidth: Double(snapshot.width), imageHeight: Double(snapshot.height), selected: selected, region: point?.box,
                    onTap: { x, y in
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
    }
    @MainActor private func open() async {
        do {
            if !fixture { runs = try await engine.multipointRuns(location); runID = runs.first?.id }
            await refresh()
            if fixture, snapshot != nil {
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? await Task.sleep(for: .milliseconds(400))
                try "PASS: original saved multipoint reference, AP centres, selected bounds and analysis metadata loaded in native UI\n"
                    .write(to: root.appendingPathComponent("simulator-sequence-multipoint-points-ready.txt"), atomically: true, encoding: .utf8)
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        guard fixture || runID != nil else { return }
        let current = runID, settings = display; loading = true
        defer { loading = false }
        do {
            let value: SequenceMultipointAnalysisSnapshot
            if fixture { value = try await engine.multipointAnalysisFixture(display: settings) }
            else if let current { value = try await engine.multipointAnalysis(location, runID: current, display: settings) }
            else { return }
            if current == runID && settings == display { snapshot = value; selected = value.points.first?.id; message = "" }
        } catch { if current == runID { message = error.localizedDescription; snapshot = nil } }
    }
}
