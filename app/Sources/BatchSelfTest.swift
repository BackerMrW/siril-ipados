// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func batchSelfTest(files: [FITSRecord]) async throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw EngineError.failed("Advanced batch check: " + message) }
        }
        guard let light = files.first(where: { $0.role == .lights }),
              let dark = files.first(where: { $0.role == .darks }),
              let bias = files.first(where: { $0.role == .biases }),
              let flat = files.first(where: { $0.role == .flats }) else { throw EngineError.failed("Calibration fixtures missing") }
        // Retain original pixel values; compute the independent physical
        // expectation instead of comparing generated strings with themselves.
        let reader = ImageAnalysisEngine()
        func pixels(_ url: URL) async throws -> [Float] {
            _ = try await reader.open(url)
            var values: [Float] = []
            for y in 0..<2 { for x in 0..<2 { values.append(try await reader.pixel(x: x, y: y).values[0]) } }
            return values
        }
        let l = try await pixels(light.url), d = try await pixels(dark.url)
        let b = try await pixels(bias.url), f = try await pixels(flat.url)
        let correctedFlat = zip(f, b).map { $0 - $1 }
        let flatMean = correctedFlat.reduce(0, +) / 4
        let temporary = documents.appendingPathComponent("batch-selftest-dark.fits")
        var bytes = try Data(contentsOf: dark.url)
        var changed = false
        // FITS keyword cards are 80 ASCII bytes; change metadata only.
        for offset in stride(from: 0, to: min(bytes.count, 2880), by: 80) {
            let card = String(decoding: bytes[offset..<(offset + 80)], as: UTF8.self)
            if card.hasPrefix("EXPTIME ") || card.hasPrefix("EXPOSURE") {
                let newCard = "EXPTIME =                  240".padding(toLength: 80, withPad: " ", startingAt: 0)
                bytes.replaceSubrange(offset..<(offset + 80), with: newCard.utf8)
                changed = true
                break
            }
        }
        try require(changed, "fixture exposure header missing")
        try bytes.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let longerDark = try importFile(temporary, role: .darks)
        defer { try? FileManager.default.removeItem(at: longerDark.url) }
        for masterCount in [1, 3] {
            var settings = BatchOptions()
            settings.register = false
            settings.darkOptimization = .exposure
            settings.method = .mean
            settings.rejection = .none
            settings.normalization = .none
            settings.outputNormalization = false
            let batch = [light, light, light] + Array(repeating: longerDark, count: masterCount) +
                Array(repeating: bias, count: masterCount) + [flat, flat, flat]
            let script = try SirilWorkflow.script(files: batch, options: settings)
            let job = try prepareJob(files: batch, script: script, batchOptions: settings)
            let outputs = try run(job)
            guard let result = outputs.first(where: { $0.lastPathComponent == "result.fits" }) else { throw EngineError.failed("Advanced batch result missing") }
            let actual = try await pixels(result)
            for i in 0..<4 {
                let expected = (l[i] - b[i] - 0.5 * (d[i] - b[i])) * flatMean / correctedFlat[i]
                try require(abs(actual[i] - expected) < 2e-5, "exposure scaling/bias subtraction mismatch")
            }
            let saved = try JSONDecoder().decode(BatchOptions.self, from: Data(contentsOf: job.folder.appendingPathComponent("batch-options.json")))
            try require(saved.darkOptimization == .exposure && saved.rejection == .none, "job settings restore")
            let inputs = try JSONDecoder().decode([FITSRecord].self, from: Data(contentsOf: job.folder.appendingPathComponent("inputs.json")))
            try require(inputs.count == batch.count && inputs[3].id == longerDark.id, "job input manifest")
            try FileManager.default.removeItem(at: job.folder)
        }
        var settings = BatchOptions()
        settings.register = false
        settings.method = .median
        settings.outputNormalization = false
        for norm in StackNormalization.allCases {
            settings.normalization = norm
            let job = try prepareJob(files: files, script: SirilWorkflow.script(files: files, options: settings))
            let outputs = try run(job)
            let actual = try await pixels(outputs.first { $0.lastPathComponent == "result.fits" }!)
            for i in 0..<4 {
                let expected = (l[i] - d[i]) * flatMean / correctedFlat[i]
                try require(abs(actual[i] - expected) < 2e-5, "normalization altered identical calibrated exposures")
            }
            try FileManager.default.removeItem(at: job.folder)
        }
        settings.normalization = .none
        // Invalid inputs must be rejected before making a job/copying files.
        do {
            _ = try SirilWorkflow.script(files: [light, light, longerDark], options: settings)
            throw EngineError.failed("Exposure mismatch accepted")
        } catch EngineError.failed(let message) { try require(message != "Exposure mismatch accepted", message) }
        settings.register = true
        settings.transform = .shift
        settings.interpolation = .none
        settings.twoPass = true
        settings.referenceID = light.id
        settings.minimumPairs = 4
        settings.maximumStars = 100
        let decoded = try JSONDecoder().decode(BatchOptions.self, from: JSONEncoder().encode(settings))
        try require(decoded.referenceID == light.id && decoded.twoPass && decoded.interpolation == .none, "advanced settings Codable round-trip")
        settings.scale = 2
        do {
            _ = try SirilWorkflow.script(files: [light, light, light], options: settings)
            throw EngineError.failed("Non-interpolated scaling accepted")
        } catch EngineError.failed(let message) { try require(message != "Non-interpolated scaling accepted", message) }
    }
}
