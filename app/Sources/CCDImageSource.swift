// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct CCDSourceDetails: Sendable {
    let title: String
    let width: Int, height: Int, channels: Int
    var includedFrames: [Int]? = nil
}
enum CCDImageSource: Sendable, Identifiable {
    case file(FITSRecord)
    case frame(directory: URL, name: String, index: Int, details: CCDSourceDetails)
    var id: String {
        switch self {
        case .file(let file): return file.id.uuidString
        case .frame(let directory, let name, let index, let details):
            return directory.path + "/" + name + "#" + String(index) + (details.includedFrames == nil ? "" : "#average")
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
    func ccdSequenceSource(_ location: SequenceLocation) throws -> CCDImageSource {
        let snapshot = try inspectSequence(location)
        let included = snapshot.frames.filter(\.included).map(\.id)
        guard let first = included.first, [1, 3].contains(Int(snapshot.info.layers)) else {
            throw EngineError.failed("序列没有可分析的参与帧。")
        }
        let reference = snapshot.frames.indices.contains(Int(snapshot.info.reference)) ? Int(snapshot.info.reference) : first
        let frame = snapshot.frames[reference].native
        guard frame.width > 0, frame.height > 0,
              snapshot.frames.filter(\.included).allSatisfy({ $0.native.width == frame.width && $0.native.height == frame.height }) else {
            throw EngineError.failed("倾斜平均需要参与帧尺寸一致。")
        }
        return .frame(directory: try sequenceFolder(location), name: location.name, index: reference,
            details: CCDSourceDetails(title: location.name + " · \(included.count) 个参与帧平均", width: Int(frame.width),
                height: Int(frame.height), channels: Int(snapshot.info.layers), includedFrames: included))
    }
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
