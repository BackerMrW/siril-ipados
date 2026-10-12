// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct CurveEditor: View {
    @Binding var settings: CurveRecipe
    @Binding var pipetteEnabled: Bool
    let pipetteValue: Double?
    let histograms: [[UInt64]]
    let isRGB: Bool
    @State private var selected = 0
    @State private var panning = false
    private var channel: Binding<CurveChannel> {
        Binding(get: { settings.current.channels[settings.selectedChannel] },
                set: { settings.current.channels[settings.selectedChannel] = $0 })
    }
    var body: some View {
        Section("原版曲线") {
            Picker("编辑通道", selection: $settings.selectedChannel) {
                ForEach(0..<7, id: \.self) { Text(CurveRecipe.channels[$0]).tag($0).disabled($0 > 0 && !isRGB) }
            }.onChange(of: settings.selectedChannel) { _, _ in selected = 0 }
            Picker("插值", selection: $settings.current.algorithm) {
                Text("三次样条").tag(0); Text("线性").tag(1); Text("Akima 样条").tag(2)
            }
            Toggle("直方图对数显示", isOn: $settings.logarithmic)
            Stepper("曲线放大：\(settings.zoom.formatted())×", value: $settings.zoom, in: 1...100, step: 1)
            HStack {
                Toggle("平移曲线视图", isOn: $panning)
                Button("重置缩放") { settings.zoom = 1; panning = false }
            }
            CurveGraph(channel: channel, selected: $selected, algorithm: settings.current.algorithm,
                       logarithmic: settings.logarithmic, zoom: settings.zoom, panning: panning,
                       histograms: selectedHistograms, pipette: pipetteValue)
                .frame(height: 240)
            Toggle("点取原图像素定位曲线", isOn: $pipetteEnabled)
            if let pipetteValue { Text("当前阶段输入音调：\(pipetteValue.formatted(.number.precision(.fractionLength(5))))").font(.caption) }
            Text("点击空白添加控制点；拖动点调整；每次拖动合并成一次撤销。端点X固定，最多100点。").font(.caption).foregroundStyle(.secondary)
            let index = min(selected, channel.wrappedValue.points.count - 1)
            HStack {
                Text("点 \(index + 1)")
                Button("前一个") { selected = max(0, index - 1) }.disabled(index == 0)
                Button("后一个") { selected = min(channel.wrappedValue.points.count - 1, index + 1) }.disabled(index == channel.wrappedValue.points.count - 1)
                Button("删除点", role: .destructive) {
                    channel.wrappedValue.points.remove(at: index); selected = max(0, index - 1)
                }.disabled(index == 0 || index == channel.wrappedValue.points.count - 1)
            }
            if index > 0 && index < channel.wrappedValue.points.count - 1 {
                let lower = channel.wrappedValue.points[index - 1].x + 0.00001
                let upper = channel.wrappedValue.points[index + 1].x - 0.00001
                coordinate("输入 X", binding: Binding(get: { channel.wrappedValue.points[index].x }, set: { channel.wrappedValue.points[index].x = min(upper, max(lower, $0)) }))
            }
            coordinate("输出 Y", binding: Binding(get: { channel.wrappedValue.points[index].y }, set: { channel.wrappedValue.points[index].y = min(1, max(0, $0)) }))
            Toggle("此通道使用亮度范围蒙版", isOn: channel.rangeEnabled)
            if channel.wrappedValue.rangeEnabled {
                coordinate("最低亮度", binding: channel.low)
                coordinate("最高亮度", binding: channel.high)
                coordinate("范围羽化", binding: channel.feather)
                Text("计算预览后，在上方“蒙版”查看原版亮度范围权重；保存的是曲线处理结果。").font(.caption)
            }
            Button("重置当前通道") { channel.wrappedValue = CurveChannel(); selected = 0 }
        }
        Section("分阶段应用") {
            Text("已保留 \(settings.stages.count) 个阶段。计算从原图依次应用这些阶段，再应用当前全部通道曲线。").font(.caption)
            Button("保留当前阶段并开始下一阶段") {
                settings.stages.append(settings.current)
                let algorithm = settings.current.algorithm
                settings.current = CurveStage(); settings.current.algorithm = algorithm; selected = 0
            }.disabled(settings.stages.count >= 30)
            Button("撤回上一个阶段") {
                if let stage = settings.stages.popLast() { settings.current = stage; selected = 0 }
            }.disabled(settings.stages.isEmpty)
            Button("重置全部曲线") { settings = CurveRecipe(); selected = 0 }
        }
    }
    private var selectedHistograms: [[UInt64]] {
        guard histograms.count == 7 else { return [] }
        return settings.selectedChannel == 0 ? [histograms[1], histograms[2], histograms[3]] : [histograms[settings.selectedChannel]]
    }
    private func coordinate(_ title: String, binding: Binding<Double>) -> some View {
        HStack {
            Text(title)
            TextField(title, value: binding, format: .number.precision(.fractionLength(0...5)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            Stepper(title, value: binding, in: 0...1, step: 0.01).labelsHidden()
        }
    }
}

private struct CurveGraph: View {
    @Binding var channel: CurveChannel
    @Binding var selected: Int
    let algorithm: Int
    let logarithmic: Bool
    let zoom: Double
    let panning: Bool
    let histograms: [[UInt64]]
    let pipette: Double?
    @State private var draft: [CurveKnot]?
    @State private var samples: [Float] = []
    @State private var offset = CGSize.zero
    @State private var panStart: CGSize?
    private var plotted: CurveStage {
        var stage = CurveStage(); stage.algorithm = algorithm
        stage.channels[0] = channel
        if let draft { stage.channels[0].points = draft }
        return stage
    }
    private func display(_ x: Double) -> Double { (x - 0.5) * zoom + 0.5 }
    private func inverse(_ x: Double) -> Double { (x - 0.5) / zoom + 0.5 }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, _ in
                let frame = CGRect(origin: .zero, size: size)
                context.fill(Path(frame), with: .color(Color(white: 0.09)))
                for i in 0...4 {
                    let t = Double(i) / 4
                    var grid = Path(); grid.move(to: CGPoint(x: size.width * t, y: 0)); grid.addLine(to: CGPoint(x: size.width * t, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: size.height * t)); grid.addLine(to: CGPoint(x: size.width, y: size.height * t))
                    context.stroke(grid, with: .color(.gray.opacity(0.35)), lineWidth: 1)
                }
                let colors: [Color] = histograms.count == 3 ? [.red, .green, .blue] : [.white]
                let maximum = Double(histograms.flatMap { $0 }.max() ?? 1)
                for (index, histogram) in histograms.enumerated() {
                    var path = Path()
                    for (bin, count) in histogram.enumerated() {
                        let height = logarithmic ? log1p(Double(count)) / max(1, log1p(maximum)) : Double(count) / max(1, maximum)
                        let p = CGPoint(x: size.width * (display(Double(bin) / Double(max(1, histogram.count - 1))) + offset.width),
                                        y: size.height * (1 - display(height) - offset.height))
                        if bin == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    context.stroke(path, with: .color(colors[index].opacity(0.5)), lineWidth: 1)
                }
                var curve = Path()
                for (i, value) in samples.enumerated() {
                    let p = CGPoint(x: size.width * (display(Double(i) / Double(max(1, samples.count - 1))) + offset.width),
                                    y: size.height * (1 - display(min(1, max(0, Double(value)))) - offset.height))
                    if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                }
                context.stroke(curve, with: .color(.yellow), lineWidth: 2)
                for (i, point) in (draft ?? channel.points).enumerated() {
                    let p = CGPoint(x: size.width * (display(point.x) + offset.width), y: size.height * (1 - display(point.y) - offset.height))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                                 with: .color(i == selected ? .cyan : .white))
                }
                if let pipette {
                    let x = size.width * (display(pipette) + offset.width)
                    var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.cyan), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if panning {
                    if panStart == nil { panStart = offset }
                    offset = CGSize(width: panStart!.width + value.translation.width / size.width,
                                    height: panStart!.height - value.translation.height / size.height)
                    return
                }
                var points = draft ?? channel.points
                if draft == nil {
                    let distances = points.map { hypot(size.width * (display($0.x) + offset.width) - value.startLocation.x, size.height * (1 - display($0.y) - offset.height) - value.startLocation.y) }
                    if let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[nearest] <= 24 {
                        selected = nearest
                    } else if points.count < 100 {
                        let x = min(1, max(0, inverse(value.startLocation.x / size.width - offset.width)))
                        let y = min(1, max(0, inverse(1 - value.startLocation.y / size.height - offset.height)))
                        guard let after = points.firstIndex(where: { $0.x > x }), after > 0,
                              x - points[after - 1].x > 0.00002, points[after].x - x > 0.00002 else { return }
                        points.insert(CurveKnot(x: x, y: y), at: after); selected = after
                    } else { return }
                }
                guard points.indices.contains(selected) else { return }
                var x = min(1, max(0, inverse(value.location.x / size.width - offset.width)))
                if selected == 0 { x = 0 }
                else if selected == points.count - 1 { x = 1 }
                else { x = min(points[selected + 1].x - 0.00001, max(points[selected - 1].x + 0.00001, x)) }
                points[selected] = CurveKnot(x: x, y: min(1, max(0, inverse(1 - value.location.y / size.height - offset.height))))
                draft = points
            }.onEnded { _ in
                if let draft { channel.points = draft }; draft = nil
                panStart = nil
            })
            .accessibilityLabel("原版曲线控制点编辑图")
        }
        .onChange(of: zoom) { _, _ in offset = .zero; panStart = nil; draft = nil }
        .task(id: plotted) {
            let stage = plotted
            let values = await Task.detached {
                var recipe = CurveRecipe(); recipe.current = stage
                return recipe.plotted(channel: 0)
            }.value
            if !Task.isCancelled { samples = values }
        }
    }
}

private struct PMReference: Decodable, Identifiable {
    var name: String, prototype: String, help: String, group: String
    var id: String { group + name }
}
struct PixelMathEditor: View {
    @Binding var settings: PixelMathRecipe
    let library: [FITSRecord]
    let file: FITSRecord
    @State private var active = 0
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var reference = false
    @State private var search = ""
    @State private var presetName = ""
    private var references: [PMReference] {
        guard let url = Bundle.main.url(forResource: "PixelMathReference", withExtension: "json"),
              let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([PMReference].self, from: data) else { return [] }
        return entries
    }
    var body: some View {
        Section("原版像素数学") {
            Toggle("使用单一 RGB / 灰度表达式", isOn: $settings.singleRGB)
            ForEach(0..<(settings.singleRGB ? 1 : 3), id: \.self) { i in
                Text(settings.singleRGB ? "RGB / 灰度表达式 · $T 表示当前图像" : ["R 表达式", "G 表达式", "B 表达式"][i]).font(.caption)
                ExpressionEditor(text: $settings.expressions[i], selection: $selection, active: active == i,
                                 focused: { active = i }).frame(height: 100)
            }
            Button("函数、图像统计与运算符") { reference = true }
            Toggle("累计总积分时间与叠加帧数", isOn: $settings.doSum)
            Text("原版 EXPTIME 保留平均单帧曝光；打开累计选项时，LIVETIME 和 STACKCNT 累加所用图像。").font(.caption).foregroundStyle(.secondary)
            Toggle("重缩放输出", isOn: $settings.rescale)
            if settings.rescale {
                number("输出下限", value: $settings.low)
                number("输出上限", value: $settings.high)
            }
            Text("单表达式可处理RGB；三表达式按原版使用灰度图像变量合成RGB。语法错误或非有限像素不会保存结果。").font(.caption).foregroundStyle(.secondary)
        }
        Section("图像变量 · 最多10个") {
            ForEach($settings.bindings) { $binding in
                VStack(alignment: .leading) {
                    TextField("变量名", text: $binding.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("图像", selection: $binding.imageID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(library.filter { $0.width == file.width && $0.height == file.height && (settings.singleRGB || $0.channels == 1) }) {
                            Text($0.displayName).tag(Optional($0.id))
                        }
                    }
                    HStack {
                        Button("插入 \(binding.name)") { insert(binding.name) }
                        Button("删除变量", role: .destructive) { settings.bindings.removeAll { $0.id == binding.id } }
                    }
                }
            }
            Button("添加图像变量") {
                var index = 1
                while settings.bindings.contains(where: { $0.name == "I\(index)" }) { index += 1 }
                settings.bindings.append(PMBinding(name: "I\(index)", imageID: settings.singleRGB ? file.id : library.first(where: { $0.width == file.width && $0.height == file.height && $0.channels == 1 })?.id))
            }.disabled(settings.bindings.count >= 10)
        }
        Section("参数定义") {
            ForEach($settings.parameters) { $parameter in
                HStack {
                    TextField("参数名", text: $parameter.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("=")
                    TextField("值或表达式", text: $parameter.expression).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(role: .destructive) { settings.parameters.removeAll { $0.id == parameter.id } } label: { Image(systemName: "trash") }
                }
            }
            Button("添加参数") { settings.parameters.append(PMParameter(name: "p\(settings.parameters.count + 1)", expression: "0.5")) }.disabled(settings.parameters.count >= 64)
        }
        Section("此图像的表达式预设") {
            TextField("预设名称", text: $presetName)
            Button("保存当前表达式与参数") {
                settings.presets.append(PMPreset(name: presetName, expressions: settings.expressions, singleRGB: settings.singleRGB, parameters: settings.parameters)); presetName = ""
            }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty || settings.presets.count >= 100)
            ForEach(settings.presets) { preset in
                HStack {
                    Button(preset.name) {
                        settings.expressions = preset.expressions; settings.singleRGB = preset.singleRGB; settings.parameters = preset.parameters
                        active = 0; selection = NSRange(location: 0, length: 0)
                    }
                    Spacer()
                    Button(role: .destructive) { settings.presets.removeAll { $0.id == preset.id } } label: { Image(systemName: "trash") }
                }
            }
        }
        .sheet(isPresented: $reference) {
            NavigationStack {
                List(references.filter { search.isEmpty || ($0.name + $0.help).localizedCaseInsensitiveContains(search) }) { entry in
                    Button {
                        insert(entry.prototype); reference = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.prototype).font(.system(.body, design: .monospaced))
                            Text(entry.group + " · " + entry.help).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.searchable(text: $search).navigationTitle("原版 PixelMath 参考")
                    .toolbar { Button("完成") { reference = false } }
            }
        }
    }
    private func insert(_ text: String) {
        let i = settings.singleRGB ? 0 : min(2, active)
        let old = settings.expressions[i] as NSString
        let start = min(selection.location, old.length)
        let range = NSRange(location: start, length: min(selection.length, old.length - start))
        settings.expressions[i] = old.replacingCharacters(in: range, with: text)
        selection = NSRange(location: start + (text as NSString).length, length: 0)
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); TextField(title, value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
    }
}
private struct ExpressionEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var active: Bool
    let focused: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.autocorrectionType = .no; view.autocapitalizationType = .none
        view.smartQuotesType = .no; view.smartDashesType = .no
        view.backgroundColor = .secondarySystemGroupedBackground
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if active {
            let length = (text as NSString).length
            let start = min(selection.location, length)
            let desired = NSRange(location: start, length: min(selection.length, length - start))
            if view.selectedRange != desired { view.selectedRange = desired }
        }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ExpressionEditor
        init(_ parent: ExpressionEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ view: UITextView) { parent.focused(); parent.selection = view.selectedRange }
        func textViewDidChange(_ view: UITextView) { parent.text = view.text; parent.selection = view.selectedRange }
        func textViewDidChangeSelection(_ view: UITextView) { if view.isFirstResponder { parent.selection = view.selectedRange } }
    }
}
