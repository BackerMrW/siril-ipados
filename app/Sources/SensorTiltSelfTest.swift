// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func sensorTiltSelfTest() async throws {
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw EngineError.failed("Sensor tilt: " + message) }
        }
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("tilt-tests-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [FITSRecord] = []
        defer {
            for record in records { try? fm.removeItem(at: record.url) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func fixture(rgb: Bool, topDown: Bool, blank: Bool = false) throws -> FITSRecord {
            let width = 512, height = 512, channels = rgb ? 3 : 1
            var pixels = [Float](repeating: 0.02, count: width * height * channels)
            if !blank {
                for cy in [40, 210, 302, 472] { for cx in [40, 210, 302, 472] {
                    let quadrant = (cy < 256 ? 0 : 2) + (cx < 256 ? 0 : 1)
                    for channel in 0..<channels {
                        let sigma = rgb && channel != 1 ? (channel == 0 ? 1.25 : 4.0) : 1.5 + Double(quadrant) * 0.5
                        let radius = Int(ceil(sigma * 8))
                        for y in (cy - radius)...(cy + radius) { for x in (cx - radius)...(cx + radius) {
                            let squared = Double((x - cx) * (x - cx) + (y - cy) * (y - cy))
                            pixels[channel * width * height + y * width + x] += Float(0.35 * exp(-squared / (2 * sigma * sigma)))
                        } }
                    }
                } }
            }
            let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32",
                "NAXIS   =                    \(channels == 3 ? 3 : 2)", "NAXIS1  =                  512", "NAXIS2  =                  512"] +
                (rgb ? ["NAXIS3  =                    3"] : []) + ["ROWORDER= '\(topDown ? "TOP-DOWN" : "BOTTOM-UP")'", "END"]
            var data = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
                .padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for channel in 0..<channels { for row in 0..<height { for x in 0..<width {
                let y = topDown ? row : height - 1 - row
                var value = pixels[channel * width * height + y * width + x].bitPattern.bigEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            } } }
            data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
            let url = folder.appendingPathComponent(UUID().uuidString + ".fits"); try data.write(to: url)
            let record = try importFile(url); records.append(record); return record
        }
        let analysis = ImageAnalysisEngine()
        let gaussianFWHM = 2 * sqrt(2 * log(2.0))
        var previous: SensorTiltResult?
        for rgb in [false, true] { for topDown in [false, true] {
            let record = try fixture(rgb: rgb, topDown: topDown)
            let bytes = try Data(contentsOf: record.url)
            _ = try await analysis.open(record.url)
            var settings = StarSettings(); settings.channel = rgb ? 1 : 0; settings.maximum = 2000; settings.radius = 12
            let result = try await analysis.sensorTilt(settings: settings)
            try require(result.stars == 16 && result.channel == settings.channel, "independent Gaussian star count/channel")
            for quadrant in 0..<4 {
                // readfits presents FITS bottom-up regardless of ROWORDER;
                // physically top-down file rows therefore swap displayed zones.
                let storedQuadrant = topDown ? quadrant ^ 2 : quadrant
                let expected = gaussianFWHM * (1.5 + Double(storedQuadrant) * 0.5)
                try require(abs(result.quadrants[quadrant] - expected) < 0.06,
                    "independent Gaussian FWHM / displayed quadrant \(quadrant), RGB=\(rgb), topDown=\(topDown), actual=\(result.quadrants[quadrant]), expected=\(expected)")
            }
            try require(abs(result.mean - gaussianFWHM * 2.25) < 0.06 &&
                abs(result.centre - gaussianFWHM * 2.25) < 0.06 && abs(result.outer - gaussianFWHM * 2.25) < 0.06 &&
                abs(result.difference - gaussianFWHM * 1.5) < 0.1 && result.percent == 67 && abs(result.offAxis) < 0.06,
                "independent tilt, percentage, central/outer zones and off-axis difference")
            if topDown, let previous {
                for i in 0..<4 { try require(abs(result.quadrants[i] - previous.quadrants[i ^ 2]) < 0.02, "FITS storage rows changed the displayed quadrant mapping") }
            }
            previous = result
            let restored = try JSONDecoder().decode(SensorTiltResult.self, from: JSONEncoder().encode(result))
            try require(restored == result, "owned report lost values across JSON round trip")
            if rgb {
                settings.channel = 0
                let red = try await analysis.sensorTilt(settings: settings)
                try require(abs(red.mean - gaussianFWHM * 1.25) < 0.06 && red.difference < 0.06, "green defaults or selected red channel ignored")
            } else if !topDown {
                try bytes.write(to: documents.appendingPathComponent("simulator-tilt-source.fits"), options: .atomic)
            }
            try require(try Data(contentsOf: record.url) == bytes, "analysis modified input FITS bytes")
        } }
        let blank = try fixture(rgb: false, topDown: false, blank: true)
        _ = try await analysis.open(blank.url)
        var failed = false
        do { _ = try await analysis.sensorTilt(settings: StarSettings()) } catch { failed = true }
        try require(failed, "missing stellar zones published a tilt result")
    }
}
