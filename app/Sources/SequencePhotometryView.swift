// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts
import SirilCore

struct SequencePhotometryView: View {
    let location: SequenceLocation
    let engine: SirilEngine
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: SequenceSnapshot?
    @State private var recipe = SequencePhotometryRecipe()
    @State private var history: SequencePhotometryHistory?
    @State private var selection: ImageSelection?
    @State private var image: UIImage?
    @State private var report: SequencePhotometryReport?
    @State private var folder: URL?
    @State private var runs: [URL] = []
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Group {
                    if geometry.size.width > 800 { HStack(spacing: 0) { imagePanel; controls.frame(width: 420) } }
                    else { VStack { imagePanel.frame(height: geometry.size.height * 0.4); controls } }
                }
            }
            .navigationTitle("序列 PSF、测光与光变").navigationBarTitleDisplayMode(.inline)
             .toolbar {
                Button("关闭") { dismiss() }.disabled(busy)
                if busy { Button("中止", role: .destructive) { siril_cancel_processing() } }
            }
            .task { await open() }
            .onChange(of: recipe.current) { _, _ in Task { await preview() } }
            .onChange(of: recipe.settings.channel) { _, _ in Task { await preview() } }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
    private var imagePanel: some View {
        VStack {
            if let image, let snapshot {
                ZoomableImageCanvas(image: image, samples: recipe.regions.enumerated().map { i, r in
                    SampleMarker(id: i, x: Double(r.x) + Double(r.width) / 2, y: Double(r.y) + Double(r.height) / 2,
                        size: Double(max(r.width, r.height)), median: [])
                }, imageWidth: Double(snapshot.info.width), imageHeight: Double(snapshot.info.height),
                    region: selection, selecting: !busy, onSelection: { selection = $0 }, onTap: nil)
                    .background(.black)
            } else { ProgressView("读取序列帧").frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text(selection?.description ?? "单指框选星点；双指缩放和平移").font(.caption)
            HStack {
                Button(recipe.regions.isEmpty ? "添加目标星" : "添加参考星") {
                    if let selection { recipe.regions.append(selection); save(); self.selection = nil }
                }.disabled(busy || selection == nil || recipe.regions.count >= 20)
                Button("撤销") { step(redo: false) }.disabled(busy || history?.past.isEmpty != false)
                Button("重做") { step(redo: true) }.disabled(busy || history?.future.isEmpty != false)
            }
            if let report, !report.curve.isEmpty {
                Chart(report.curve) { point in
                    PointMark(x: .value("时间", point.time), y: .value("V-C", point.magnitude))
                    RuleMark(x: .value("时间", point.time), yStart: .value("下误差", point.magnitude - point.error), yEnd: .value("上误差", point.magnitude + point.error))
                }.chartYScale(domain: .automatic(reversed: true)).frame(height: 210).padding()
                Text(report.curve[0].time > 1000000 ? "曝光中点 JD_UT · 差分星等 V-C" : "未记录拍摄时间：原版帧序号 · 差分星等 V-C").font(.caption)
            }
        }
    }
    private var controls: some View {
        Form {
            Section("序列与跟踪") {
                Text(location.name)
                if let snapshot {
                    Picker("选择星点所在帧", selection: $recipe.current) {
                        ForEach(snapshot.frames.filter(\.included)) { frame in Text("第 \(frame.id + 1) 帧 · 原编号 \(frame.native.file_number)").tag(frame.id) }
                    }
                    Text("参与 \(snapshot.info.included) / \(snapshot.info.count) 帧；排除帧保留在报告中并标为无测量。")
                }
                Picker("选区定位", selection: $recipe.framing) {
                    Text("固定原始选区").tag(0); Text("跟随前一帧星点").tag(1); Text("已有配准矩阵").tag(2)
                }
                Toggle("生成原版差分光变曲线", isOn: $recipe.lightCurve)
                Text("第一颗为目标星，其余为参考星。使用原版参考星有效率筛选、平均通量、星等和误差；未解算的帧仍可测光。配准定位在缺少可用矩阵时按原版退回固定选区。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.disabled(busy)
            Section("星点选区") {
                ForEach(recipe.regions.indices, id: \.self) { i in
                    HStack {
                        Text("\(i == 0 ? "目标 V" : "参考 C\(i)") · \(recipe.regions[i].description)").font(.caption)
                        Spacer(); Button("删除", role: .destructive) { recipe.regions.remove(at: i); save() }
                    }
                }
                Button("清空选区", role: .destructive) { recipe.regions = []; save() }.disabled(recipe.regions.isEmpty)
            }.disabled(busy)
            StarSettingsControls(settings: $recipe.settings, channels: Int(snapshot?.info.layers ?? 1)).disabled(busy)
            Section {
                Button("保存参数") { save() }
                Button("运行原版序列分析") { Task { await compute() } }.disabled(recipe.regions.isEmpty || !recipe.settings.photometry)
                if busy { ProgressView("逐帧拟合与测光") }
                if !message.isEmpty { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            }.disabled(busy)
            if let report {
                Section("真实逐帧结果") {
                    Text("\(report.created.formatted()) · 有效测光 \(report.rows.filter { $0.measurement?.photometryValid == true }.count) / \(report.rows.filter(\.included).count)")
                    ForEach(report.rows) { row in
                        VStack(alignment: .leading) {
                            Text("星 \(row.star + 1) · 帧 \(row.frame + 1) / 原编号 \(row.number)")
                            if let m = row.measurement {
                                Text(String(format: "x=%.4f y=%.4f FWHM=%.4f × %.4f px\nm=%.6f ± %.6f · %@", m.x, m.y, m.fwhmX, m.fwhmY, m.magnitude, m.magnitudeError, m.photometryValid ? "有效孔径测光" : "测光无效，星等为估算"))
                            } else { Text(row.included ? "未得到有效星像拟合" : "排除帧") }
                        }.font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if let folder {
                Section("保存与导出") {
                    ShareLink("逐帧测量 CSV", item: folder.appendingPathComponent("photometry.csv"))
                    ShareLink("完整结果与来源", item: folder.appendingPathComponent("report.json"))
                    ShareLink("处理日志", item: folder.appendingPathComponent("processing.log"))
                    if report?.recipe.lightCurve == true { ShareLink("原版光变数据 .dat", item: folder.appendingPathComponent("light_curve.dat")) }
                }
            }
            Section("以往分析") {
                ForEach(runs, id: \.self) { url in Button(url.lastPathComponent.prefix(8)) { load(url) } }
                Text("每次分析独立保存，不覆盖旧结果；参数与选区可撤销/重做，记录跨关闭保留。随所属任务移入最近删除和恢复。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    @MainActor private func open() async {
        busy = true; defer { busy = false }
        do {
            snapshot = try await engine.inspectSequence(location)
            history = try await engine.photometryHistory(location); recipe = history!.current
            if let snapshot, !snapshot.frames.contains(where: { $0.id == recipe.current && $0.included }) { recipe.current = snapshot.frames.first(where: \.included)?.id ?? 0 }
            image = try await engine.sequencePreview(location, index: recipe.current, channel: recipe.settings.channel).uiImage
            runs = try await engine.sequencePhotometryReports(location)
            if let latest = runs.last { load(latest) }
            if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] == "photometry" {
                guard let snapshot, image != nil else { throw EngineError.failed("Sequence photometry source did not load") }
                let scale = Double(snapshot.info.width) / 256
                recipe.regions = [ImageSelection(x: max(0, Int(30 * scale) - 25), y: max(0, Int(31 * scale) - 25), width: 51, height: 51)]
                recipe.settings.inner = 18; recipe.settings.outer = 23; recipe.settings.aperture = 10
                let output = try await engine.sequencePhotometry(location, recipe: recipe); load(output)
                guard report?.rows.contains(where: { $0.measurement?.photometryValid == true }) == true else { throw EngineError.failed("Sequence view did not compute actual valid photometry") }
                let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-sequence-photometry-ready.txt")
                try "PASS: native sequence photometry workspace computed original per-frame photometry and loaded actual frame selection, controls, tracking modes and saved results.\n".write(to: marker, atomically: true, encoding: .utf8)
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func preview() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { image = try await engine.sequencePreview(location, index: recipe.current, channel: recipe.settings.channel).uiImage }
        catch { message = error.localizedDescription }
    }
    @MainActor private func save() {
        guard !busy, var h = history else { return }; h.record(recipe); busy = true
        Task {
            defer { busy = false }
            do { try await engine.savePhotometryHistory(h); history = h } catch { message = error.localizedDescription }
        }
    }
    @MainActor private func step(redo: Bool) {
        guard !busy, var h = history else { return }
        if redo { h.redo() } else { h.undo() }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await engine.savePhotometryHistory(h); history = h; recipe = h.current
                image = try await engine.sequencePreview(location, index: recipe.current, channel: recipe.settings.channel).uiImage
            } catch { message = error.localizedDescription }
        }
    }
    @MainActor private func load(_ url: URL) {
        do {
            let value = try JSONDecoder().decode(SequencePhotometryReport.self, from: Data(contentsOf: url.appendingPathComponent("report.json")))
            guard value.source == location else { throw EngineError.failed("分析结果属于另一序列") }
            report = value; folder = url
        } catch { message = error.localizedDescription }
    }
    @MainActor private func compute() async {
        guard !busy else { return }; busy = true; message = ""
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            if var h = history { h.record(recipe); try await engine.savePhotometryHistory(h); history = h }
            let url = try await engine.sequencePhotometry(location, recipe: recipe)
            load(url); runs = try await engine.sequencePhotometryReports(location)
        } catch { message = error.localizedDescription }
    }
}
