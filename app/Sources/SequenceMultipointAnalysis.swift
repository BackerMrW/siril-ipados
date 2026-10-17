// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct SequenceMultipointRun: Identifiable, Sendable {
    let id: String
    let created: Date
    let state: String
}
struct SequenceMultipointPoint: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let x: Int
    let y: Int
    let box: ImageSelection
    let patch: ImageSelection
    let structure: Double
    init(id: Int, native: SirilMultipointPoint) {
        self.id = id; x = Int(native.x); y = Int(native.y)
        box = ImageSelection(x: Int(native.box_x), y: Int(native.box_y), width: Int(native.box_width), height: Int(native.box_height))
        patch = ImageSelection(x: Int(native.patch_x), y: Int(native.patch_y), width: Int(native.patch_width), height: Int(native.patch_height))
        structure = native.structure
    }
    func nativePoint() throws -> SirilMultipointPoint {
        let values = [x, y, box.x, box.y, box.width, box.height, patch.x, patch.y, patch.width, patch.height]
        guard values.allSatisfy({ Int32(exactly: $0) != nil }), structure.isFinite else {
            throw EngineError.failed("对齐点记录超出有效范围。")
        }
        return SirilMultipointPoint(x: Int32(x), y: Int32(y), box_x: Int32(box.x), box_y: Int32(box.y),
            box_width: Int32(box.width), box_height: Int32(box.height), patch_x: Int32(patch.x), patch_y: Int32(patch.y),
            patch_width: Int32(patch.width), patch_height: Int32(patch.height), structure: structure)
    }
}
struct SequenceMultipointAnalysisSnapshot: Sendable {
    let width: Int
    let height: Int
    let frames: Int
    let included: Int
    let reference: Int
    let registered: Bool
    let points: [SequenceMultipointPoint]
    let preview: PreviewBytes
}
extension SirilEngine {
    func multipointRuns(_ location: SequenceLocation) throws -> [SequenceMultipointRun] {
        let folder = try owned("SequenceRuns", under: sequenceFolder(location).deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap { candidate in
            guard UUID(uuidString: candidate.lastPathComponent) != nil,
                  let run = try? owned(candidate.lastPathComponent, under: folder),
                  let source = try? JSONDecoder().decode(SequenceLocation.self, from: Data(contentsOf: owned("source-location.json", under: run))),
                  source == location,
                  let analysis = try? owned("analysis.mpp", under: run), FileManager.default.fileExists(atPath: analysis.path),
                  let state = try? JSONDecoder().decode(JobState.self, from: Data(contentsOf: owned("job.json", under: run))) else { return nil }
            return SequenceMultipointRun(id: run.lastPathComponent, created: state.created,
                state: state.state == "运行中" ? "处理被中断" : state.state)
        }.sorted { $0.created > $1.created }
    }
    func multipointAnalysis(_ location: SequenceLocation, runID: String, display: NativeDisplaySettings) throws -> SequenceMultipointAnalysisSnapshot {
        guard UUID(uuidString: runID) != nil else { throw EngineError.failed("多点分析编号无效。") }
        let runs = try owned("SequenceRuns", under: sequenceFolder(location).deletingLastPathComponent())
        let folder = try owned(runID, under: runs)
        let source = try JSONDecoder().decode(SequenceLocation.self, from: Data(contentsOf: owned("source-location.json", under: folder)))
        guard source == location else { throw EngineError.failed("该分析记录不属于当前序列。") }
        let history = try multipointHistory(folder)
        return try readMultipointAnalysis(owned("analysis.mpp", under: folder), points: history?.current, display: display)
    }
    func multipointAnalysisFixture(display: NativeDisplaySettings) throws -> SequenceMultipointAnalysisSnapshot {
        guard ["multipoint-points", "multipoint-edit"].contains(ProcessInfo.processInfo.environment["SIRIL_SEQUENCE_SECTION"] ?? "") else {
            throw EngineError.failed("当前未运行多点分析页面检查。")
        }
        return try readMultipointAnalysis(owned("native-multipoint-analysis.mpp", under: documents), display: display)
    }
    private func readMultipointAnalysis(_ path: URL, points override: [SequenceMultipointPoint]? = nil, display: NativeDisplaySettings) throws -> SequenceMultipointAnalysisSnapshot {
        var error = [CChar](repeating: 0, count: 1024); let capacity = error.count
        guard let analysis = path.path.withCString({ siril_multipoint_open($0, &error, capacity) }) else {
            throw EngineError.failed(String(cString: error))
        }
        defer { siril_multipoint_close(analysis) }
        if let override { try restoreMultipoint(analysis, points: override) }
        var info = SirilMultipointAnalysisInfo()
        guard siril_multipoint_info(analysis, &info) != 0, info.points >= 0 else { throw EngineError.failed("无法读取多点分析。") }
        var points: [SequenceMultipointPoint] = []
        for index in 0..<Int(info.points) {
            var point = SirilMultipointPoint()
            guard siril_multipoint_point(analysis, Int32(index), &point) != 0 else { throw EngineError.failed("无法读取对齐点。") }
            points.append(SequenceMultipointPoint(id: index, native: point))
        }
        guard let image = siril_multipoint_reference(analysis, &error, capacity) else { throw EngineError.failed(String(cString: error)) }
        defer { siril_image_free(image) }
        var preview = SirilPreview()
        let success = try display.withNative { siril_image_preview_mode(image, 1536, -1, &$0, &preview) }
        guard success != 0, let bytes = preview.rgba else { throw EngineError.failed("无法显示多点参考图。") }
        defer { siril_preview_free(&preview) }
        let rendered = PreviewBytes(data: Data(bytes: bytes, count: Int(preview.width) * Int(preview.height) * 4), width: Int(preview.width), height: Int(preview.height))
        return SequenceMultipointAnalysisSnapshot(width: Int(info.width), height: Int(info.height), frames: Int(info.frames),
            included: Int(info.included), reference: Int(info.reference), registered: info.registered != 0, points: points, preview: rendered)
    }
}
