// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func multipointSelfTest() throws {
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("multipoint-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var imported: [FITSRecord] = []
        defer {
            for input in imported { try? fm.removeItem(at: input.url) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Multipoint: " + message) }
        }
        func expected(_ x: Int, _ y: Int, _ channel: Int) -> UInt16 {
            let dx = Double(x) - 127.5, dy = Double(y) - 127.5
            let distance = sqrt(dx * dx + dy * dy)
            let disc = max(0, min(1, (104 - distance) / 8))
            let texture = 24000 + 6000 * sin(Double(x) / 6) * cos(Double(y) / 7) + 4000 * sin(Double(x + y) / 4)
            return UInt16(max(0, min(65535, disc * texture * (1 - 0.2 * Double(channel)))))
        }
        for channels in [1, 3] {
            var inputs: [FITSRecord] = []
            for frame in 0..<3 {
                var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    \(channels == 1 ? 2 : 3)",
                    "NAXIS1  =                  256", "NAXIS2  =                  256"]
                if channels == 3 { cards.append("NAXIS3  =                    3") }
                cards += ["BZERO   =                32768", "BSCALE  =                    1", "ROWORDER= '\(channels == 1 ? "BOTTOM-UP" : "TOP-DOWN")'", "END"]
                var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
                for channel in 0..<channels { for row in 0..<256 { for x in 0..<256 {
                    // An excluded bright frame must not enter the reference or stack.
                    let value: UInt16 = frame == 1 ? 60000 : expected(x, 255 - row, channel)
                    var encoded = (value ^ 0x8000).bigEndian
                    withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
                } } }
                bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
                let path = folder.appendingPathComponent("\(channels)-\(frame).fits")
                try bytes.write(to: path)
                let input = try importFile(path); imported.append(input); inputs.append(input)
            }
            let job = try createSequence(files: inputs)
            defer { try? fm.removeItem(at: job.folder) }
            guard let source = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Multipoint source sequence missing") }
            try editSequence(source, selection: SequenceSelection(included: [true, false, true], reference: 0))
            let process = try sequenceFolder(source), metadata = try Data(contentsOf: process.appendingPathComponent(source.name))
            let sourceBytes = try inputs.map { try Data(contentsOf: $0.url) }
            var settings = SequenceMultipointSettings()
            settings.planet = channels == 1; settings.halfBox = 16; settings.search = 4
            settings.structure = 0; settings.normalize = false; settings.refine = false
            settings.dewarp = false; settings.smoothRadius = 0; settings.floatOutput = true
            let result = try stackMultipoint(source, settings: settings)
            let summary = try JSONDecoder().decode(SequenceMultipointSummary.self, from: Data(contentsOf: result.deletingLastPathComponent().appendingPathComponent("multipoint-summary.json")))
            try require(summary.frames == 3 && summary.included == 2 && summary.points > 0 && summary.stackSize == 2,
                "original AP/frame counts and selected-frame ranking")
            try require(fm.fileExists(atPath: result.deletingLastPathComponent().appendingPathComponent("analysis.mpp").path), "missing independently saved analysis")
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            guard let image = result.path.withCString({ siril_image_read($0, &error, capacity) }) else { throw EngineError.failed(String(cString: error)) }
            var info = SirilImageInfo()
            try require(siril_image_info(image, &info) != 0 && info.width == 256 && info.height == 256 && info.channels == channels,
                "identity stack geometry and channels")
            var worst: Float = 0
            for y in 0..<256 { for x in 0..<256 {
                var pixel = [Float](repeating: 0, count: 3)
                if siril_image_pixel(image, Int32(x), Int32(y), &pixel) != channels { worst = 1 }
                for channel in 0..<channels {
                    worst = max(worst, abs(pixel[channel] - Float(expected(x, y, channel)) / 65535))
                }
            } }
            siril_image_free(image)
            try require(worst < 4.0 / 65535, "independent identical-frame pixels, channels=\(channels), error=\(worst)")
            if channels == 3 {
                var local = settings; local.dewarp = true
                let warped = try stackMultipoint(source, settings: local)
                guard let aligned = warped.path.withCString({ siril_image_read($0, &error, capacity) }) else { throw EngineError.failed(String(cString: error)) }
                var alignedInfo = SirilImageInfo()
                try require(siril_image_info(aligned, &alignedInfo) != 0 && alignedInfo.channels == 3 &&
                    alignedInfo.width > 200 && alignedInfo.width <= 256 && alignedInfo.height > 200 && alignedInfo.height <= 256,
                    "original locally aligned common-area geometry")
                var colorError: Float = 0, peak: Float = 0
                for y in 0..<Int(alignedInfo.height) { for x in 0..<Int(alignedInfo.width) {
                    var pixel = [Float](repeating: 0, count: 3)
                    if siril_image_pixel(aligned, Int32(x), Int32(y), &pixel) != 3 { colorError = 1 }
                    peak = max(peak, pixel[0])
                    colorError = max(colorError, max(abs(pixel[1] - 0.8 * pixel[0]), abs(pixel[2] - 0.6 * pixel[0])))
                } }
                siril_image_free(aligned)
                try require(peak > 0.3 && colorError < 4.0 / 65535,
                    "independent RGB linearity under original local warps and excluded bright-frame isolation, error=\(colorError)")
            }
            try require(try Data(contentsOf: process.appendingPathComponent(source.name)) == metadata, "changed source sequence metadata")
            for (i, input) in inputs.enumerated() { try require(try Data(contentsOf: input.url) == sourceBytes[i], "changed source FITS pixels") }
            var invalid = settings; invalid.stackPercent = 101
            var rejected = false
            do { _ = try stackMultipoint(source, settings: invalid) } catch { rejected = true }
            try require(rejected, "invalid frame selection accepted")
        }
    }
}
