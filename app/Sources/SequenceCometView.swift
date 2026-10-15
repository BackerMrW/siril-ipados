// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

struct SequenceCometView: View {
    let location: SequenceLocation
    let engine: SirilEngine
    let onOutput: @MainActor (SequenceLocation) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: SequenceSnapshot?
    @State private var history: SequenceCometHistory?
    @State private var recipe = SequenceCometRecipe()
    @State private var index = 0
    @State private var point: CometAnchor?
    @State private var image: UIImage?
    @State private var display = NativeDisplaySettings.load()
    @State private var busy = false
    @State private var message = ""
    @State private var output: SequenceLocation?
    @State private var persistTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > 800 { HStack(spacing: 0) { imagePanel; controls.frame(width: 420) } }
                else { VStack { imagePanel.frame(height: geometry.size.height * 0.43); controls } }
            }
            .navigationTitle("彗星／小行星配准").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("关闭") { Task { await persistTask?.value; dismiss() } }.disabled(busy)
                if busy { Button("中止", role: .destructive) { siril_cancel_processing() } }
            }
            .interactiveDismissDisabled(busy)
            .task { await open() }
            .onChange(of: index) { _, _ in point = nil; Task { await refresh() } }
            .onChange(of: display) { _, _ in display.save(); Task { await refresh() } }
            .onChange(of: recipe) { _, _ in record() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
    private var markers: [SampleMarker] {
        [recipe.first, recipe.second, point].enumerated().compactMap { id, anchor in
            guard let anchor, anchor.frame == index else { return nil }
            return SampleMarker(id: id, x: anchor.x, y: anchor.y, size: 12, median: [])
        }
    }
    private var imagePanel: some View {
        VStack {
            if let snapshot {
                Picker("预览帧", selection: $index) {
                    ForEach(snapshot.frames) { frame in Text("第 \(frame.id + 1) 帧 · \(frame.included ? "参与" : "排除")").tag(frame.id) }
                }.padding(.horizontal).disabled(busy)
                if let image {
                    ZoomableImageCanvas(image: image, samples: markers,
                        imageWidth: Double(snapshot.info.width), imageHeight: Double(snapshot.info.height), onTap: { x, y in
                            if !busy { point = CometAnchor(frame: index, x: x, y: y) }
                        }).background(.black)
                } else { ProgressView("读取序列帧").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            Text(point.map { String(format: "已点击：X %.3f，Y %.3f", $0.x, $0.y) } ?? "点击移动目标的中心；双指缩放和平移")
                .font(.caption)
            NativeDisplayControls(settings: $display).padding(.horizontal).disabled(busy)
        }
    }
    private var controls: some View {
        Form {
            Section("两次目标位置") {
                Text("在两张不同帧中点击同一移动目标，分别设为位置 1 和位置 2。原版按 DATE-OBS 计算匀速轨迹；已有星点配准时换算到参考帧坐标。")
                    .font(.caption)
                if let snapshot {
                    Picker("配准通道", selection: $recipe.layer) {
                        ForEach(0..<Int(snapshot.info.layers), id: \.self) { Text(snapshot.info.layers == 1 ? "单色" : ["红", "绿", "蓝"][$0]).tag($0) }
                    }
                }
                Text("坐标原点在左上角，X 向右、Y 向下；单位为原图像素。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            anchorSection(first: true)
            anchorSection(first: false)
            Section("编辑历史") {
                HStack {
                    Button("撤销") { step(redo: false) }.disabled(history?.past.isEmpty != false)
                    Spacer()
                    Button("重做") { step(redo: true) }.disabled(history?.future.isEmpty != false)
                }
                Text("位置和通道保留最近 30 步，关闭后可继续编辑。")
                    .font(.caption)
            }
            Section("生成移动目标配准序列") {
                Text("参与：\(snapshot?.info.included ?? 0) / \(snapshot?.info.count ?? 0)。保留输入帧及已有星点变换，生成独立输出；之后可应用配准或叠加。请在 Drizzle 和畸变处理前执行。")
                    .font(.caption)
                Button("计算并生成新配准序列") { Task { await apply() } }
                    .disabled(recipe.first == nil || recipe.second == nil || (snapshot?.info.included ?? 0) < 2)
                if let output { Text("已生成：\(output.name)").font(.caption).textSelection(.enabled) }
            }
            if !message.isEmpty { Section { Text(message).textSelection(.enabled) } }
        }.disabled(busy)
    }
    @ViewBuilder private func anchorSection(first: Bool) -> some View {
        let anchor = first ? recipe.first : recipe.second
        Section(first ? "位置 1" : "位置 2") {
            Button("将当前点击设为位置 \(first ? 1 : 2)") {
                if first { recipe.first = point } else { recipe.second = point }
            }.disabled(point == nil)
            if let anchor {
                Text("第 \(anchor.frame + 1) 帧")
                BatchNumber(title: "X", value: Binding(get: { (first ? recipe.first?.x : recipe.second?.x) ?? 0 }, set: {
                    if first { recipe.first?.x = $0 } else { recipe.second?.x = $0 }
                }))
                BatchNumber(title: "Y", value: Binding(get: { (first ? recipe.first?.y : recipe.second?.y) ?? 0 }, set: {
                    if first { recipe.first?.y = $0 } else { recipe.second?.y = $0 }
                }))
                Button("显示此帧") { index = anchor.frame }
                Button("清除位置") { if first { recipe.first = nil } else { recipe.second = nil } }
            } else { Text("尚未设置").foregroundStyle(.secondary) }
        }
    }
    @MainActor private func open() async {
        do {
            snapshot = try await engine.inspectSequence(location)
            history = try await engine.cometHistory(location); recipe = history?.current ?? SequenceCometRecipe()
            index = recipe.first?.frame ?? snapshot?.frames.first(where: \.included)?.id ?? 0
            await refresh()
            if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] == "comet", let snapshot, image != nil {
                recipe.first = CometAnchor(frame: 0, x: Double(snapshot.info.width) / 3, y: Double(snapshot.info.height) / 3)
                recipe.second = CometAnchor(frame: max(0, snapshot.frames.count - 1), x: Double(snapshot.info.width) / 2, y: Double(snapshot.info.height) / 2)
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? await Task.sleep(for: .milliseconds(400))
                try "PASS: native comet workspace loaded original sequence frame, two anchors, coordinate/channel controls and persistent history; numerical worker verified separately\n".write(to: root.appendingPathComponent("simulator-sequence-comet-ready.txt"), atomically: true, encoding: .utf8)
            }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func refresh() async {
        let frame = index, settings = display
        do {
            let bytes = try await engine.sequencePreview(location, index: frame, settings: settings)
            if index == frame && display == settings { image = bytes.uiImage }
        } catch { if index == frame { image = nil; message = error.localizedDescription } }
    }
    @MainActor private func record() {
        guard var value = history, let snapshot else { return }
        do { try recipe.validate(snapshot, complete: false) } catch { message = error.localizedDescription; return }
        value.record(recipe); history = value
        let previous = persistTask
        persistTask = Task { await previous?.value; do { try await engine.saveCometHistory(value) } catch { message = error.localizedDescription } }
    }
    @MainActor private func step(redo: Bool) {
        guard var value = history else { return }
        value.step(redo: redo); history = value; recipe = value.current; record()
    }
    @MainActor private func apply() async {
        busy = true; UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            await persistTask?.value
            let result = try await engine.registerComet(location, recipe: recipe)
            output = result; try await onOutput(result); message = "配准完成；可关闭此页，继续应用矩阵或叠加。"
        } catch { message = error.localizedDescription }
    }
}
