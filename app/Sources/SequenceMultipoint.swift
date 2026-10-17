// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct SequenceMultipointAdvanced: Codable, Equatable, Sendable {
    var globalSearch = 34
    var referencePercent = 5
    var brightness = 10
    var contrast = 0
    var gridStep = 0
    var referenceFrames = 0
    var debayer = 7 // Original BAYER_LMMSE.
    var aviBayer = 0
    var zeroMean = false
    var fastChanging = false
    var seed = true
    var stackFrames = -1
    var stackMethod = 0
    func validate() throws {
        guard (4...64).contains(globalSearch), (1...100).contains(referencePercent),
              (0...100).contains(brightness), (0...100).contains(contrast), (0...500).contains(gridStep),
              (0...500).contains(referenceFrames), (0...8).contains(debayer), (0...5).contains(aviBayer),
              (-1...10000).contains(stackFrames), (0...1).contains(stackMethod) else {
            throw EngineError.failed("多点高级参数超出原版界面的有效范围。")
        }
    }
}
struct SequenceMultipointSettings: Codable, Equatable, Sendable {
    // Optional for analysis recipes saved before advanced controls existed.
    var advanced: SequenceMultipointAdvanced?
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
        let a = advanced ?? SequenceMultipointAdvanced()
        value.global_search = Int32(a.globalSearch); value.reference_percent = Int32(a.referencePercent)
        value.brightness = Int32(a.brightness); value.contrast = Int32(a.contrast); value.grid_step = Int32(a.gridStep)
        value.reference_frames = Int32(a.referenceFrames); value.debayer = Int32(a.debayer); value.avi_bayer = Int32(a.aviBayer)
        value.zero_mean = a.zeroMean ? 1 : 0; value.fast_changing = a.fastChanging ? 1 : 0; value.seed = a.seed ? 1 : 0
        value.stack_frames = Int32(a.stackFrames); value.stack_method = Int32(a.stackMethod)
        value.refine = refine ? 1 : 0; value.dewarp = dewarp ? 1 : 0
        value.skip_failed = skipFailed ? 1 : 0; value.float_output = floatOutput ? 1 : 0
        value.structure = structure; value.scale = scale; value.smooth_radius = smoothRadius
        value.background_fraction = backgroundFraction; value.background_blend = backgroundBlend
        return value
    }
    func validate(width: Int, height: Int) throws {
        try (advanced ?? SequenceMultipointAdvanced()).validate()
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
    func resumeMultipoint(_ location: SequenceLocation, runID: String, phase: Int32 = 0) throws -> URL {
        let folder = try multipointFolder(location, runID: runID)
        let settings = try JSONDecoder().decode(SequenceMultipointSettings.self, from: Data(contentsOf: owned("multipoint.json", under: folder)))
        return try stackMultipoint(location, settings: settings, resuming: runID, phase: phase)
    }
    func stackMultipoint(_ location: SequenceLocation, settings: SequenceMultipointSettings, resuming runID: String? = nil, phase: Int32 = 0) throws -> URL {
        guard (0...3).contains(phase), phase != 1 || runID == nil, (phase != 2 && phase != 3) || runID != nil else {
            throw EngineError.failed("多点处理阶段无效。")
        }
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
        guard phase != 3 || nativePoints == nil else { throw EngineError.failed("编辑后的对齐点须先重新配准。") }
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
            var stageSucceeded = false
            let image = process.path.withCString { directory in location.name.withCString { name in sidecar.path.withCString { target -> OpaquePointer? in
                if phase == 1 || phase == 2 {
                    func stage(_ input: UnsafePointer<CChar>?) -> Bool {
                        if let nativePoints {
                            return nativePoints.withUnsafeBufferPointer {
                                siril_sequence_multipoint_stage(directory, name, input, $0.baseAddress, Int32($0.count), target, &options, phase, &info, &error, capacity) != 0
                            }
                        }
                        return siril_sequence_multipoint_stage(directory, name, input, nil, -1, target, &options, phase, &info, &error, capacity) != 0
                    }
                    if let inputAnalysis { stageSucceeded = inputAnalysis.path.withCString { stage($0) } }
                    else { stageSucceeded = stage(nil) }
                    return nil
                }
                if let inputAnalysis {
                    return inputAnalysis.path.withCString { input in
                        if phase == 3 { return siril_sequence_multipoint_stack_saved(directory, name, input, target, &info, &error, capacity) }
                        if let nativePoints {
                            return nativePoints.withUnsafeBufferPointer {
                                siril_sequence_multipoint_resume(directory, name, input, $0.baseAddress, Int32($0.count), target, &info, &error, capacity)
                            }
                        }
                        return siril_sequence_multipoint_resume(directory, name, input, nil, -1, target, &info, &error, capacity)
                    }
                }
                return siril_sequence_multipoint_stack(directory, name, target, &options, &info, &error, capacity)
            } } }
            try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            if phase == 1 || phase == 2 {
                guard stageSucceeded, info.frames == snapshot.info.count, info.included == snapshot.info.included,
                      try Data(contentsOf: source) == sourceBytes else { throw EngineError.failed(String(cString: error)) }
                try JSONEncoder().encode(SequenceMultipointSummary(info)).write(to: folder.appendingPathComponent("multipoint-summary.json"), options: .atomic)
                try writeJobState(folder, state: phase == 1 ? "已分析，待配准" : "已配准，待叠加", message: "\(info.points) 个对齐点；阶段独立保存。")
                return sidecar
            }
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
