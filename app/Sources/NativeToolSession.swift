// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct NativeToolHistory: Codable, Sendable {
    let sourceID: UUID
    let width: Int, height: Int
    var current: NativeToolRecipe
    var past: [NativeToolRecipe] = [], future: [NativeToolRecipe] = []
    mutating func record(_ recipe: NativeToolRecipe) {
        guard recipe != current else { return }
        past.append(current); past = Array(past.suffix(30)); current = recipe; future = []
    }
    mutating func step(redo: Bool) {
        if redo, let value = future.popLast() { past.append(current); past = Array(past.suffix(30)); current = value }
        else if !redo, let value = past.popLast() { future.append(current); future = Array(future.suffix(30)); current = value }
    }
}
extension SirilEngine {
    private func toolHistoryURL(_ file: FITSRecord) throws -> URL {
        let root = documents.appendingPathComponent("FITS")
        let source = try owned(file.url.lastPathComponent, under: root)
        guard source.path == file.url.standardizedFileURL.resolvingSymlinksInPath().path, FileManager.default.fileExists(atPath: source.path) else { throw EngineError.failed("原图已删除或不在图库中。") }
        return try owned(source.lastPathComponent + ".tools.json", under: root)
    }
    func nativeToolHistory(_ file: FITSRecord, tool: NativeTool) throws -> NativeToolHistory {
        let url = try toolHistoryURL(file)
        if !FileManager.default.fileExists(atPath: url.path) {
            return NativeToolHistory(sourceID: file.id, width: file.width, height: file.height, current: NativeToolRecipe(tool: tool, file: file))
        }
        var history = try JSONDecoder().decode(NativeToolHistory.self, from: Data(contentsOf: url))
        guard history.sourceID == file.id, history.width == file.width, history.height == file.height, history.past.count <= 30, history.future.count <= 30 else { throw EngineError.failed("工具编辑历史与原图不匹配。") }
        // Keep editable invalid combinations (e.g. a temporarily inverted range),
        // but never accept foreign fields or nonfinite stored data.
        for recipe in history.past + [history.current] + history.future {
            guard Set(recipe.values.keys) == Set(recipe.tool.fields.map(\.id)), recipe.values.values.allSatisfy(\.isFinite), Set(recipe.mask.values.keys) == Set(ToolMask.fields.map(\.id)), recipe.mask.values.values.allSatisfy(\.isFinite) else { throw EngineError.failed("工具历史中的参数无效。") }
        }
        if history.current.tool != tool { history.record(NativeToolRecipe(tool: tool, file: file)) }
        return history
    }
    func saveNativeToolHistory(_ history: NativeToolHistory, file: FITSRecord) throws {
        guard history.sourceID == file.id, history.width == file.width, history.height == file.height, history.past.count <= 30, history.future.count <= 30 else { throw EngineError.failed("工具历史与原图不匹配。") }
        try JSONEncoder().encode(history).write(to: toolHistoryURL(file), options: .atomic)
    }
    func prepareNativeToolJob(file: FITSRecord, recipe: NativeToolRecipe, library: [FITSRecord]) throws -> ProcessingJob {
        var inputs = [file]
        for id in [recipe.guideID, recipe.mask.number("mode") == 3 ? recipe.mask.sourceID : nil].compactMap({ $0 }) where !inputs.contains(where: { $0.id == id }) {
            guard let record = library.first(where: { $0.id == id }) else { throw EngineError.failed("蒙版或引导图已删除，请先恢复。") }; inputs.append(record)
        }
        var script = try recipe.commands(file: file)
        func copied(_ id: UUID) throws -> String {
            guard let record = inputs.first(where: { $0.id == id }), let index = inputs.filter({ $0.role == record.role }).firstIndex(where: { $0.id == id }) else { throw EngineError.failed("工具输入不完整。") }
            return record.role.rawValue + "/" + String(format: "frame_%05d.fits", index + 1)
        }
        script = script.replacingOccurrences(of: "load input.fits", with: "load " + (try copied(file.id)))
        if let id = recipe.guideID { script = script.replacingOccurrences(of: "guide.fits", with: try copied(id)) }
        if recipe.mask.number("mode") == 3, let id = recipe.mask.sourceID { script = script.replacingOccurrences(of: "mask-source.fits", with: try copied(id)) }
        let job = try prepareJob(files: inputs, script: script + "save process/result.fits\nclose\n")
        if recipe.mask.number("mode") == 6 {
            let saved = try owned(file.url.lastPathComponent + ".mask.fits", under: documents.appendingPathComponent("FITS"))
            try FileManager.default.copyItem(at: saved, to: job.folder.appendingPathComponent("mask-source.fits"))
        }
        try JSONEncoder().encode(recipe).write(to: job.folder.appendingPathComponent("native-tool.json"), options: .atomic)
        return job
    }
}

// Original commands use a temporary fixed-name input snapshot. Its decoded
// preview and mask are atomically detached from global gfit by the C bridge.
actor NativeToolSession {
    private var folder: URL?
    private var source: FITSRecord?
    private var original: OpaquePointer?, result: OpaquePointer?, maskImage: OpaquePointer?
    private var computed: NativeToolRecipe?
    deinit {
        for pointer in [original, result, maskImage].compactMap({ $0 }) { siril_image_free(pointer) }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
    func open(_ file: FITSRecord) throws {
        close()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeTools").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        folder = cache; source = file
        try FileManager.default.copyItem(at: file.url, to: cache.appendingPathComponent("input.fits"))
        var error = [CChar](repeating: 0, count: 512); let size = error.count
        original = cache.appendingPathComponent("input.fits").path.withCString { siril_image_read($0, &error, size) }
        guard original != nil else { close(); throw EngineError.failed(String(cString: error)) }
    }
    func close() {
        for pointer in [original, result, maskImage].compactMap({ $0 }) { siril_image_free(pointer) }
        original = nil; result = nil; maskImage = nil; computed = nil; source = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil
    }
    func compute(_ recipe: NativeToolRecipe, library: [FITSRecord]) throws {
        guard let folder, let source else { throw EngineError.failed("工具会话已关闭。") }
        computed = nil
        let script = try recipe.commands(file: source)
        func copyReference(_ id: UUID, name: String, mask: Bool) throws {
            guard let file = library.first(where: { $0.id == id }), file.width == source.width, file.height == source.height, [1, 3].contains(file.channels) else { throw EngineError.failed(mask ? "蒙版图必须与原图同尺寸。" : "引导图必须与原图同尺寸。") }
            let target = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: file.url, to: target)
        }
        if recipe.mask.number("mode") == 3, let id = recipe.mask.sourceID { try copyReference(id, name: "mask-source.fits", mask: true) }
        if recipe.mask.number("mode") == 6 {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FITS").standardizedFileURL.resolvingSymlinksInPath()
            let saved = source.url.appendingPathExtension("mask.fits").standardizedFileURL
            guard saved.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path, saved.resolvingSymlinksInPath().path == saved.path else { throw EngineError.failed("保存的蒙版路径无效。") }
            let target = folder.appendingPathComponent("mask-source.fits")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: saved, to: target)
        }
        if let id = recipe.guideID, recipe.tool == .guided { try copyReference(id, name: "guide.fits", mask: false) }
        var error = [CChar](repeating: 0, count: 4096); let size = error.count
        guard let output = folder.path.withCString({ directory in script.withCString { siril_tool_compute(directory, $0, &error, size) } }) else { throw EngineError.failed(String(cString: error)) }
        if let result { siril_image_free(result) }; if let maskImage { siril_image_free(maskImage) }
        result = output; maskImage = siril_image_mask_copy(output); computed = recipe
    }
    func preview(view: Int, channel: Int, automatic: Bool) throws -> PreviewBytes {
        let pointer = view == 0 ? original : view == 2 ? maskImage : result
        guard let pointer else { throw EngineError.failed(view == 2 ? "当前没有蒙版。" : "请先计算预览。") }
        var info = SirilImageInfo(); _ = siril_image_info(pointer, &info)
        var p = SirilPreview()
        guard siril_image_preview_display(pointer, 2048, info.channels == 1 ? -1 : Int32(channel), view == 2 ? 0 : automatic ? 1 : 0, &p) != 0, let rgba = p.rgba else { throw EngineError.failed("无法显示原版工具结果。") }
        defer { siril_preview_free(&p) }
        return PreviewBytes(data: Data(bytes: rgba, count: Int(p.width) * Int(p.height) * 4), width: Int(p.width), height: Int(p.height))
    }
    func info(view: Int) throws -> SirilImageInfo {
        let pointer = view == 0 ? original : view == 2 ? maskImage : result
        guard let pointer else { throw EngineError.failed("没有可读图像。") }
        var info = SirilImageInfo(); guard siril_image_info(pointer, &info) != 0 else { throw EngineError.failed("图像信息读取失败。") }; return info
    }
    func pixel(view: Int, x: Int, y: Int) throws -> [Float] {
        let pointer = view == 0 ? original : view == 2 ? maskImage : result
        guard let pointer else { throw EngineError.failed("没有可读图像。") }
        var values = [Float](repeating: 0, count: 3)
        let count = siril_image_pixel(pointer, Int32(x), Int32(y), &values)
        guard count > 0 else { throw EngineError.failed("像素坐标无效。") }; return Array(values.prefix(Int(count)))
    }
    func export(_ recipe: NativeToolRecipe, to job: ProcessingJob) throws -> URL {
        guard let result, computed == recipe else { throw EngineError.failed("参数已改变或计算失败，请重新计算预览再应用。") }
        let output = job.folder.appendingPathComponent("process/result.fits")
        guard output.path.withCString({ siril_image_write(result, $0) }) != 0 else { throw EngineError.failed("原版 FITS 导出失败。") }
        if let maskImage {
            let mask = output.appendingPathExtension("mask.fits")
            guard mask.path.withCString({ siril_image_write(maskImage, $0) }) != 0 else { throw EngineError.failed("蒙版保存失败；图像已保存，请查看处理记录。") }
        }
        return output
    }
}
