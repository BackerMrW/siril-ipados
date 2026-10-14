// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct SequenceLocation: Identifiable, Hashable, Codable, Sendable {
    let job: String
    let name: String
    var id: String { job + "/" + name }
    var base: String { String(name.dropLast(4)) }
}
struct SequenceSelection: Codable, Equatable, Sendable {
    var included: [Bool]
    var reference: Int
}
struct SequenceFrame: Identifiable, Sendable {
    let native: SirilSequenceFrame
    var id: Int { Int(native.index) }
    var included: Bool { native.included != 0 }
    func value(_ metric: SequenceMetric) -> Double? {
        let reg = native.has_registration != 0, stats = native.has_statistics != 0
        let value: Double?
        switch metric {
        case .frame: value = Double(id + 1)
        case .fwhm: value = reg && native.fwhm > 0 ? native.fwhm : nil
        case .wfwhm: value = reg && native.weighted_fwhm > 0 ? native.weighted_fwhm : nil
        case .round: value = reg && native.roundness > 0 ? native.roundness : nil
        case .background: value = reg ? native.background : nil
        case .stars: value = reg && native.stars > 0 ? Double(native.stars) : nil
        case .quality: value = reg && native.quality != 0 ? native.quality : nil
        case .xShift: value = reg ? native.translation_x : nil
        case .yShift: value = reg ? native.translation_y : nil
        case .mean: value = stats ? native.mean : nil
        case .median: value = stats ? native.median : nil
        case .sigma: value = stats ? native.sigma : nil
        }
        return value?.isFinite == true ? value : nil
    }
}
enum SequenceMetric: String, BatchChoice {
    case frame, fwhm, wfwhm, round, background, stars, quality, xShift, yShift, mean, median, sigma
    var title: String { switch self {
    case .frame: return "帧序号"; case .fwhm: return "FWHM（像素）"; case .wfwhm: return "加权 FWHM（像素）"
    case .round: return "圆度"; case .background: return "配准背景"; case .stars: return "星点数量"; case .quality: return "质量值"
    case .xShift: return "矩阵平移 X（像素）"; case .yShift: return "矩阵平移 Y（像素）"
    case .mean: return "均值（归一化）"; case .median: return "中位数（归一化）"; case .sigma: return "Sigma（归一化）"
    } }
}
struct SequenceSnapshot: Sendable {
    let info: SirilSequenceInfo
    let frames: [SequenceFrame]
    var selection: SequenceSelection { SequenceSelection(included: frames.map(\.included), reference: Int(info.reference)) }
}
struct SequenceEditHistory: Codable, Sendable {
    var numbers: [Int]
    var current: SequenceSelection
    var past: [SequenceSelection] = []
    var future: [SequenceSelection] = []
}
struct SequenceEditJournal: Codable, Sendable {
    let sequence: Data
    let history: Data?
    var committed = false
}

extension SirilEngine {
    func sequenceFolder(_ location: SequenceLocation) throws -> URL {
        guard UUID(uuidString: location.job) != nil, location.name.hasSuffix(".seq"), !activeJobIDs.contains(location.job) else {
            throw EngineError.failed("任务正在运行或序列路径无效，请处理完成后再打开。")
        }
        let job = try owned(location.job, under: documents.appendingPathComponent("Jobs"))
        guard (try? job.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw EngineError.failed("任务已删除或不存在，请先恢复所属任务。")
        }
        let process = try owned("process", under: job)
        _ = try owned(location.name, under: process)
        return process
    }
    func sequenceLocations(job: String? = nil) -> [SequenceLocation] {
        jobHistory().filter { job == nil || $0.id == job }.flatMap { task in
            guard let folder = try? owned(task.id, under: documents.appendingPathComponent("Jobs")),
                  let process = try? owned("process", under: folder) else { return [SequenceLocation]() }
            return ((try? FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "seq" && (try? owned($0.lastPathComponent, under: process)) != nil }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { SequenceLocation(job: task.id, name: $0.lastPathComponent) }
        }
    }
    private func sequenceEditURLs(_ location: SequenceLocation) throws -> (sequence: URL, history: URL, journal: URL) {
        let process = try sequenceFolder(location)
        let edits = try owned("SequenceEdits", under: process.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        return (try owned(location.name, under: process), try owned(location.name + ".json", under: edits), try owned(location.name + ".journal.json", under: edits))
    }
    func recoverSequenceEdit(_ location: SequenceLocation) throws {
        let urls = try sequenceEditURLs(location)
        guard FileManager.default.fileExists(atPath: urls.journal.path) else { return }
        let journal = try JSONDecoder().decode(SequenceEditJournal.self, from: Data(contentsOf: urls.journal))
        siril_release_workspace()
        if !journal.committed {
            try journal.sequence.write(to: urls.sequence, options: .atomic)
            if let history = journal.history { try history.write(to: urls.history, options: .atomic) }
            else if FileManager.default.fileExists(atPath: urls.history.path) { try FileManager.default.removeItem(at: urls.history) }
        }
        try FileManager.default.removeItem(at: urls.journal)
    }
    func inspectSequence(_ location: SequenceLocation, layer: Int = 0) throws -> SequenceSnapshot {
        try recoverSequenceEdit(location)
        let folder = try sequenceFolder(location)
        var error = [CChar](repeating: 0, count: 512), info = SirilSequenceInfo()
        let capacity = error.count
        let count = folder.path.withCString { directory in location.name.withCString { siril_sequence_inspect(directory, $0, Int32(layer), &info, nil, 0, &error, capacity) } }
        guard count > 0 else { throw EngineError.failed(String(cString: error)) }
        var frames = [SirilSequenceFrame](repeating: SirilSequenceFrame(), count: Int(count))
        let result = folder.path.withCString { directory in location.name.withCString { siril_sequence_inspect(directory, $0, Int32(layer), &info, &frames, Int(count), &error, capacity) } }
        guard result == count else { throw EngineError.failed(String(cString: error)) }
        return SequenceSnapshot(info: info, frames: frames.map { SequenceFrame(native: $0) })
    }
    func sequenceHistory(_ location: SequenceLocation, snapshot: SequenceSnapshot) throws -> SequenceEditHistory {
        let url = try sequenceEditURLs(location).history
        let numbers = snapshot.frames.map { Int($0.native.file_number) }
        if let saved = try? JSONDecoder().decode(SequenceEditHistory.self, from: Data(contentsOf: url)),
           saved.numbers == numbers, saved.current == snapshot.selection { return saved }
        return SequenceEditHistory(numbers: numbers, current: snapshot.selection)
    }
    // Transaction journal survives a crash between upstream's .seq write and
    // the undo history update. Undo changes flags only, retaining newer stats.
    func editSequence(_ location: SequenceLocation, selection: SequenceSelection? = nil, undo: Bool = false, redo: Bool = false) throws {
        let snapshot = try inspectSequence(location)
        var history = try sequenceHistory(location, snapshot: snapshot)
        let target: SequenceSelection
        if undo, let value = history.past.popLast() { history.future.append(history.current); target = value }
        else if redo, let value = history.future.popLast() { history.past.append(history.current); target = value }
        else if let value = selection, value != history.current {
            history.past.append(history.current); history.past = Array(history.past.suffix(30)); history.future = []; target = value
        } else { return }
        guard target.included.count == snapshot.frames.count, target.reference >= -1, target.reference < target.included.count,
              target.reference < 0 || target.included[target.reference] else { throw EngineError.failed("参考帧必须参与序列；请检查帧选择范围。") }
        let urls = try sequenceEditURLs(location)
        var journal = SequenceEditJournal(sequence: try Data(contentsOf: urls.sequence), history: try? Data(contentsOf: urls.history))
        try JSONEncoder().encode(journal).write(to: urls.journal, options: .atomic)
        do {
            var flags = target.included.map { UInt8($0 ? 1 : 0) }, error = [CChar](repeating: 0, count: 512)
            let capacity = error.count, count = flags.count
            let success = urls.sequence.deletingLastPathComponent().path.withCString { directory in
                location.name.withCString { siril_sequence_select(directory, $0, &flags, count, Int32(target.reference), &error, capacity) }
            }
            guard success != 0 else { throw EngineError.failed(String(cString: error)) }
            history.current = target
            try JSONEncoder().encode(history).write(to: urls.history, options: .atomic)
            journal.committed = true
            try JSONEncoder().encode(journal).write(to: urls.journal, options: .atomic)
            try FileManager.default.removeItem(at: urls.journal)
        } catch { try recoverSequenceEdit(location); throw error }
    }
    func sequencePreview(_ location: SequenceLocation, index: Int, channel: Int = -1, automatic: Bool = true, settings: NativeDisplaySettings? = nil) throws -> PreviewBytes {
        _ = try inspectSequence(location)
        let folder = try sequenceFolder(location)
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        guard let image = folder.path.withCString({ directory in location.name.withCString { siril_sequence_frame(directory, $0, Int32(index), &error, capacity) } }) else { throw EngineError.failed(String(cString: error)) }
        defer { siril_image_free(image) }
        var preview = SirilPreview()
        let success: Int32
        if let settings { success = try settings.withNative { siril_image_preview_mode(image, 1536, Int32(channel), &$0, &preview) } }
        else { success = siril_image_preview_display(image, 1536, Int32(channel), automatic ? 1 : 0, &preview) }
        guard success != 0, let bytes = preview.rgba else { throw EngineError.failed("无法预览序列帧，请检查显示范围。") }
        defer { siril_preview_free(&preview) }
        return PreviewBytes(data: Data(bytes: bytes, count: Int(preview.width * preview.height) * 4), width: Int(preview.width), height: Int(preview.height))
    }
    func exportSequenceQuality(_ location: SequenceLocation, layer: Int) throws -> URL {
        let snapshot = try inspectSequence(location, layer: layer)
        var rows = ["index,file_number,included,reference," + SequenceMetric.allCases.filter { $0 != .frame }.map(\.rawValue).joined(separator: ",")]
        for frame in snapshot.frames {
            rows.append("\(frame.id + 1),\(frame.native.file_number),\(frame.included ? 1 : 0),\(frame.id == Int(snapshot.info.reference) ? 1 : 0)," + SequenceMetric.allCases.filter { $0 != .frame }.map { metric in
                frame.value(metric).map { String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
            }.joined(separator: ","))
        }
        let url = try sequenceEditURLs(location).history.deletingLastPathComponent().appendingPathComponent(location.name + "-quality-\(layer).csv")
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func createSequence(files: [FITSRecord]) throws -> ProcessingJob {
        let lights = files.filter { $0.role == .lights }
        guard let first = lights.first, lights.count >= 2, lights.allSatisfy({ $0.width == first.width && $0.height == first.height && $0.channels == first.channels }) else { throw EngineError.failed("建立序列需至少两张尺寸、通道相同的亮场。") }
        let job = try prepareJob(files: lights, script: "set32bits\ncd lights\nconvert light -out=../process\n")
        _ = try run(job)
        // convert writes numbered FITS; desktop directory scanning creates the
        // .seq index later. Invoke that original scanner before returning.
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        let indexed = job.folder.appendingPathComponent("process").path.withCString { siril_sequence_discover($0, &error, capacity) }
        try? Self.processingLog().write(to: job.folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
        guard indexed != 0 else {
            try? writeJobState(job.folder, state: "序列索引失败", message: String(cString: error))
            throw EngineError.failed(String(cString: error))
        }
        return job
    }
    func runSequenceCommand(_ location: SequenceLocation, command: String, title: String, options: BatchOptions? = nil, flat: URL? = nil, producesSequence: Bool = false, runID: UUID = UUID()) throws -> URL {
        let snapshot = try inspectSequence(location)
        let process = try sequenceFolder(location), job = process.deletingLastPathComponent()
        let folder = try owned(runID.uuidString, under: try owned("SequenceRuns", under: job))
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw EngineError.failed("序列运行编号已使用，请重新运行。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = "r_" + folder.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
        try JSONEncoder().encode(location).write(to: folder.appendingPathComponent("source-location.json"), options: .atomic)
        if producesSequence {
            try JSONEncoder().encode(SequenceLocation(job: location.job, name: prefix + location.name))
                .write(to: folder.appendingPathComponent("output-sequence.json"), options: .atomic)
        }
        let relative = "../SequenceRuns/\(folder.lastPathComponent)/"
        if let flat { try FileManager.default.copyItem(at: flat, to: folder.appendingPathComponent("flat.fits")) }
        if let options { try JSONEncoder().encode(options).write(to: folder.appendingPathComponent("batch-options.json"), options: .atomic) }
        let script = "# \(title)\ncd process\n" + command.replacingOccurrences(of: "$OUTPUT", with: relative + "result.fits").replacingOccurrences(of: "$CSV", with: relative + "statistics.csv").replacingOccurrences(of: "$PREFIX", with: prefix).replacingOccurrences(of: "$FLAT", with: relative + "flat.fits") + "\n"
        try script.write(to: folder.appendingPathComponent("processing.ssf"), atomically: true, encoding: .utf8)
        try Data(contentsOf: process.appendingPathComponent(location.name)).write(to: folder.appendingPathComponent("source.seq"), options: .atomic)
        let state = JobState(created: Date(), updated: Date(), state: "运行中", inputCount: Int(snapshot.info.included), message: title)
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("job.json"), options: .atomic)
        activeJobIDs.insert(location.job)
        defer { activeJobIDs.remove(location.job) }
        var error = [CChar](repeating: 0, count: 4096)
        let capacity = error.count
        let success = job.path.withCString { directory in script.withCString { siril_run_commands(directory, $0, &error, capacity) } }
        try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
        try? writeJobState(folder, state: success != 0 ? "已完成" : "已停止或失败", message: success != 0 ? title : String(cString: error))
        guard success != 0 else { throw EngineError.failed(String(cString: error)) }
        return folder
    }
    func sequenceCommandName(_ location: SequenceLocation) throws -> String {
        guard !location.base.contains("\""), !location.base.contains("\n"), !location.base.contains("\r") else { throw EngineError.failed("序列名称含无效命令字符。") }
        return "\"" + location.base + "\""
    }
    func cropSequence(_ location: SequenceLocation, region: ImageSelection) throws -> SequenceLocation {
        let before = try inspectSequence(location)
        let selected = before.frames.filter(\.included)
        guard !selected.isEmpty, before.info.drizzle == 0, location.base.utf8.count < 180 else {
            throw EngineError.failed("裁剪需要参与帧及有效的序列名称；Drizzle 权重裁剪尚未接入。")
        }
        guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
              selected.allSatisfy({ region.width <= Int($0.native.width) && region.height <= Int($0.native.height) &&
                  region.x <= Int($0.native.width) - region.width && region.y <= Int($0.native.height) - region.height }) else {
            throw EngineError.failed("裁剪选区必须位于每一张参与帧内。")
        }
        let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
        let runID = UUID(), prefix = "r_" + runID.uuidString.replacingOccurrences(of: "-", with: "") + "_"
        let folder = try owned(runID.uuidString, under: try owned("SequenceRuns", under: root))
        let output = SequenceLocation(job: location.job, name: prefix + location.name)
        do {
            _ = try runSequenceCommand(location, command: "seqcrop \(sequenceCommandName(location)) \(region.x) \(region.y) \(region.width) \(region.height) -prefix=$PREFIX",
                title: "原版参与帧裁剪 · \(region.description)", producesSequence: true, runID: runID)
            try JSONEncoder().encode(region).write(to: folder.appendingPathComponent("crop.json"), options: .atomic)
            let generated = try inspectSequence(output)
            guard generated.info.count == Int32(selected.count), generated.info.layers == before.info.layers,
                  generated.frames.allSatisfy({ Int($0.native.width) == region.width && Int($0.native.height) == region.height }),
                  before.info.type != 0 || generated.frames.map({ $0.native.file_number }) == selected.map({ $0.native.file_number }) else {
                throw EngineError.failed("裁剪输出的帧数、编号、尺寸或通道不符；请查看本次日志。")
            }
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            for frame in generated.frames {
                guard let image = process.path.withCString({ directory in output.name.withCString {
                    siril_sequence_frame(directory, $0, Int32(frame.id), &error, capacity)
                } }) else { throw EngineError.failed(String(cString: error)) }
                siril_image_free(image)
            }
            let reference = before.info.reference >= 0 ? selected.firstIndex(where: { $0.id == Int(before.info.reference) }) ?? -1 : -1
            try editSequence(output, selection: SequenceSelection(included: Array(repeating: true, count: selected.count), reference: reference))
            try writeJobState(folder, state: "已完成", message: "裁剪后的所有参与帧已验证。")
            return output
        } catch {
            if FileManager.default.fileExists(atPath: folder.path) {
                try? JSONEncoder().encode(region).write(to: folder.appendingPathComponent("crop.json"), options: .atomic)
                try? writeJobState(folder, state: "裁剪失败或取消", message: error.localizedDescription)
            }
            siril_release_workspace()
            // Only this run's UUID-prefixed regular files are removed. Failed
            // partial sequences never become usable processing results.
            for directory in [process, process.appendingPathComponent("cache"), process.appendingPathComponent("drizztmp")] {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let parent: URL
                if directory == process { parent = process }
                else { parent = try owned(directory.lastPathComponent, under: process) }
                for item in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey]) where item.lastPathComponent.hasPrefix(prefix) {
                    let ownedFile = try owned(item.lastPathComponent, under: parent)
                    guard (try ownedFile.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw EngineError.failed("裁剪输出清理遇到非普通文件。") }
                    try FileManager.default.removeItem(at: ownedFile)
                }
            }
            throw error
        }
    }
    func measureSequence(_ location: SequenceLocation, options: BatchOptions, layer: Int) throws {
        let snapshot = try inspectSequence(location, layer: layer)
        guard snapshot.info.included >= 2, (4...2000).contains(options.minimumPairs), (100...2000).contains(options.maximumStars), options.minimumPairs <= options.maximumStars else {
            throw EngineError.failed("星点配准需至少两张参与帧，并设置有效的星对、星点数量。")
        }
        // Native two-pass analysis always chooses a reference. seqapplyreg
        // can reframe its measured matrices around another included frame.
        let name = try sequenceCommandName(location)
        let restoreReference = snapshot.info.reference >= 0 ? "\nsetref \(name) \(snapshot.info.reference + 1)" : ""
        _ = try runSequenceCommand(location, command: "register \(name) -2pass -selected -transf=\(options.transform.rawValue) -minpairs=\(options.minimumPairs) -maxstars=\(options.maximumStars) -layer=\(layer)" + restoreReference, title: "原版两遍星点配准与质量测量", options: options)
        let measured = try inspectSequence(location, layer: layer)
        guard measured.frames.filter({ $0.included && $0.native.has_registration != 0 }).count >= 2 else { throw EngineError.failed("原版未测得足够的参与帧配准数据，请检查星点检测和运行日志。") }
    }
    func applySequenceRegistration(_ location: SequenceLocation, options: BatchOptions, layer: Int, flat: FITSRecord? = nil) throws -> SequenceLocation {
        let snapshot = try inspectSequence(location, layer: layer)
        guard snapshot.info.included >= 2, snapshot.frames.filter(\.included).allSatisfy({ $0.native.has_registration != 0 }) else {
            throw EngineError.failed("请先对当前参与帧执行两遍星点配准，再应用变换。新增参与帧需要重新测量。")
        }
        guard location.base.utf8.count < 180, options.scale.isFinite, (0.1...3).contains(options.scale) else { throw EngineError.failed("输出倍率须在 0.1–3；序列名称过长时请从原始序列重新应用。") }
        let drizzle = options.drizzleOptions
        if drizzle.enabled {
            guard snapshot.info.layers == 1, drizzle.pixelFraction.isFinite, (0.1...10).contains(drizzle.pixelFraction) else { throw EngineError.failed("Drizzle 需要单通道单色或 Bayer 原始数据，像素比例须在 0.1–10。") }
        } else if options.interpolation == .none && (options.scale != 1 || options.framing == .min || options.framing == .max) {
            throw EngineError.failed("不插值需保持倍率 1，并选择参考帧范围或图像中心；矩阵必须为仅平移。")
        }
        for filter in options.filters where filter.enabled {
            guard filter.value.isFinite, filter.value > 0, filter.limit != .percentage || filter.value <= 100,
                  filter.limit != .threshold || filter.metric != .round || filter.value <= 1 else { throw EngineError.failed("质量筛选阈值无效。") }
        }
        var flatURL: URL?
        if drizzle.enabled && drizzle.useFlat {
            if let flat {
                guard flat.channels == 1, flat.width == Int(snapshot.info.width), flat.height == Int(snapshot.info.height), loadLibrary().contains(where: { $0.id == flat.id }) else { throw EngineError.failed("主平场必须来自图库，且尺寸、通道与输入序列一致。") }
                flatURL = try owned(flat.url.lastPathComponent, under: documents.appendingPathComponent("FITS"))
            } else {
                flatURL = try owned("master_flat.fits", under: sequenceFolder(location))
            }
            guard let flatURL, FileManager.default.fileExists(atPath: flatURL.path) else { throw EngineError.failed("当前任务没有主平场，请从图库选择已校准的主平场或关闭平场权重。") }
        }
        func number(_ value: Double) -> String { String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value) }
        var args = ["seqapplyreg", try sequenceCommandName(location), "-prefix=$PREFIX", "-layer=\(layer)", "-filter-included", "-framing=\(options.framing.rawValue)", "-scale=\(number(options.scale))"]
        if drizzle.enabled {
            args += ["-drizzle", "-pixfrac=\(number(drizzle.pixelFraction))", "-kernel=\(drizzle.kernel.rawValue)"]
            if drizzle.useFlat { args += ["-flat=$FLAT"] }
        } else {
            args += ["-interp=\(options.interpolation.rawValue)"]
            if options.interpolation.supportsClamp && !options.clamp { args += ["-noclamp"] }
        }
        for filter in options.filters where filter.enabled { args += ["-filter-\(filter.metric.rawValue)=\(number(filter.value))\(filter.limit.suffix)"] }
        let command = "set32bits\nset gui_registration.drizz_weight_match_bitpix=\(drizzle.matchWeightBitDepth ? "true" : "false")\n" + args.joined(separator: " ")
        let folder = try runSequenceCommand(location, command: command, title: "应用当前序列配准变换", options: options, flat: flatURL, producesSequence: true)
        let prefix = "r_" + folder.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
        let output = SequenceLocation(job: location.job, name: prefix + location.name)
        do {
            let generated = try inspectSequence(output, layer: drizzle.enabled ? 0 : layer)
            guard generated.info.count >= 2 else { throw EngineError.failed("原版未生成至少两张配准输出。") }
            try JSONEncoder().encode(output).write(to: folder.appendingPathComponent("output-sequence.json"), options: .atomic)
            return output
        } catch {
            try? writeJobState(folder, state: "输出验证失败", message: error.localizedDescription)
            throw EngineError.failed("Siril 未生成可用的配准序列，请查看运行日志。\n" + error.localizedDescription)
        }
    }
    func sequenceStatistics(_ location: SequenceLocation) throws -> URL {
        let folder = try runSequenceCommand(location, command: "seqstat \(sequenceCommandName(location)) $CSV main", title: "原版序列统计")
        let csv = folder.appendingPathComponent("statistics.csv")
        guard FileManager.default.fileExists(atPath: csv.path) else { throw EngineError.failed("Siril 未生成序列统计，请查看本次运行日志。") }
        return csv
    }
    func stackSequence(_ location: SequenceLocation, options: BatchOptions, layer: Int) throws -> URL {
        let snapshot = try inspectSequence(location, layer: layer)
        guard snapshot.info.included >= 2 else { throw EngineError.failed("叠加需至少两张参与帧。") }
        let registered = snapshot.frames.contains { $0.native.has_registration != 0 }
        if options.method == .mean {
            if options.rejection != .none {
                guard snapshot.info.included >= 3, options.low.isFinite, options.high.isFinite, options.low >= 0, options.high >= 0,
                      !options.rejection.fractional || (options.low <= 1 && options.high <= 1),
                      options.rejection != .generalized || (options.low > 0 && options.high > 0 && options.high < 1) else { throw EngineError.failed("剔除需要至少三张参与帧及有效的剔除参数。") }
            }
            if options.weight == .noise && options.normalization == .none { throw EngineError.failed("噪声权重需要输入归一化。") }
            if [.nbstars, .wfwhm].contains(options.weight) && !registered { throw EngineError.failed("所选序列尚未测得配准质量，不能使用星数或 FWHM 权重。") }
        }
        for filter in options.filters where filter.enabled && registered {
            guard filter.value.isFinite, filter.value > 0, filter.limit != .percentage || filter.value <= 100,
                  filter.limit != .threshold || filter.metric != .round || filter.value <= 1 else { throw EngineError.failed("质量筛选阈值无效。") }
        }
        let command = "set32bits\n" + SirilWorkflow.stackCommand(sequence: try sequenceCommandName(location), options: options, channels: Int(snapshot.info.layers), includeQuality: registered, output: "$OUTPUT")
        let folder = try runSequenceCommand(location, command: command, title: "按当前序列选择重新叠加", options: options)
        let result = folder.appendingPathComponent("result.fits")
        guard FileManager.default.fileExists(atPath: result.path) else { throw EngineError.failed("Siril 未生成叠加结果，请查看运行日志。") }
        return result
    }
}
