// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct SequenceMultipointHistory: Codable, Sendable {
    var current: [SequenceMultipointPoint]
    var past: [[SequenceMultipointPoint]] = []
    var future: [[SequenceMultipointPoint]] = []
}
enum SequenceMultipointEdit: Sendable {
    case add(x: Int, y: Int, halfBox: Int), move(index: Int, x: Int, y: Int)
    case resize(index: Int, halfBox: Int), remove(index: Int), clear, auto, undo, redo
}
extension SirilEngine {
    func multipointFolder(_ location: SequenceLocation, runID: String) throws -> URL {
        guard UUID(uuidString: runID) != nil else { throw EngineError.failed("多点分析编号无效。") }
        let folder = try owned(runID, under: owned("SequenceRuns", under: sequenceFolder(location).deletingLastPathComponent()))
        let source = try JSONDecoder().decode(SequenceLocation.self, from: Data(contentsOf: owned("source-location.json", under: folder)))
        guard source == location else { throw EngineError.failed("该分析记录不属于当前序列。") }
        return folder
    }
    func multipointHistory(_ folder: URL) throws -> SequenceMultipointHistory? {
        let path = try owned("multipoint-edit.json", under: folder)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(SequenceMultipointHistory.self, from: Data(contentsOf: path))
        guard value.past.count <= 30, value.future.count <= 30 else { throw EngineError.failed("对齐点历史记录无效。") }
        return value
    }
    func restoreMultipoint(_ analysis: OpaquePointer, points: [SequenceMultipointPoint]) throws {
        var error = [CChar](repeating: 0, count: 1024); let capacity = error.count
        guard points.count <= 10_000_000 else { throw EngineError.failed("对齐点数量超出限制。") }
        let native = try points.map { try $0.nativePoint() }
        guard native.withUnsafeBufferPointer({ siril_multipoint_restore_points(analysis, $0.baseAddress, Int32($0.count), &error, capacity) }) != 0 else {
            throw EngineError.failed(String(cString: error))
        }
    }
    func editMultipoint(_ location: SequenceLocation, runID: String, edit: SequenceMultipointEdit) throws -> String {
        let original = try multipointFolder(location, runID: runID)
        var error = [CChar](repeating: 0, count: 1024); let capacity = error.count
        let path = try owned("analysis.mpp", under: original)
        guard let analysis = path.path.withCString({ siril_multipoint_open($0, &error, capacity) }) else {
            throw EngineError.failed(String(cString: error))
        }
        defer { siril_multipoint_close(analysis) }
        func readPoints() throws -> [SequenceMultipointPoint] {
            var info = SirilMultipointAnalysisInfo()
            guard siril_multipoint_info(analysis, &info) != 0 else { throw EngineError.failed("无法读取对齐点。") }
            return try (0..<Int(info.points)).map { index in
                var point = SirilMultipointPoint()
                guard siril_multipoint_point(analysis, Int32(index), &point) != 0 else { throw EngineError.failed("无法读取对齐点。") }
                return SequenceMultipointPoint(id: index, native: point)
            }
        }
        let saved = try multipointHistory(original)
        var history = try saved ?? SequenceMultipointHistory(current: readPoints())
        try restoreMultipoint(analysis, points: history.current)
        switch edit {
        case .undo:
            guard let previous = history.past.popLast() else { throw EngineError.failed("没有可撤销的对齐点编辑。") }
            history.future.append(history.current); history.current = previous
            try restoreMultipoint(analysis, points: history.current)
        case .redo:
            guard let next = history.future.popLast() else { throw EngineError.failed("没有可重做的对齐点编辑。") }
            history.past.append(history.current); history.current = next
            try restoreMultipoint(analysis, points: history.current)
        default:
            let action: Int32, index: Int, x: Int, y: Int, half: Int
            switch edit {
            case let .add(px, py, size): (action, index, x, y, half) = (0, 0, px, py, size)
            case let .move(i, px, py): (action, index, x, y, half) = (1, i, px, py, 0)
            case let .remove(i): (action, index, x, y, half) = (2, i, 0, 0, 0)
            case let .resize(i, size): (action, index, x, y, half) = (3, i, 0, 0, size)
            case .clear: (action, index, x, y, half) = (4, 0, 0, 0, 0)
            case .auto: (action, index, x, y, half) = (5, 0, 0, 0, 0)
            default: throw EngineError.failed("无效的对齐点编辑。")
            }
            guard [index, x, y, half].allSatisfy({ Int32(exactly: $0) != nil }),
                  siril_multipoint_edit(analysis, action, Int32(index), Int32(x), Int32(y), Int32(half), &error, capacity) != 0 else {
                throw EngineError.failed(String(cString: error))
            }
            let points = try readPoints()
            if points == history.current { return runID }
            history.past.append(history.current); history.past = Array(history.past.suffix(30))
            history.future = []; history.current = points
        }
        // Completed analyses are immutable. Fork once, then write only small
        // coordinate snapshots; the full mean image is never copied for undo.
        let folder: URL
        if saved != nil { folder = original }
        else {
            folder = try owned(UUID().uuidString, under: original.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                for name in ["analysis.mpp", "source.seq", "source-location.json", "multipoint.json"] {
                    try FileManager.default.copyItem(at: owned(name, under: original), to: owned(name, under: folder))
                }
                try JSONEncoder().encode(runID).write(to: owned("parent-analysis.json", under: folder), options: .atomic)
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
        try JSONEncoder().encode(history).write(to: owned("multipoint-edit.json", under: folder), options: .atomic)
        if saved == nil {
            try JSONEncoder().encode(JobState(created: Date(), updated: Date(), state: "待重新配准", inputCount: 0,
                message: "对齐点编辑副本；原分析和叠加结果保留。"))
                .write(to: owned("job.json", under: folder), options: .atomic)
        } else { try? writeJobState(folder, state: "待重新配准", message: "对齐点已编辑；局部配准需重新计算。") }
        return folder.lastPathComponent
    }
}
