// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func colorCalibrationSelfTest(file: FITSRecord, values: [Float], width: Int, height: Int) async throws -> [ProcessingJob] {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw EngineError.failed("Color calibration: " + message) }
        }
        let source = try Data(contentsOf: file.url)
        let session = NativeToolSession(); try await session.open(file)
        let background = ImageSelection(x: 3, y: 11, width: 9, height: 7)
        let white = ImageSelection(x: 33, y: 35, width: 7, height: 9)
        func samples(_ region: ImageSelection, _ channel: Int) -> [Double] {
            (region.y..<(region.y + region.height)).flatMap { y in
                (region.x..<(region.x + region.width)).map { x in Double(values[channel * width * height + y * width + x]) }
            }
        }
        let bg = (0..<3).map { samples(background, $0).sorted()[background.width * background.height / 2] }
        let means = (0..<3).map { channel in samples(background, channel).reduce(0, +) / Double(background.width * background.height) }
        let reference = bg.reduce(0, +) / 3
        let signal = (0..<3).map { channel in abs(samples(white, channel).reduce(0, +) / Double(white.width * white.height) - bg[channel]) }
        let peak = signal.max()!
        let gains = [0.8, 0.6, 0.4]
        var jobs: [ProcessingJob] = []
        for mode in 0...2 {
            var recipe = NativeToolRecipe(tool: .colorCalibration, file: file)
            recipe.values["operation"] = Double(mode)
            for (prefix, region) in [("background", background), ("white", white)] {
                recipe.values[prefix + "X"] = Double(region.x); recipe.values[prefix + "Y"] = Double(region.y)
                recipe.values[prefix + "Width"] = Double(region.width); recipe.values[prefix + "Height"] = Double(region.height)
            }
            for (key, gain) in zip(["red", "green", "blue"], gains) { recipe.values[key] = gain }
            try await session.compute(recipe, library: [file])
            let job = try prepareNativeToolJob(file: file, recipe: recipe, library: [file]); jobs.append(job)
            let output = try await session.export(recipe, to: job)
            func verify(_ url: URL) throws {
                let data = try Data(contentsOf: url)
                var end = 0
                while end + 80 <= data.count && String(data: data[end..<(end + 8)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) != "END" { end += 80 }
                let start = ((end + 80 + 2879) / 2880) * 2880
                try require(start + width * height * 3 * 4 <= data.count, "truncated output")
                for c in 0..<3 { for row in 0..<height { for x in 0..<width {
                    let offset = start + (c * width * height + row * width + x) * 4
                    let actual = Float(bitPattern: data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                    let value = Double(values[c * width * height + (height - 1 - row) * width + x])
                    let expected = mode == 0 ? value * gains[c] : mode == 1 ? value - Double(Float(means[c] - reference)) : (value - bg[c]) * peak / signal[c] + bg[c]
                    try require(abs(Double(actual) - expected) < 3e-6, "independent full RGB pixels, operation \(mode), channel \(c)")
                } } }
            }
            try verify(output)
            let replay = try run(job)
            guard let replayOutput = replay.first(where: { $0.lastPathComponent == "result.fits" }) else { throw EngineError.failed("Color calibration replay missing") }
            try verify(replayOutput)
            try require(try JSONDecoder().decode(NativeToolRecipe.self, from: Data(contentsOf: job.folder.appendingPathComponent("native-tool.json"))) == recipe, "saved recipe changed")
        }
        for scenario in 0...3 {
            var invalid = NativeToolRecipe(tool: .colorCalibration, file: file)
            invalid.values["operation"] = 2
            if scenario == 0 { invalid.values["backgroundX"] = Double(width) }
            if scenario == 1 { invalid.values["low"] = 0.95; invalid.values["high"] = 1 }
            if scenario == 2 { invalid.values["low"] = 0.9; invalid.values["high"] = 0.1 }
            if scenario == 3 { invalid.mask.values["mode"] = 1 }
            var rejected = false
            do { try await session.compute(invalid, library: [file]) } catch { rejected = true }
            try require(rejected, "accepted invalid region, empty white sample, limits or partial mask: \(scenario)")
        }
        try require(try Data(contentsOf: file.url) == source, "modified source bytes")
        checkpoint("PASS: original color calibration manual coefficients, background mean/median offsets, white-reference gains, independent full RGB pixels, private job replay and invalid/empty selection guards")
        return jobs
    }
}
