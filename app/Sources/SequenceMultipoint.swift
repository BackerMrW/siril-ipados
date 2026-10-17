// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct SequenceMultipointSettings: Codable, Equatable, Sendable {
    var planet = true
    var halfBox = 24
    var search = 14
    var registerPercent = 100
    var stackPercent = 100
    var normalize = true
    var refine = true
    var dewarp = true
    var skipFailed = false
    var floatOutput = false
    var structure = 0.04
    var scale = 1.0
    var smoothRadius = 2.5
    var backgroundFraction = 0.3
    var backgroundBlend = 0.2
    var native: SirilMultipointOptions {
        var value = SirilMultipointOptions()
        value.alignment = planet ? 1 : 0; value.half_box = Int32(halfBox); value.search = Int32(search)
        value.register_percent = Int32(registerPercent); value.stack_percent = Int32(stackPercent)
        value.normalize = normalize ? 1 : 0
        value.refine = refine ? 1 : 0; value.dewarp = dewarp ? 1 : 0
        value.skip_failed = skipFailed ? 1 : 0; value.float_output = floatOutput ? 1 : 0
        value.structure = structure; value.scale = scale; value.smooth_radius = smoothRadius
        value.background_fraction = backgroundFraction; value.background_blend = backgroundBlend
        return value
    }
    func validate(width: Int, height: Int) throws {
        guard (8...128).contains(halfBox), halfBox * 2 <= min(width, height), (1...64).contains(search),
              (1...100).contains(registerPercent), (1...registerPercent).contains(stackPercent),
              structure.isFinite, (0...1).contains(structure), scale.isFinite, (1...3).contains(scale),
              smoothRadius.isFinite, (0...10).contains(smoothRadius),
              backgroundFraction.isFinite, (0...1).contains(backgroundFraction),
              backgroundBlend.isFinite, (0...1).contains(backgroundBlend) else {
            throw EngineError.failed("多点配准参数无效；对齐框必须位于图像内，叠加比例不得超过配准比例。")
        }
    }
}
struct SequenceMultipointSummary: Codable, Sendable {
    let frames: Int
    let included: Int
    let points: Int
    let failedShifts: Int
    let reference: Int
    let stackSize: Int
    init(_ value: SirilMultipointInfo) {
        frames = Int(value.frames); included = Int(value.included); points = Int(value.points)
        failedShifts = Int(value.failed_shifts); reference = Int(value.reference); stackSize = Int(value.stack_size)
    }
}
extension SirilEngine {
    func resumeMultipoint(_ location: SequenceLocation, runID: String) throws -> URL {
        let folder = try multipointFolder(location, runID: runID)
        let settings = try JSONDecoder().decode(SequenceMultipointSettings.self, from: Data(contentsOf: owned("multipoint.json", under: folder)))
        return try stackMultipoint(location, settings: settings, resuming: runID)
    }
    func stackMultipoint(_ location: SequenceLocation, settings: SequenceMultipointSettings, resuming runID: String? = nil) throws -> URL {
        let snapshot = try inspectSequence(location)
        guard snapshot.info.included >= 2, snapshot.info.drizzle == 0 else {
            throw EngineError.failed("多点配准需要至少两张参与帧，暂不接受 Drizzle 后的序列。")
        }
        try settings.validate(width: Int(snapshot.info.width), height: Int(snapshot.info.height))
        let process = try sequenceFolder(location), job = process.deletingLastPathComponent()
        let source = try owned(location.name, under: process), sourceBytes = try Data(contentsOf: source)
        let inputFolder = try runID.map { try multipointFolder(location, runID: $0) }
        let inputAnalysis = try inputFolder.map { try owned("analysis.mpp", under: $0) }
        let overrides = try inputFolder.flatMap { try multipointHistory($0)?.current }
        if let inputFolder {
            guard try Data(contentsOf: owned("source.seq", under: inputFolder)) == sourceBytes else {
                throw EngineError.failed("序列选择或参考帧已变化，请重新生成多点分析。")
            }
        }
        let nativePoints = try overrides?.map { try $0.nativePoint() }
        let folder = try owned(UUID().uuidString, under: try owned("SequenceRuns", under: job))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecar = try owned("analysis.mpp", under: folder), output = try owned("result.fits", under: folder)
        try sourceBytes.write(to: folder.appendingPathComponent("source.seq"), options: .atomic)
        try JSONEncoder().encode(location).write(to: folder.appendingPathComponent("source-location.json"), options: .atomic)
        try JSONEncoder().encode(settings).write(to: folder.appendingPathComponent("multipoint.json"), options: .atomic)
        if let runID { try JSONEncoder().encode(runID).write(to: folder.appendingPathComponent("parent-analysis.json"), options: .atomic) }
        try JSONEncoder().encode(JobState(created: Date(), updated: Date(), state: "运行中", inputCount: Int(snapshot.info.included), message: "原版多点配准与叠加"))
            .write(to: folder.appendingPathComponent("job.json"), options: .atomic)
        activeJobIDs.insert(location.job); defer { activeJobIDs.remove(location.job) }
        do {
            var error = [CChar](repeating: 0, count: 4096), options = settings.native, info = SirilMultipointInfo()
            let capacity = error.count
            let image = process.path.withCString { directory in location.name.withCString { name in sidecar.path.withCString {
                if let inputAnalysis {
                    let target = $0
                    return inputAnalysis.path.withCString { input in
                        if let nativePoints {
                            return nativePoints.withUnsafeBufferPointer {
                                siril_sequence_multipoint_resume(directory, name, input, $0.baseAddress, Int32($0.count), target, &info, &error, capacity)
                            }
                        }
                        return siril_sequence_multipoint_resume(directory, name, input, nil, -1, target, &info, &error, capacity)
                    }
                }
                return siril_sequence_multipoint_stack(directory, name, $0, &options, &info, &error, capacity)
            } } }
            try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            guard let image else { throw EngineError.failed(String(cString: error)) }
            defer { siril_image_free(image) }
            var resultInfo = SirilImageInfo()
            guard siril_image_info(image, &resultInfo) != 0, resultInfo.width > 0, resultInfo.height > 0,
                  info.points > 0, info.frames == snapshot.info.count, info.included == snapshot.info.included,
                  try Data(contentsOf: source) == sourceBytes,
                  output.path.withCString({ siril_image_write(image, $0) }) != 0 else {
                throw EngineError.failed("多点配准未生成可用的独立叠加结果，或输入序列发生变化。")
            }
            try JSONEncoder().encode(SequenceMultipointSummary(info)).write(to: folder.appendingPathComponent("multipoint-summary.json"), options: .atomic)
            try writeJobState(folder, state: "已完成", message: "原版多点配准：\(info.points) 个对齐点；\(info.failed_shifts) 次局部测量失败。")
            return output
        } catch {
            siril_release_workspace()
            for url in [output, sidecar] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            try sourceBytes.write(to: source, options: .atomic)
            try? writeJobState(folder, state: "多点配准失败或取消", message: error.localizedDescription)
            throw error
        }
    }
}
