// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func serSequenceSelfTest() throws {
        let fm = FileManager.default
        let folder = documents.appendingPathComponent("ser-sequence-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Native SER sequence: " + message) }
        }
        for name in ["ser-mono8", "ser-cfa16", "ser-rgb8", "ser-bgr16be"] {
            guard let asset = Bundle.main.url(forResource: name, withExtension: "ser") else { throw EngineError.failed("SER fixture missing") }
            let original = try Data(contentsOf: asset)
            let location = try importSERSequence(asset), process = try sequenceFolder(location)
            defer { try? fm.removeItem(at: process.deletingLastPathComponent()) }
            let snapshot = try inspectSequence(location)
            let state = try JSONDecoder().decode(JobState.self, from: Data(contentsOf: process.deletingLastPathComponent().appendingPathComponent("job.json")))
            try require(snapshot.info.count == 3 && state.inputCount == 3 &&
                !(try fm.contentsOfDirectory(atPath: process.path)).contains(where: { $0.hasSuffix(".fits") }),
                "container was expanded to FITS or indexed with the wrong count")
            for frame in 0..<3 {
                var error = [CChar](repeating: 0, count: 512); let capacity = error.count
                let image = process.path.withCString { directory in location.name.withCString {
                    siril_sequence_frame(directory, $0, Int32(frame), &error, capacity)
                } }
                guard let image else { throw EngineError.failed(String(cString: error)) }
                var values = [Float](repeating: 0, count: 3)
                let channels = Int(siril_image_pixel(image, 3, 4, &values))
                siril_image_free(image)
                let rgb = name.contains("rgb") || name.contains("bgr")
                try require(channels == (rgb ? 3 : 1), "native frame channel count")
                for channel in 0..<channels {
                    let expected = name.hasSuffix("8") ? Float(25 + channel * 40 + frame * 10) / 255 : Float(1035 + channel * 100 + frame * 20) / 65535
                    try require(abs(values[channel] - expected) < 1e-7, "actual container pixels/orientation/byte order")
                }
            }
            try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 2))
            let selected = try inspectSequence(location)
            try require(selected.info.included == 2 && selected.info.reference == 2, "SER selection/reference persistence")
            try editSequence(location, undo: true)
            try require(try Data(contentsOf: process.appendingPathComponent("capture.ser")) == original && Data(contentsOf: asset) == original,
                "selection or frame reads changed the copied/original container")
            if name == "ser-mono8" {
                guard let job = jobHistory().first(where: { $0.id == location.job }) else { throw EngineError.failed("SER job missing") }
                try trashJob(job)
                guard let entry = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("SER trash missing") }
                _ = try restoreTrash(entry.id)
                try require(try inspectSequence(location).info.count == 3 && Data(contentsOf: process.appendingPathComponent("capture.ser")) == original,
                    "whole SER task restore lost the container/index")
            }
        }
        guard let broken = Bundle.main.url(forResource: "ser-truncated", withExtension: "ser") else { throw EngineError.failed("SER invalid fixture missing") }
        let before = Set(jobHistory().map(\.id))
        var rejected = false
        do { _ = try importSERSequence(broken) } catch { rejected = true }
        try require(rejected && Set(jobHistory().map(\.id)) == before, "truncated container succeeded or left a task")
        for cfa in [false, true] {
            var data = Data("LUCAM-RECORDER".utf8)
            let fields: [UInt32] = [0, cfa ? 8 : 0, 0, 256, 256, cfa ? 16 : 8, 3]
            for field in fields {
                var value = field.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: repeatElement(UInt8(0), count: 136))
            try require(data.count == 178, "synthetic SER header")
            for _ in 0..<3 { for y in 0..<256 { for x in 0..<256 {
                let disc = hypot(Double(x) - 127.5, Double(y) - 127.5) < 104
                if cfa {
                    let intensity = y % 2 == 0 ? (x % 2 == 0 ? 40000 : 20000) : (x % 2 == 0 ? 20000 : 10000)
                    var value = UInt16(disc ? intensity : 0).littleEndian
                    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
                } else { data.append(disc ? 100 : 0) }
            } } }
            let path = folder.appendingPathComponent(cfa ? "cfa16.ser" : "mono8.ser")
            try data.write(to: path)
            if !cfa {
                let link = folder.appendingPathComponent("linked.ser")
                try fm.createSymbolicLink(at: link, withDestinationURL: path)
                let linked = try importSERSequence(link), linkedProcess = try sequenceFolder(linked)
                defer { try? fm.removeItem(at: linkedProcess.deletingLastPathComponent()) }
                let copied = linkedProcess.appendingPathComponent("capture.ser")
                let attributes = try fm.attributesOfItem(atPath: copied.path)
                try require(attributes[.type] as? FileAttributeType == .typeRegular && (try Data(contentsOf: copied)) == data,
                    "selected link must become an independent regular container copy")
            }
            let location = try importSERSequence(path), process = try sequenceFolder(location)
            defer { try? fm.removeItem(at: process.deletingLastPathComponent()) }
            try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 0))
            for debayer in (cfa ? [7, 8] : [7]) {
                var settings = SequenceMultipointSettings()
                settings.halfBox = 16; settings.search = 4; settings.structure = 0
                settings.normalize = false; settings.refine = false; settings.dewarp = false
                settings.smoothRadius = 0; settings.floatOutput = true
                var advanced = SequenceMultipointAdvanced(); advanced.debayer = debayer; settings.advanced = advanced
                let output = try stackMultipoint(location, settings: settings)
                var error = [CChar](repeating: 0, count: 512); let capacity = error.count
                guard let image = output.path.withCString({ siril_image_read($0, &error, capacity) }) else { throw EngineError.failed(String(cString: error)) }
                var info = SirilImageInfo(), worst: Float = 0
                let infoOK = siril_image_info(image, &info)
                for y in 116..<140 { for x in 116..<140 {
                    var values = [Float](repeating: 0, count: 3)
                    let channels = Int(siril_image_pixel(image, Int32(x), Int32(y), &values))
                    if channels != (cfa ? 3 : 1) { worst = 1 }
                    for channel in 0..<channels {
                        let expected: Float = cfa ? Float([40000, 20000, 10000][channel]) / 65535 : 100.0 / 255
                        worst = max(worst, abs(values[channel] - expected))
                    }
                } }
                siril_image_free(image)
                try require(infoOK != 0 && info.width == 256 && info.height == 256 && worst < 4.0 / 65535,
                    "MPP native SER bit depth/CFA colors, cfa=\(cfa), debayer=\(debayer), error=\(worst), geometry=\(info.width)x\(info.height)")
                if cfa {
                    let sidecar = output.deletingLastPathComponent().appendingPathComponent("analysis.mpp")
                    guard let analysis = sidecar.path.withCString({ siril_multipoint_open($0, &error, capacity) }) else {
                        throw EngineError.failed(String(cString: error))
                    }
                    let reference = siril_multipoint_reference(analysis, &error, capacity)
                    siril_multipoint_close(analysis)
                    guard let reference else { throw EngineError.failed(String(cString: error)) }
                    var luminanceError: Float = 0
                    // Independent RGB luminance of the constant RGGB centre.
                    let expected: Float = (0.299 * 40000 + 0.587 * 20000 + 0.114 * 10000) / 65535
                    for y in 116..<140 { for x in 116..<140 {
                        var values = [Float](repeating: 0, count: 3)
                        if siril_image_pixel(reference, Int32(x), Int32(y), &values) != 1 { luminanceError = 1 }
                        luminanceError = max(luminanceError, abs(values[0] - expected))
                    } }
                    siril_image_free(reference)
                    try require(luminanceError < 4.0 / 65535,
                        "SER CFA analysis Bayer orientation, luminance error=\(luminanceError)")
                }
            }
            try require(try Data(contentsOf: path) == data && Data(contentsOf: process.appendingPathComponent("capture.ser")) == data,
                "MPP changed SER source bytes")
            if cfa {
                let demo = try importSERSequence(path)
                try editSequence(demo, selection: SequenceSelection(included: [true, false, true], reference: 0))
                try JSONEncoder().encode(demo).write(to: documents.appendingPathComponent("simulator-ser-sequence-location.json"), options: .atomic)
            }
        }
    }
}
