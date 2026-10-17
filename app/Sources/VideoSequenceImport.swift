// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func importVideoSequence(_ source: URL, bayer: Int = 0) throws -> SequenceLocation {
        guard (0...5).contains(bayer) else { throw EngineError.failed("视频 Bayer 排列无效。") }
        let ext = source.pathExtension.lowercased()
        guard ["avi", "mpg", "mpeg", "mov", "mp4", "webm"].contains(ext) else {
            throw EngineError.failed("请选择 AVI、MOV、MP4、MPEG 或 WebM 视频。")
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default, created = Date()
        let folder = try owned(UUID().uuidString, under: documents.appendingPathComponent("Jobs"))
        let input = try owned("video", under: folder), process = try owned("process", under: folder)
        do {
            try fm.createDirectory(at: input, withIntermediateDirectories: true)
            try fm.createDirectory(at: process, withIntermediateDirectories: true)
            try writeJobState(folder, state: "运行中", message: "原版视频解码与 SER 转换")
            let copy = try owned("capture." + ext, under: input)
            try Task.checkCancellation()
            try fm.copyItem(at: source.resolvingSymlinksInPath(), to: copy)
            _ = try owned(copy.lastPathComponent, under: input)
            var error = [CChar](repeating: 0, count: 2048); let capacity = error.count
            activeJobIDs.insert(folder.lastPathComponent)
            defer { activeJobIDs.remove(folder.lastPathComponent) }
            try Task.checkCancellation()
            let count = process.path.withCString { directory in copy.path.withCString {
                siril_video_convert(directory, $0, Int32(bayer), &error, capacity)
            } }
            activeJobIDs.remove(folder.lastPathComponent)
            try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            guard count >= 2 else { throw EngineError.failed(String(cString: error)) }
            try Task.checkCancellation()
            let container = try owned("capture.ser", under: process)
            guard let session = container.path.withCString({ siril_ser_open($0, &error, capacity) }) else {
                throw EngineError.failed(String(cString: error))
            }
            let valid = siril_ser_complete(session) != 0 && siril_ser_count(session) == UInt32(count)
            siril_ser_close(session)
            guard valid else { throw EngineError.failed("转换后的 SER 不完整或帧数不符。") }
            guard process.path.withCString({ siril_sequence_discover($0, &error, capacity) }) != 0 else {
                throw EngineError.failed(String(cString: error))
            }
            let location = SequenceLocation(job: folder.lastPathComponent, name: "capture.seq")
            guard try inspectSequence(location).info.count == count else { throw EngineError.failed("视频序列索引帧数不符。") }
            try JSONEncoder().encode(source.lastPathComponent).write(to: owned("video-source-name.json", under: folder), options: .atomic)
            try JSONEncoder().encode(bayer).write(to: owned("video-bayer.json", under: folder), options: .atomic)
            try JSONEncoder().encode(JobState(created: created, updated: Date(), state: "已完成", inputCount: Int(count),
                message: "原版视频解码为 SER；保留原视频副本，逐帧读取。"))
                .write(to: owned("job.json", under: folder), options: .atomic)
            return location
        } catch {
            siril_release_workspace()
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}
