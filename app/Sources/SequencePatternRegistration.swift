// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

enum SequencePatternMethod: String, BatchChoice {
    case dft, kombat
    var title: String { self == .dft ? "DFT 图像图案" : "KOMBAT 图像图案" }
    var native: Int32 { self == .dft ? 0 : 1 }
}
struct SequencePatternRecipe: Codable, Sendable {
    let method: SequencePatternMethod
    let region: ImageSelection
    let layer: Int
    let moved: Double
}
extension SirilEngine {
    func measurePatternRegistration(_ location: SequenceLocation, recipe: SequencePatternRecipe) throws {
        guard (0...2).contains(recipe.layer) else { throw EngineError.failed("图案配准通道无效。") }
        let before = try inspectSequence(location, layer: recipe.layer), area = recipe.region
        guard before.info.included >= 2, before.info.width > 0, before.info.height > 0, recipe.moved.isFinite,
              (0...1).contains(recipe.moved), recipe.method != .kombat || recipe.moved >= 0.05,
              area.x >= 0, area.y >= 0, area.width >= 8, area.height >= 8,
              area.width <= Int(before.info.width), area.height <= Int(before.info.height),
              area.x <= Int(before.info.width) - area.width, area.y <= Int(before.info.height) - area.height,
              recipe.method != .dft || area.width == area.height else {
            throw EngineError.failed("图案配准需要至少两张参与帧和图像内至少8×8的选区；DFT 选区必须为正方形。")
        }
        let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
        let sequence = try owned(location.name, under: process), original = try Data(contentsOf: sequence)
        let folder = try owned(UUID().uuidString, under: try owned("SequenceRuns", under: root))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try original.write(to: folder.appendingPathComponent("source.seq"), options: .atomic)
        try JSONEncoder().encode(location).write(to: folder.appendingPathComponent("source-location.json"), options: .atomic)
        try JSONEncoder().encode(recipe).write(to: folder.appendingPathComponent("pattern.json"), options: .atomic)
        let state = JobState(created: Date(), updated: Date(), state: "运行中", inputCount: Int(before.info.included), message: recipe.method.title)
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("job.json"), options: .atomic)
        activeJobIDs.insert(location.job); defer { activeJobIDs.remove(location.job) }
        do {
            var error = [CChar](repeating: 0, count: 4096), native = area.native; let capacity = error.count
            let success = process.path.withCString { directory in location.name.withCString {
                siril_sequence_pattern_register(directory, $0, recipe.method.native, Int32(recipe.layer), &native, recipe.moved, &error, capacity)
            } }
            try Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            guard success != 0 else { throw EngineError.failed(String(cString: error)) }
            let after = try inspectSequence(location, layer: recipe.layer)
            guard after.info.count == before.info.count, after.selection.included == before.selection.included,
                  before.info.reference < 0 || after.info.reference == before.info.reference,
                  after.frames.filter(\.included).allSatisfy({ $0.native.has_registration != 0 }) else {
                throw EngineError.failed("并非所有参与帧都获得有效图案配准；原序列元数据已恢复。")
            }
            try writeJobState(folder, state: "已完成", message: recipe.method.title + "：参与帧矩阵已验证。")
        } catch {
            siril_release_workspace()
            try original.write(to: sequence, options: .atomic)
            try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            try? writeJobState(folder, state: "图案配准失败或取消", message: error.localizedDescription)
            throw error
        }
    }
}
