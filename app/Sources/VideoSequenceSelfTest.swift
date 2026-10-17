// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func makeVideoSequenceDemo() throws {
        guard let source = Bundle.main.url(forResource: "video-h264", withExtension: "mp4") else {
            throw EngineError.failed("Missing independent MP4 fixture")
        }
        let location = try importVideoSequence(source)
        try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 2))
        try JSONEncoder().encode(location).write(to: documents.appendingPathComponent("simulator-video-sequence-location.json"), options: .atomic)
    }

    func videoSequenceSelfTest() throws {
        let fm = FileManager.default
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Video sequence: " + message) }
        }
        let fixtures = [("video-mono", "avi", false), ("video-rgb", "avi", true),
                        ("video-png", "mov", true), ("video-h264", "mp4", true), ("video-vp9", "webm", true)]
        for (name, ext, rgb) in fixtures {
            guard let source = Bundle.main.url(forResource: name, withExtension: ext) else {
                throw EngineError.failed("Missing independent video fixture: " + name)
            }
            let original = try Data(contentsOf: source)
            let location = try importVideoSequence(source, bayer: name == "video-rgb" ? 2 : 0), process = try sequenceFolder(location)
            let root = process.deletingLastPathComponent()
            defer { try? fm.removeItem(at: root) }
            let snapshot = try inspectSequence(location)
            try require(snapshot.info.count == 3 && snapshot.info.layers == (rgb ? 3 : 1) &&
                snapshot.info.width == 65 && snapshot.info.height == 49, "decoded frame count/shape/channels")
            try require(try !(fm.contentsOfDirectory(atPath: process.path)).contains(where: { $0.hasSuffix(".fits") }),
                "video conversion expanded frames instead of streaming SER")
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            for frame in [2, 0, 1] {
                guard let image = process.path.withCString({ directory in location.name.withCString {
                    siril_sequence_frame(directory, $0, Int32(frame), &error, capacity)
                } }) else { throw EngineError.failed(String(cString: error)) }
                var worst: Float = 0
                var firstMismatch = ""
                for y in 0..<49 { for x in 0..<65 {
                    var values = [Float](repeating: 0, count: 3)
                    let channels = Int(siril_image_pixel(image, Int32(x), Int32(y), &values))
                    if channels != (rgb ? 3 : 1) { worst = 1 }
                    for channel in 0..<channels {
                        let expected = Float(20 + frame * 7 + y * 2 + x % 13 + channel * 35) / 255
                        if firstMismatch.isEmpty && abs(values[channel] - expected) >= 1e-7 {
                            firstMismatch = "frame=\(frame), x=\(x), y=\(y), channel=\(channel), actual=\(values[channel]), expected=\(expected)"
                        }
                        worst = max(worst, abs(values[channel] - expected))
                    }
                } }
                siril_image_free(image)
                try require(worst < 1e-7, "independent video pixels, row padding/orientation/order, fixture=\(name), error=\(worst), \(firstMismatch)")
            }
            try editSequence(location, selection: SequenceSelection(included: [true, false, true], reference: 2))
            try require(try inspectSequence(location).selection == SequenceSelection(included: [true, false, true], reference: 2),
                "video-derived selection/reference")
            try editSequence(location, undo: true)
            let converted = try Data(contentsOf: process.appendingPathComponent("capture.ser"))
            guard let job = jobHistory().first(where: { $0.id == location.job }) else { throw EngineError.failed("Video job missing") }
            try trashJob(job)
            guard let entry = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("Video trash missing") }
            _ = try restoreTrash(entry.id)
            try require(try Data(contentsOf: root.appendingPathComponent("video/capture." + ext)) == original &&
                Data(contentsOf: source) == original && Data(contentsOf: process.appendingPathComponent("capture.ser")) == converted &&
                inspectSequence(location).info.count == 3, "original video/SER/index lost or modified through task restore")
        }
        for (hint, pattern, colorID) in [(2, "RGGB", 8), (3, "BGGR", 11), (4, "GBRG", 10), (5, "GRBG", 9)] {
            guard let source = Bundle.main.url(forResource: "video-cfa-" + pattern.lowercased(), withExtension: "avi") else {
                throw EngineError.failed("Missing independent Bayer AVI fixture")
            }
            let original = try Data(contentsOf: source), location = try importVideoSequence(source, bayer: hint)
            let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
            defer { try? fm.removeItem(at: root) }
            let bytes = try Data(contentsOf: process.appendingPathComponent("capture.ser"))
            try require(Array(bytes[18..<22]) == [UInt8(colorID), 0, 0, 0], "Bayer SER sensor pattern changed after row flip: " + pattern)
            let snapshot = try inspectSequence(location)
            try require(snapshot.info.count == 3 && snapshot.info.layers == 1 && snapshot.info.width == 66 && snapshot.info.height == 50,
                "Bayer video did not retain native mosaic")
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            let mosaic = Array(pattern), levels: [Character: Int] = ["R": 80, "G": 120, "B": 180]
            for frame in [2, 0, 1] {
                guard let image = process.path.withCString({ directory in location.name.withCString {
                    siril_sequence_frame(directory, $0, Int32(frame), &error, capacity)
                } }) else { throw EngineError.failed(String(cString: error)) }
                defer { siril_image_free(image) }
                for y in 0..<50 { for x in 0..<66 {
                    var pixel = [Float](repeating: 0, count: 3)
                    let count = siril_image_pixel(image, Int32(x), Int32(y), &pixel)
                    let expected = Float(levels[mosaic[(y % 2) * 2 + x % 2]]! + frame * 7) / 255
                    try require(count == 1 && abs(pixel[0] - expected) < 1e-7, "Bayer video raw pixel orientation: " + pattern)
                } }
                var stats = [SirilChannelStatistics](repeating: SirilChannelStatistics(), count: 3)
                try require(siril_image_statistics(image, nil, 1, &stats) == 3, "Bayer video channel statistics unavailable")
                for (channel, level) in [80, 120, 180].enumerated() {
                    try require(abs(stats[channel].mean - Double(level + frame * 7) / 255) < 1e-6,
                        "Bayer video red/green/blue channel assignment: " + pattern)
                }
            }
            try require(try Data(contentsOf: source) == original && Data(contentsOf: root.appendingPathComponent("video/capture.avi")) == original &&
                JSONDecoder().decode(Int.self, from: Data(contentsOf: root.appendingPathComponent("video-bayer.json"))) == hint,
                "Bayer video source or persisted sensor setting changed")
        }
        for name in ["video-single", "video-invalid"] {
            guard let source = Bundle.main.url(forResource: name, withExtension: "avi") else { throw EngineError.failed("Missing invalid AVI fixture") }
            let jobs = Set(jobHistory().map(\.id)), bytes = try Data(contentsOf: source)
            var rejected = false
            do { _ = try importVideoSequence(source) } catch { rejected = true }
            try require(rejected && Set(jobHistory().map(\.id)) == jobs && (try Data(contentsOf: source)) == bytes,
                "invalid/single-frame video accepted, changed source or left a task")
        }
        guard let valid = Bundle.main.url(forResource: "bias", withExtension: "fits") else {
            throw EngineError.failed("Missing conversion failure fixture")
        }
        let scratch = documents.appendingPathComponent("conversion-failure-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { siril_release_workspace(); try? fm.removeItem(at: scratch) }
        let original = try Data(contentsOf: valid), broken = Data("not a FITS image".utf8)
        try original.write(to: scratch.appendingPathComponent("a-valid.fits"))
        try broken.write(to: scratch.appendingPathComponent("b-broken.fits"))
        var error = [CChar](repeating: 0, count: 512); let capacity = error.count
        let failed = scratch.path.withCString { directory in "convert partial -ser\n".withCString {
            siril_run_commands(directory, $0, &error, capacity)
        } }
        try require(failed == 0 && Data(contentsOf: scratch.appendingPathComponent("a-valid.fits")) == original &&
            Data(contentsOf: scratch.appendingPathComponent("b-broken.fits")) == broken,
            "partially converted inputs reported success or changed their sources")
    }
}
