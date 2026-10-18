// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func wcsSelfTest() async throws {
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw EngineError.failed("Image WCS: " + message) }
        }
        let source = documents.appendingPathComponent("simulator-wcs-source.fits")
        let missing = documents.appendingPathComponent("wcs-missing-" + UUID().uuidString + ".fits")
        defer { try? FileManager.default.removeItem(at: missing) }
        let analysis = ImageAnalysisEngine()
        for hasWCS in [true, false] {
            var cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    2",
                "NAXIS1  =                  128", "NAXIS2  =                   96"]
            if hasWCS {
                cards += ["CTYPE1  = 'RA---TAN'", "CTYPE2  = 'DEC--TAN'", "CUNIT1  = 'deg'", "CUNIT2  = 'deg'",
                    "RADESYS = 'ICRS'", "CRPIX1  =                   64", "CRPIX2  =                   48",
                    "CRVAL1  =             359.9998", "CRVAL2  =                -20.4", "CD1_1   =                -0.01",
                    "CD1_2   =                0.003", "CD2_1   =                0.002", "CD2_2   =                0.012"]
            }
            cards += ["END"]
            var data = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
                .padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for row in 0..<96 { for x in 0..<128 {
                var value = Float(0.05 + Double(x) / 256 + Double(row) / 512).bitPattern.bigEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            } }
            data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
            let url = hasWCS ? source : missing; try data.write(to: url)
            _ = try await analysis.open(url)
            for (x, y) in [(0, 0), (63, 48), (127, 95), (95, 24)] {
                let reading = try await analysis.pixel(x: x, y: y)
                let raw = Float(0.05 + Double(x) / 256 + Double(95 - y) / 512)
                try require(reading.values.count == 1 && abs(reading.values[0] - raw) < 1e-7, "raw/display pixel changed")
                if hasWCS {
                    guard let sky = reading.sky else { throw EngineError.failed("WCS pixel coordinate missing") }
                    let radians = Double.pi / 180, dec0 = -20.4 * radians
                    let dx = Double(x + 1 - 64), dy = Double(96 - y - 48)
                    let xi = (-0.01 * dx + 0.003 * dy) * radians
                    let eta = (0.002 * dx + 0.012 * dy) * radians
                    let denominator = cos(dec0) - eta * sin(dec0)
                    let ra = (atan2(xi, denominator) / radians + 359.9998 + 360).truncatingRemainder(dividingBy: 360)
                    let dec = atan2(sin(dec0) + eta * cos(dec0), hypot(denominator, xi)) / radians
                    try require(abs(sky.ra - ra) < 1e-9 && abs(sky.dec - dec) < 1e-9, "independent TAN pixel centre or RA wrap")
                    try require(sky.description.contains("图像 WCS") && sky.description.contains("RA"), "coordinate readout format")
                } else { try require(reading.sky == nil, "missing WCS was represented as a valid coordinate") }
            }
            try require(try Data(contentsOf: url) == data, "pixel readout changed source bytes")
        }
    }
}
