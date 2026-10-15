// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct CometAnchor: Codable, Equatable, Sendable {
    var frame: Int
    var x: Double, y: Double
}
struct SequenceCometRecipe: Codable, Equatable, Sendable {
    var layer = 0
    var first: CometAnchor?, second: CometAnchor?
    func validate(_ snapshot: SequenceSnapshot, complete: Bool) throws {
        guard (0..<Int(snapshot.info.layers)).contains(layer), !complete || (first != nil && second != nil) else { throw EngineError.failed("请在两张不同帧中设置目标位置。") }
        for anchor in [first, second].compactMap({ $0 }) {
            guard snapshot.frames.indices.contains(anchor.frame), anchor.x.isFinite, anchor.y.isFinite else { throw EngineError.failed("目标位置或帧序号无效。") }
            if complete, !(anchor.x >= 0 && anchor.y >= 0 && anchor.x < Double(snapshot.info.width) && anchor.y < Double(snapshot.info.height)) { throw EngineError.failed("目标位置超出序列范围。") }
        }
        if complete, first?.frame == second?.frame { throw EngineError.failed("两个目标位置必须来自不同帧。") }
    }
}
struct SequenceCometHistory: Codable, Sendable {
    let source: SequenceLocation
    var current = SequenceCometRecipe()
    var past: [SequenceCometRecipe] = [], future: [SequenceCometRecipe] = []
    mutating func record(_ value: SequenceCometRecipe) {
        guard value != current else { return }
        past.append(current); past = Array(past.suffix(30)); current = value; future = []
    }
    mutating func step(redo: Bool) {
        if redo, let next = future.popLast() { past.append(current); past = Array(past.suffix(30)); current = next }
        else if !redo, let previous = past.popLast() { future.append(current); future = Array(future.suffix(30)); current = previous }
    }
}

extension SirilEngine {
    private func discardCometOutput(folder: URL, process: URL) throws {
        guard UUID(uuidString: folder.lastPathComponent) != nil,
              folder.deletingLastPathComponent().path == process.deletingLastPathComponent().appendingPathComponent("SequenceRuns").path else { throw EngineError.failed("无效的彗星配准清理目录。") }
        let fm = FileManager.default, prefix = "r_" + folder.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
        for directory in [process, process.appendingPathComponent("cache"), process.appendingPathComponent("drizztmp")] {
            guard fm.fileExists(atPath: directory.path) else { continue }
            if directory.path != process.path { _ = try owned(directory.lastPathComponent, under: process) }
            for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where item.lastPathComponent.hasPrefix(prefix) {
                let type = try fm.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { throw EngineError.failed("彗星配准清理遇到非文件输出。") }
                try fm.removeItem(at: item)
            }
        }
        for item in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where item.pathExtension == "frame" && UUID(uuidString: item.deletingPathExtension().lastPathComponent) != nil {
            let file = try owned(item.lastPathComponent, under: folder)
            guard (try fm.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType == .typeRegular else { throw EngineError.failed("彗星配准临时文件无效。") }
            try fm.removeItem(at: file)
        }
    }
    func recoverCometRuns(job: String) throws {
        guard UUID(uuidString: job) != nil else { throw EngineError.failed("无效任务。") }
        guard !activeJobIDs.contains(job) else { return }
        let root = try owned(job, under: documents.appendingPathComponent("Jobs"))
        let runs = try owned("SequenceRuns", under: root), process = try owned("process", under: root)
        guard FileManager.default.fileExists(atPath: runs.path) else { return }
        for candidate in try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: candidate.lastPathComponent) != nil else { continue }
            guard let folder = try? owned(candidate.lastPathComponent, under: runs) else { continue }
            guard (try? JSONDecoder().decode(SequenceCometRecipe.self, from: Data(contentsOf: owned("comet.json", under: folder)))) != nil,
                  let state = try? JSONDecoder().decode(JobState.self, from: Data(contentsOf: owned("job.json", under: folder))), state.state == "运行中",
                  let source = try? JSONDecoder().decode(SequenceLocation.self, from: Data(contentsOf: owned("source-location.json", under: folder))), source.job == job,
                  let output = try? JSONDecoder().decode(SequenceLocation.self, from: Data(contentsOf: owned("output-sequence.json", under: folder))), output.job == job else { continue }
            let prefix = "r_" + folder.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
            guard output.name == prefix + source.name else { throw EngineError.failed("中断的彗星配准来源与输出不匹配。") }
            _ = try owned(source.name, under: process); _ = try owned(output.name, under: process)
            siril_release_workspace()
            try discardCometOutput(folder: folder, process: process)
            try writeJobState(folder, state: "彗星配准被中断", message: "未完成的输出已清理，输入序列保留。")
        }
    }
    private func cometHistoryURL(_ source: SequenceLocation) throws -> URL {
        let directory = try owned("SequenceEdits", under: sequenceFolder(source).deletingLastPathComponent())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try owned(source.name + ".comet.json", under: directory)
    }
    func cometHistory(_ source: SequenceLocation) throws -> SequenceCometHistory {
        let snapshot = try inspectSequence(source), url = try cometHistoryURL(source)
        guard FileManager.default.fileExists(atPath: url.path) else { return SequenceCometHistory(source: source) }
        let history = try JSONDecoder().decode(SequenceCometHistory.self, from: Data(contentsOf: url))
        guard history.source == source, history.past.count <= 30, history.future.count <= 30 else { throw EngineError.failed("彗星配准编辑历史无效。") }
        for recipe in history.past + [history.current] + history.future { try recipe.validate(snapshot, complete: false) }
        return history
    }
    func saveCometHistory(_ history: SequenceCometHistory) throws {
        let snapshot = try inspectSequence(history.source)
        guard history.past.count <= 30 && history.future.count <= 30 else { throw EngineError.failed("彗星配准历史过长。") }
        for recipe in history.past + [history.current] + history.future { try recipe.validate(snapshot, complete: false) }
        try JSONEncoder().encode(history).write(to: cometHistoryURL(history.source), options: .atomic)
    }

    func registerComet(_ source: SequenceLocation, recipe: SequenceCometRecipe) throws -> SequenceLocation {
        let before = try inspectSequence(source, layer: recipe.layer)
        try recipe.validate(before, complete: true)
        guard before.info.included >= 2, before.info.drizzle == 0, source.base.utf8.count < 180,
              let first = recipe.first, let second = recipe.second else { throw EngineError.failed("彗星配准需要至少两张参与帧；请在 Drizzle 前执行。") }
        let fm = FileManager.default, process = try sequenceFolder(source), root = process.deletingLastPathComponent()
        let sourceURL = try owned(source.name, under: process), sourceBytes = try Data(contentsOf: sourceURL)
        // Plan exact owned input/cache paths before the original worker creates
        // symlinks. Generated outputs are detached copies for gallery storage.
        let paths = try sequenceFilePaths(source).filter { $0 != "process/" + source.name }
        let inputFiles = try paths.map { try sequenceTrashPath($0, under: root) }
        let folder = try owned(UUID().uuidString, under: try owned("SequenceRuns", under: root))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = "r_" + folder.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
        let output = SequenceLocation(job: source.job, name: prefix + source.name)
        try JSONEncoder().encode(source).write(to: folder.appendingPathComponent("source-location.json"), options: .atomic)
        try JSONEncoder().encode(output).write(to: folder.appendingPathComponent("output-sequence.json"), options: .atomic)
        try JSONEncoder().encode(recipe).write(to: folder.appendingPathComponent("comet.json"), options: .atomic)
        try sourceBytes.write(to: folder.appendingPathComponent("source.seq"), options: .atomic)
        let state = JobState(created: Date(), updated: Date(), state: "运行中", inputCount: Int(before.info.included), message: "彗星／小行星配准")
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("job.json"), options: .atomic)
        do {
            var options = SirilCometOptions(layer: Int32(recipe.layer), first: Int32(first.frame), second: Int32(second.frame), x1: first.x, y1: first.y, x2: second.x, y2: second.y)
            var velocity = [Double](repeating: 0, count: 2), error = [CChar](repeating: 0, count: 4096); let capacity = error.count
            activeJobIDs.insert(source.job)
            let success = process.path.withCString { directory in source.name.withCString { name in prefix.withCString {
                siril_sequence_comet_register(directory, name, $0, &options, &velocity, &error, capacity)
            } } }
            activeJobIDs.remove(source.job)
            try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            guard success != 0 else { throw EngineError.failed(String(cString: error)) }
            guard try Data(contentsOf: sourceURL) == sourceBytes else { throw EngineError.failed("原版处理改写了输入序列，已停止发布输出。") }
            siril_release_workspace()
            for input in inputFiles {
                let target = input.deletingLastPathComponent().appendingPathComponent(prefix + input.lastPathComponent)
                let parent = target.deletingLastPathComponent()
                if parent.path != process.path { _ = try owned(parent.lastPathComponent, under: process) }
                let type = (try? fm.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType
                if type == .typeSymbolicLink {
                    guard target.resolvingSymlinksInPath() == input.resolvingSymlinksInPath() else { throw EngineError.failed("原版输出链接与输入不匹配。") }
                } else if let type, type != .typeRegular { throw EngineError.failed("彗星配准输出不是普通文件。") }
                let temporary = folder.appendingPathComponent(UUID().uuidString + ".frame")
                try fm.copyItem(at: input, to: temporary)
                if type != nil { try fm.removeItem(at: target) }
                try fm.moveItem(at: temporary, to: target)
            }
            let generated = try inspectSequence(output, layer: recipe.layer)
            let reference = before.info.reference >= 0 ? Int(before.info.reference) : before.frames.first(where: \.included)?.id ?? -1
            guard generated.info.count == before.info.count, generated.info.layers == before.info.layers,
                  Int(generated.info.reference) == reference, generated.selection.included == before.selection.included,
                  generated.frames.map({ $0.native.file_number }) == before.frames.map({ $0.native.file_number }),
                  generated.frames.filter(\.included).allSatisfy({ $0.native.has_registration != 0 }) else { throw EngineError.failed("彗星配准输出的参与帧、编号、参考帧或矩阵不符。") }
            for frame in generated.frames {
                guard let image = process.path.withCString({ directory in output.name.withCString { siril_sequence_frame(directory, $0, Int32(frame.id), &error, capacity) } }) else { throw EngineError.failed(String(cString: error)) }
                siril_image_free(image)
            }
            try JSONEncoder().encode(velocity).write(to: folder.appendingPathComponent("comet-velocity.json"), options: .atomic)
            try writeJobState(folder, state: "已完成", message: "彗星配准：X \(velocity[0])，Y \(velocity[1]) 像素/小时；输出矩阵与全部帧已验证。")
            return output
        } catch {
            activeJobIDs.remove(source.job); siril_release_workspace()
            if (try? Data(contentsOf: sourceURL)) != sourceBytes { try sourceBytes.write(to: sourceURL, options: .atomic) }
            try discardCometOutput(folder: folder, process: process)
            try? writeJobState(folder, state: "彗星配准失败或取消", message: error.localizedDescription)
            throw error
        }
    }
}
