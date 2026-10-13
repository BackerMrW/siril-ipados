// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func importSER(_ source: URL, role: FrameRole = .lights) throws -> [FITSRecord] {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("SER-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let copied = temporary.appendingPathComponent("capture.ser")
        try manager.copyItem(at: source, to: copied)
        var error = [CChar](repeating: 0, count: 512); let capacity = error.count
        guard let session = copied.path.withCString({ siril_ser_open($0, &error, capacity) }) else {
            throw EngineError.failed(String(cString: error))
        }
        defer { siril_ser_close(session) }
        let folder = manager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("FITS", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = UUID().uuidString + "-" + source.lastPathComponent + "-"
        var created: [URL] = [], records: [FITSRecord] = []
        do {
            for frame in 0..<siril_ser_count(session) {
                try Task.checkCancellation()
                guard let image = siril_ser_read(session, frame, &error, capacity) else { throw EngineError.failed(String(cString: error)) }
                defer { siril_image_free(image) }
                var info = SirilImageInfo()
                guard siril_image_info(image, &info) != 0 else { throw EngineError.failed("SER 帧信息读取失败。") }
                let output = folder.appendingPathComponent(prefix + String(format: "%06d", frame + 1) + ".fits")
                created.append(output)
                guard output.path.withCString({ siril_image_write(image, $0) }) != 0 else { throw EngineError.failed("SER 帧保存失败。") }
                records.append(FITSRecord(url: output, width: Int(info.width), height: Int(info.height), channels: Int(info.channels), exposure: info.exposure, role: role))
            }
            return records
        } catch {
            for output in created { try? manager.removeItem(at: output) }
            throw error
        }
    }
}
