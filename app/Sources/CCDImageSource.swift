// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct CCDSourceDetails: Sendable {
    let title: String
    let width: Int, height: Int, channels: Int
}
enum CCDImageSource: Sendable, Identifiable {
    case file(FITSRecord)
    case frame(directory: URL, name: String, index: Int, details: CCDSourceDetails)
    var id: String {
        switch self {
        case .file(let file): return file.id.uuidString
        case .frame(let directory, let name, let index, _): return directory.path + "/" + name + "#" + String(index)
        }
    }
    var details: CCDSourceDetails {
        switch self {
        case .file(let file): return CCDSourceDetails(title: file.displayName, width: file.width, height: file.height, channels: file.channels)
        case .frame(_, _, _, let details): return details
        }
    }
}
extension SirilEngine {
    func ccdFrameSource(_ location: SequenceLocation, index: Int) throws -> CCDImageSource {
        let snapshot = try inspectSequence(location)
        guard snapshot.frames.indices.contains(index), [1, 3].contains(Int(snapshot.info.layers)) else {
            throw EngineError.failed("当前序列帧不可用。")
        }
        let frame = snapshot.frames[index].native
        guard frame.width > 0, frame.height > 0 else { throw EngineError.failed("当前帧尺寸无效。") }
        return .frame(directory: try sequenceFolder(location), name: location.name, index: index,
            details: CCDSourceDetails(title: location.name + " · 帧 \(index + 1)", width: Int(frame.width), height: Int(frame.height), channels: Int(snapshot.info.layers)))
    }
}
extension ImageAnalysisEngine {
    func openCCDSource(_ source: CCDImageSource) throws -> ImageDetails {
        try Task.checkCancellation()
        switch source {
        case .file(let file): return try open(file.url)
        case .frame(let directory, let name, let index, _):
            if let image { siril_image_free(image); self.image = nil }
            guard index >= 0, index <= Int(Int32.max) else { throw EngineError.failed("序列帧序号无效。") }
            var error = [CChar](repeating: 0, count: 1024); let capacity = error.count
            let frame = directory.path.withCString { folder in name.withCString {
                siril_sequence_frame(folder, $0, Int32(index), &error, capacity)
            } }
            guard let frame else { throw EngineError.failed(String(cString: error)) }
            image = frame
            return try imageDetails()
        }
    }
}
