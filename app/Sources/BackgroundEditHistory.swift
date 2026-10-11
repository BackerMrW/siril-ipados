// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct BackgroundPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    init(_ marker: SampleMarker) { x = marker.x; y = marker.y }
    init(x: Double, y: Double) { self.x = x; self.y = y }
}
struct BackgroundEdit: Codable, Equatable, Sendable {
    var settings = BackgroundSettings()
    var points: [BackgroundPoint] = []
}
// Store coordinates, never stale sample medians or duplicate FITS pixels.
struct BackgroundEditHistory: Codable, Equatable, Sendable {
    let sourceID: UUID
    let width: Int
    let height: Int
    var current = BackgroundEdit()
    var past: [BackgroundEdit] = []
    var future: [BackgroundEdit] = []
    init(file: FITSRecord) { sourceID = file.id; width = file.width; height = file.height }
    mutating func record(_ edit: BackgroundEdit) {
        guard edit != current else { return }
        past.append(current)
        if past.count > 30 { past.removeFirst(past.count - 30) }
        current = edit; future = []
    }
    mutating func undo() {
        guard let edit = past.popLast() else { return }
        future.append(current); current = edit
    }
    mutating func redo() {
        guard let edit = future.popLast() else { return }
        past.append(current); current = edit
    }
    static func url(for file: FITSRecord) throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FITS").standardizedFileURL.resolvingSymlinksInPath()
        let source = root.appendingPathComponent(file.url.lastPathComponent)
        let url = source.appendingPathExtension("background.json")
        guard file.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == root.path,
              source.resolvingSymlinksInPath().path == source.path, url.resolvingSymlinksInPath().path == url.path else {
            throw EngineError.failed("不能保存到图库以外的路径或符号链接")
        }
        return url
    }
    func save(for file: FITSRecord) throws {
        try JSONEncoder().encode(self).write(to: Self.url(for: file), options: .atomic)
    }
    static func load(for file: FITSRecord) throws -> Self {
        let url = try url(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self(file: file) }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.sourceID == file.id, value.width == file.width, value.height == file.height,
              value.past.count <= 30, value.future.count <= 30 else {
            throw EngineError.failed("背景编辑记录与原图不匹配")
        }
        return value
    }
}
