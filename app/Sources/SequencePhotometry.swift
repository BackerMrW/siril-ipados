// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct SequencePhotometryRecipe: Codable, Equatable, Sendable {
    var settings: StarSettings = { var s = StarSettings(); s.photometry = true; return s }()
    var regions: [ImageSelection] = []
    var framing = 2
    var current = 0
    var lightCurve = false
}
struct SequenceStarRow: Codable, Sendable, Identifiable {
    let star: Int, frame: Int, number: Int, included: Bool
    let measurement: StarMeasurement?
    var id: String { "\(star)-\(frame)" }
}
struct LightCurvePoint: Codable, Sendable, Identifiable {
    let time: Double, magnitude: Double, error: Double
    var id: Double { time }
}
struct SequencePhotometryReport: Codable, Sendable {
    let source: SequenceLocation
    let recipe: SequencePhotometryRecipe
    let rows: [SequenceStarRow]
    let curve: [LightCurvePoint]
    let created: Date
}
extension SirilEngine {
    func sequencePhotometryReports(_ location: SequenceLocation) throws -> [URL] {
        let root = try sequenceFolder(location).deletingLastPathComponent().appendingPathComponent("Photometry")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { (try? owned($0.lastPathComponent, under: root)) != nil && FileManager.default.fileExists(atPath: $0.appendingPathComponent("report.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func sequencePhotometry(_ location: SequenceLocation, recipe: SequencePhotometryRecipe) throws -> URL {
        let snapshot = try inspectSequence(location, layer: recipe.settings.channel)
        try recipe.settings.validate(channels: Int(snapshot.info.layers))
        guard (1...20).contains(recipe.regions.count), (0...2).contains(recipe.framing),
              (0..<snapshot.frames.count).contains(recipe.current), snapshot.frames[recipe.current].included,
              !recipe.lightCurve || recipe.regions.count >= 2 else { throw EngineError.failed("需要参与帧、1–20 个选区；光变曲线需目标星和至少一颗参考星") }
        let process = try sequenceFolder(location), fm = FileManager.default
        let root = try owned("Photometry", under: process.deletingLastPathComponent())
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try owned(UUID().uuidString, under: root)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(recipe).write(to: folder.appendingPathComponent("recipe.json"), options: .atomic)
        var regions = recipe.regions.map(\.native), finder = recipe.settings.finder, phot = recipe.settings.phot
        let count = snapshot.frames.count * regions.count
        var results = [SirilStarMeasurement](repeating: SirilStarMeasurement(), count: count), error = [CChar](repeating: 0, count: 512)
        let curveURL = folder.appendingPathComponent("light_curve.dat")
        let ok = process.path.withCString { directory in location.name.withCString { name in
            if recipe.lightCurve {
                return curveURL.path.withCString { path in siril_sequence_photometry(directory, name, Int32(recipe.current), Int32(recipe.framing), &regions, regions.count, &finder, &phot, path, &results, count, &error, error.count) }
            }
            return siril_sequence_photometry(directory, name, Int32(recipe.current), Int32(recipe.framing), &regions, regions.count, &finder, &phot, nil, &results, count, &error, error.count)
        } }
        try Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
        guard ok != 0 else {
            try String(cString: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            throw EngineError.failed(String(cString: error))
        }
        var rows: [SequenceStarRow] = []
        for s in regions.indices { for frame in snapshot.frames {
            let raw = results[s * snapshot.frames.count + frame.id]
            let measurement = raw.fwhm_x > 0 && raw.fwhm_y > 0 ? try StarMeasurement(raw) : nil
            rows.append(SequenceStarRow(star: s, frame: frame.id, number: Int(frame.native.file_number), included: frame.included, measurement: measurement))
        } }
        var curve: [LightCurvePoint] = []
        if recipe.lightCurve {
            for line in try String(contentsOf: curveURL).components(separatedBy: .newlines) where !line.hasPrefix("#") {
                let numbers = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                if numbers.count == 3 && numbers.allSatisfy(\.isFinite) { curve.append(LightCurvePoint(time: numbers[0], magnitude: numbers[1], error: numbers[2])) }
            }
            guard !curve.isEmpty else { throw EngineError.failed("原版光变输出没有有效数据") }
        }
        let report = SequencePhotometryReport(source: location, recipe: recipe, rows: rows, curve: curve, created: Date())
        try JSONEncoder().encode(report).write(to: folder.appendingPathComponent("report.json"), options: .atomic)
        var csv = ["star,frame,file_number,included,valid,x,y,fwhm_x_px,fwhm_y_px,magnitude,magnitude_error,snr_dB,background,amplitude,rmse"]
        for row in rows {
            let prefix = "\(row.star + 1),\(row.frame + 1),\(row.number),\(row.included ? 1 : 0),\(row.measurement?.photometryValid == true ? 1 : 0)"
            if let m = row.measurement {
                csv.append(prefix + "," + [m.x, m.y, m.fwhmX, m.fwhmY, m.magnitude, m.magnitudeError, m.snr, m.background, m.amplitude, m.rmse].map { String(format: "%.12g", $0) }.joined(separator: ","))
            } else { csv.append(prefix + ",,,,,,,,,,") }
        }
        try csv.joined(separator: "\n").write(to: folder.appendingPathComponent("photometry.csv"), atomically: true, encoding: .utf8)
        return folder
    }
}

struct SequencePhotometryHistory: Codable, Sendable {
    let source: SequenceLocation
    var current = SequencePhotometryRecipe(), past: [SequencePhotometryRecipe] = [], future: [SequencePhotometryRecipe] = []
    mutating func record(_ recipe: SequencePhotometryRecipe) {
        guard recipe != current else { return }
        past.append(current); past = Array(past.suffix(30)); current = recipe; future = []
    }
    mutating func undo() { if let recipe = past.popLast() { future.append(current); current = recipe } }
    mutating func redo() { if let recipe = future.popLast() { past.append(current); current = recipe } }
}
extension SirilEngine {
    private func photometryHistoryURL(_ location: SequenceLocation) throws -> URL {
        let root = try owned("SequenceEdits", under: sequenceFolder(location).deletingLastPathComponent())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try owned(location.name + ".photometry.json", under: root)
    }
    func photometryHistory(_ location: SequenceLocation) throws -> SequencePhotometryHistory {
        let url = try photometryHistoryURL(location)
        guard FileManager.default.fileExists(atPath: url.path) else { return SequencePhotometryHistory(source: location) }
        let history = try JSONDecoder().decode(SequencePhotometryHistory.self, from: Data(contentsOf: url))
        guard history.source == location, history.past.count <= 30, history.future.count <= 30 else { throw EngineError.failed("序列测光编辑记录不匹配") }
        return history
    }
    func savePhotometryHistory(_ history: SequencePhotometryHistory) throws {
        try JSONEncoder().encode(history).write(to: photometryHistoryURL(history.source), options: .atomic)
    }
}
