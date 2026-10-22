// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import SirilCore

enum SequenceStretch {
    static let tools: [NativeTool] = [.mtf, .ghs, .inverseGHS, .modifiedAsinh, .inverseModifiedAsinh, .linearStretch]
    static func command(_ recipe: NativeToolRecipe, file: FITSRecord, sequence: String) throws -> String {
        guard tools.contains(recipe.tool), recipe.mask.number("mode") == 0, recipe.previewRegion == nil else {
            throw EngineError.failed("此序列入口仅支持整帧拉伸，请关闭单张蒙版和预览选区。")
        }
        let script = try recipe.commands(file: file, topDown: false)
        guard let line = script.split(separator: "\n").last,
              let split = line.firstIndex(of: " ") else { throw EngineError.failed("原版拉伸命令无效。") }
        let name = String(line[..<split])
        guard ["mtf", "ght", "invght", "modasinh", "invmodasinh", "linstretch"].contains(name) else {
            throw EngineError.failed("当前参数没有对应的原版序列拉伸命令。")
        }
        return "set32bits\nseq" + name + " " + sequence + String(line[split...]) + " -prefix=$PREFIX"
    }
}
extension SirilEngine {
    func sequenceStretchFile(_ location: SequenceLocation) throws -> FITSRecord {
        let snapshot = try inspectSequence(location)
        guard let first = snapshot.frames.first(where: \.included), [1, 3].contains(Int(snapshot.info.layers)),
              first.native.width > 0, first.native.height > 0 else { throw EngineError.failed("请至少选择一张有效参与帧。") }
        return FITSRecord(url: try sequenceFolder(location).appendingPathComponent(location.name), width: Int(first.native.width),
            height: Int(first.native.height), channels: Int(snapshot.info.layers), exposure: 0)
    }
    func applySequenceStretch(_ location: SequenceLocation, recipe: NativeToolRecipe) throws -> SequenceLocation {
        let before = try inspectSequence(location), selected = before.frames.filter(\.included)
        guard location.base.utf8.count < 180 else { throw EngineError.failed("序列名称过长，请使用较短的来源序列名称。") }
        let command = try SequenceStretch.command(recipe, file: sequenceStretchFile(location), sequence: sequenceCommandName(location))
        let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
        let sourceURL = process.appendingPathComponent(location.name), sourceBytes = try Data(contentsOf: sourceURL)
        let runID = UUID(), prefix = "r_" + runID.uuidString.replacingOccurrences(of: "-", with: "") + "_"
        let folder = try owned(runID.uuidString, under: owned("SequenceRuns", under: root))
        let output = SequenceLocation(job: location.job, name: prefix + location.name)
        do {
            _ = try runSequenceCommand(location, command: command, title: "序列 · " + recipe.tool.title, producesSequence: true, runID: runID)
            try JSONEncoder().encode(recipe).write(to: folder.appendingPathComponent("stretch.json"), options: .atomic)
            siril_release_workspace()
            if try Data(contentsOf: sourceURL) != sourceBytes { try sourceBytes.write(to: sourceURL, options: .atomic) }
            let generated = try inspectSequence(output)
            guard generated.frames.count == selected.count, generated.info.layers == before.info.layers,
                  zip(generated.frames, selected).allSatisfy({ $0.0.native.width == $0.1.native.width && $0.0.native.height == $0.1.native.height }),
                  before.info.type != 0 || generated.frames.map({ $0.native.file_number }) == selected.map({ $0.native.file_number }) else {
                throw EngineError.failed("序列拉伸输出不完整，或帧编号、尺寸、通道不匹配。")
            }
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            for frame in generated.frames {
                guard let image = process.path.withCString({ directory in output.name.withCString {
                    siril_sequence_frame(directory, $0, Int32(frame.id), &error, capacity)
                } }) else { throw EngineError.failed(String(cString: error)) }
                siril_image_free(image)
            }
            let reference = selected.firstIndex(where: { $0.id == Int(before.info.reference) }) ?? -1
            try editSequence(output, selection: SequenceSelection(included: Array(repeating: true, count: selected.count), reference: reference))
            try writeJobState(folder, state: "已完成", message: "全部参与帧已拉伸并验证。")
            return output
        } catch {
            siril_release_workspace()
            if FileManager.default.fileExists(atPath: folder.path) {
                try? JSONEncoder().encode(recipe).write(to: folder.appendingPathComponent("stretch.json"), options: .atomic)
                try? writeJobState(folder, state: "拉伸失败或取消", message: error.localizedDescription)
                let manifest = folder.appendingPathComponent("output-sequence.json")
                if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
            }
            if try Data(contentsOf: sourceURL) != sourceBytes { try sourceBytes.write(to: sourceURL, options: .atomic) }
            for directory in [process, process.appendingPathComponent("cache"), process.appendingPathComponent("drizztmp")] {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let parent: URL
                if directory == process { parent = process }
                else { parent = try owned(directory.lastPathComponent, under: process) }
                for item in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey]) where item.lastPathComponent.hasPrefix(prefix) {
                    let file = try owned(item.lastPathComponent, under: parent)
                    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw EngineError.failed("拉伸输出清理遇到非普通文件。")
                    }
                    try FileManager.default.removeItem(at: file)
                }
            }
            throw error
        }
    }
}

struct SequenceStretchView: View {
    let location: SequenceLocation
    let engine: SirilEngine
    let onOutput: @MainActor (SequenceLocation) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: FITSRecord?
    @State private var recipe: NativeToolRecipe?
    @State private var tool = NativeTool.mtf
    @State private var busy = false
    @State private var message = ""
    @State private var output: SequenceLocation?
    @State private var includedCount = 0
    var body: some View {
        NavigationStack {
            Form {
                Section("原版序列拉伸") {
                    Text(location.name)
                    LabeledContent("参与帧", value: String(includedCount))
                    Picker("工具", selection: $tool) {
                        ForEach(SequenceStretch.tools, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(busy)
                    Text("仅处理参与帧，结果独立保存；沿用原版逐帧工作器，不覆盖输入。每帧独立拉伸，不作帧间亮度归一化。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let recipe {
                    Section("原版参数") {
                        ToolFieldControls(fields: recipe.tool.fields, values: Binding(get: { self.recipe?.values ?? [:] }, set: { self.recipe?.values = $0 }))
                    }.disabled(busy)
                }
                Section {
                    Button("应用到全部参与帧") { Task { await apply() } }.disabled(busy || recipe == nil)
                    if busy { ProgressView("原版序列工作器运行中"); Button("中止", role: .destructive) { siril_cancel_processing() } }
                    if let output { Text("已保存：" + output.name).textSelection(.enabled) }
                    if !message.isEmpty { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle("序列拉伸")
            .toolbar { Button("关闭") { dismiss() }.disabled(busy) }
            .task {
                do {
                    includedCount = Int(try await engine.inspectSequence(location).info.included)
                    let metadata = try await engine.sequenceStretchFile(location); file = metadata; recipe = NativeToolRecipe(tool: tool, file: metadata)
                    if ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_VIEW_CHECK"] == "1" && ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] == "stretch" {
                        recipe?.values["mid"] = 0.3
                        let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("simulator-sequence-stretch-ready.txt")
                        try "PASS: native sequence stretch loaded original six workers, frame selection and shared parameter controls.\n".write(to: marker, atomically: true, encoding: .utf8)
                    }
                }
                catch { message = error.localizedDescription }
            }
            .onChange(of: tool) { _, _ in if let file { recipe = NativeToolRecipe(tool: tool, file: file); output = nil; message = "" } }
            .onChange(of: recipe) { _, _ in output = nil }
        }
    }
    @MainActor private func apply() async {
        guard let recipe, !busy else { return }
        busy = true; output = nil; message = ""; UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let result = try await engine.applySequenceStretch(location, recipe: recipe)
            output = result; try await onOutput(result)
        } catch { message = error.localizedDescription }
    }
}
