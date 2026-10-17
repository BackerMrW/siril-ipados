// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func importSERSequence(_ source: URL) throws -> SequenceLocation {
        guard source.pathExtension.lowercased() == "ser" else { throw EngineError.failed("请选择 SER 文件。") }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let created = Date()
        let folder = try owned(UUID().uuidString, under: documents.appendingPathComponent("Jobs"))
        let process = try owned("process", under: folder)
        try fm.createDirectory(at: process, withIntermediateDirectories: true)
        do {
            try writeJobState(folder, state: "运行中", message: "复制并索引原生 SER 序列")
            try Task.checkCancellation()
            let copied = try owned("capture.ser", under: process)
            try fm.copyItem(at: source.resolvingSymlinksInPath(), to: copied)
            _ = try owned("capture.ser", under: process)
            var error = [CChar](repeating: 0, count: 1024); let capacity = error.count
            guard let session = copied.path.withCString({ siril_ser_open($0, &error, capacity) }) else {
                throw EngineError.failed(String(cString: error))
            }
            let count = siril_ser_count(session)
            let complete = siril_ser_complete(session) != 0
            siril_ser_close(session)
            guard complete else { throw EngineError.failed("SER 文件缺少声明的完整帧数据。") }
            guard count >= 2 else { throw EngineError.failed("原生 SER 序列需要至少两帧。") }
            try Task.checkCancellation()
            let indexed = process.path.withCString { siril_sequence_discover($0, &error, capacity) }
            try? Self.processingLog().write(to: folder.appendingPathComponent("processing.log"), atomically: true, encoding: .utf8)
            guard indexed != 0 else { throw EngineError.failed(String(cString: error)) }
            let location = SequenceLocation(job: folder.lastPathComponent, name: "capture.seq")
            let snapshot = try inspectSequence(location)
            guard snapshot.info.count == Int32(count), snapshot.info.width > 0, snapshot.info.height > 0 else {
                throw EngineError.failed("SER 序列索引与原始帧数不一致。")
            }
            try JSONEncoder().encode(source.lastPathComponent).write(to: owned("ser-source-name.json", under: folder), options: .atomic)
            try JSONEncoder().encode(JobState(created: created, updated: Date(), state: "已完成", inputCount: Int(count),
                message: "原生 SER 序列；保留容器，逐帧读取。"))
                .write(to: owned("job.json", under: folder), options: .atomic)
            return location
        } catch {
            siril_release_workspace()
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}
