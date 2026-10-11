// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SequenceResultHistory: Codable, Equatable, Sendable {
    let entry: SequenceLocation
    var current: SequenceLocation
    var past: [SequenceLocation] = []
    var future: [SequenceLocation] = []
}
struct SequenceResultStatus: Sendable {
    let history: SequenceResultHistory
    let canUndo: Bool
    let canRedo: Bool
    let note: String
}

extension SirilEngine {
    private func sequenceResultURL(_ entry: SequenceLocation) throws -> URL {
        let job = try sequenceFolder(entry).deletingLastPathComponent()
        let folder = try owned("SequenceResults", under: job)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try owned(entry.name + ".json", under: folder)
    }
    private func resultExists(_ location: SequenceLocation) throws -> Bool {
        FileManager.default.fileExists(atPath: try owned(location.name, under: sequenceFolder(location)).path)
    }
    private func resultAncestors(_ current: SequenceLocation, entry: SequenceLocation) throws -> SequenceResultHistory {
        let outputs = try sequenceOutputRecords(job: entry.job)
        var visited: Set<SequenceLocation> = [current], predecessors: [SequenceLocation] = []
        var node = current
        // Follow saved source metadata, not the display prefix or array order.
        while let parent = outputs.first(where: { $0.location == node })?.source {
            guard parent.job == entry.job, visited.insert(parent).inserted else {
                throw EngineError.failed("处理结果来源包含循环或跨任务引用，不能建立撤销历史。")
            }
            _ = try sequenceFolder(parent)
            predecessors.append(parent); node = parent
            if predecessors.count == 30 { break }
        }
        return SequenceResultHistory(entry: entry, current: current, past: Array(predecessors.reversed()))
    }
    private func loadSequenceResults(_ entry: SequenceLocation) throws -> SequenceResultHistory {
        let url = try sequenceResultURL(entry)
        guard FileManager.default.fileExists(atPath: url.path) else { return try resultAncestors(entry, entry: entry) }
        let history = try JSONDecoder().decode(SequenceResultHistory.self, from: Data(contentsOf: url))
        guard history.entry == entry, history.past.count <= 30, history.future.count <= 30 else {
            throw EngineError.failed("处理结果历史与入口不匹配或超过保存范围。")
        }
        for item in history.past + [history.current] + history.future {
            guard item.job == entry.job else { throw EngineError.failed("处理结果历史含跨任务引用。") }
            _ = try sequenceFolder(item)
        }
        return history
    }
    private func saveSequenceResults(_ history: SequenceResultHistory) throws {
        try JSONEncoder().encode(history).write(to: sequenceResultURL(history.entry), options: .atomic)
    }
    func sequenceResultStatus(_ entry: SequenceLocation) throws -> SequenceResultStatus {
        var history = try loadSequenceResults(entry)
        var note = ""
        // Keep missing steps in redo so restoring the output makes them usable
        // again. Do not delete FITS or silently prune the persistent branch.
        while try !resultExists(history.current), let previous = history.past.popLast() {
            history.future.append(history.current); history.future = Array(history.future.suffix(30))
            history.current = previous
            note = "上次当前输出已删除，已回到可用的前一步；恢复输出后可重做。"
        }
        if try !resultExists(history.current) { note = "当前序列及可撤销的前序都不可用，请先恢复所属任务或输出。" }
        if !note.isEmpty { try saveSequenceResults(history) }
        let canUndo = try history.past.last.map { try resultExists($0) } ?? false
        let canRedo = try history.future.last.map { try resultExists($0) } ?? false
        if note.isEmpty && ((!history.past.isEmpty && !canUndo) || (!history.future.isEmpty && !canRedo)) {
            note = "历史中的输出已删除；请先在输出管理中恢复，再撤销或重做。"
        }
        return SequenceResultStatus(history: history, canUndo: canUndo, canRedo: canRedo, note: note)
    }
    @discardableResult func recordSequenceResult(entry: SequenceLocation, source: SequenceLocation, output: SequenceLocation) throws -> SequenceResultStatus {
        guard source.job == entry.job, output.job == entry.job, source != output else { throw EngineError.failed("处理结果与来源不匹配。") }
        let outputs = try sequenceOutputRecords(job: entry.job)
        guard outputs.contains(where: { $0.location == output && $0.source == source && $0.available && $0.state.state == "已完成" }) else {
            throw EngineError.failed("此输出尚未完整验证，不能加入处理结果撤销历史。")
        }
        _ = try inspectSequence(source); _ = try inspectSequence(output)
        var history = try loadSequenceResults(entry)
        if history.current == output { return try sequenceResultStatus(entry) }
        if history.current != source { history = try resultAncestors(source, entry: entry) }
        history.past.append(source); history.past = Array(history.past.suffix(30))
        history.current = output; history.future = []
        try saveSequenceResults(history)
        return try sequenceResultStatus(entry)
    }
    @discardableResult func replaySequenceResult(_ entry: SequenceLocation, redo: Bool) throws -> SequenceResultStatus {
        var history = try sequenceResultStatus(entry).history
        let target = redo ? history.future.last : history.past.last
        guard let target, try resultExists(target) else {
            throw EngineError.failed("没有可用的\(redo ? "重做" : "撤销")结果；已删除的输出请先恢复。")
        }
        // Actual upstream reads must succeed before changing the durable cursor.
        _ = try inspectSequence(target)
        if redo {
            history.future.removeLast(); history.past.append(history.current)
            history.past = Array(history.past.suffix(30))
        } else {
            history.past.removeLast(); history.future.append(history.current)
            history.future = Array(history.future.suffix(30))
        }
        history.current = target
        try saveSequenceResults(history)
        return try sequenceResultStatus(entry)
    }
    @discardableResult func selectSequenceResult(entry: SequenceLocation, target: SequenceLocation) throws -> SequenceResultStatus {
        guard target.job == entry.job else { throw EngineError.failed("请选择同一任务的处理结果。") }
        _ = try inspectSequence(target)
        let history = try resultAncestors(target, entry: entry)
        try saveSequenceResults(history)
        return try sequenceResultStatus(entry)
    }
}
