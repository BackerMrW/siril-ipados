// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func drizzleSelfTest() async throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw EngineError.failed("Drizzle App check: " + message) }
        }
        var inputs: [FITSRecord] = []
        defer { for input in inputs { try? FileManager.default.removeItem(at: input.url) } }
        for (name, role) in (0..<4).map({ ("drizzle-bayer-\($0)", FrameRole.lights) }) +
            [("drizzle-flat", .flats), ("drizzle-bias", .biases)] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "fits") else {
                throw EngineError.failed("Drizzle fixture missing: " + name)
            }
            inputs.append(try importFile(url, role: role))
        }
        var options = BatchOptions()
        options.cfa = true
        options.minimumPairs = 4
        options.maximumStars = 100
        options.referenceID = inputs[0].id
        options.transform = .shift
        options.rejection = .none
        options.normalization = .none
        options.outputNormalization = false
        options.drizzleOptions.enabled = true
        options.drizzleOptions.useFlat = true
        let reader = ImageAnalysisEngine()
        for twoPass in [false, true] {
            options.twoPass = twoPass
            options.scale = twoPass ? 2 : 1
            let job = try prepareJob(files: inputs, script: SirilWorkflow.script(files: inputs, options: options), batchOptions: options)
            let outputs = try run(job)
            guard let result = outputs.first(where: { $0.lastPathComponent == "result.fits" }) else {
                throw EngineError.failed("Bayer Drizzle result missing")
            }
            let metadata = try await reader.open(result)
            let side = Int(256 * options.scale)
            try require(metadata.width == side && metadata.height == side && metadata.channels == 3 && !metadata.hasCFA, "RGB output size/Bayer metadata")
            var total = [Float](repeating: 0, count: 3), count = [Int](repeating: 0, count: 3)
            for y in 12..<20 { for x in 12..<20 {
                let pixel = try await reader.pixel(x: Int(Double(x) * options.scale), y: Int(Double(y) * options.scale))
                for c in 0..<3 where pixel.values[c] > 0 { total[c] += pixel.values[c]; count[c] += 1 }
            } }
            for c in 0..<3 {
                let expected = 0.004 * 0.75 * options.scale * options.scale * [1.0, 0.5, 0.25][c]
                try require(count[c] >= 16 && abs(Double(total[c]) / Double(count[c]) - expected) < 4e-5 * options.scale * options.scale, "flat-calibrated color/background photometry channel \(c)")
            }
            let weights = job.folder.appendingPathComponent("process/drizztmp")
            let names = try FileManager.default.contentsOfDirectory(at: weights, includingPropertiesForKeys: nil).filter { $0.pathExtension == "fit" }
            try require(names.count == 4, "four real per-frame weight maps")
            let weightBytes = try Data(contentsOf: names[0])
            guard let task = jobHistory().first(where: { $0.id == job.folder.lastPathComponent }) else {
                throw EngineError.failed("Drizzle job history missing")
            }
            try trashJob(task)
            guard let entry = trashEntries().first(where: { $0.jobName == job.folder.lastPathComponent }) else {
                throw EngineError.failed("Deleted Drizzle task missing")
            }
            _ = try restoreTrash(entry.id)
            try require(try Data(contentsOf: names[0]) == weightBytes, "weight map changed on task delete/restore")
            let saved = try JSONDecoder().decode(BatchOptions.self, from: Data(contentsOf: job.folder.appendingPathComponent("batch-options.json")))
            try require(saved.drizzleOptions.enabled && saved.drizzleOptions.useFlat && saved.twoPass == twoPass, "saved Drizzle configuration")
            try trashJob(task)
            let deletion = trashEntries().filter { $0.jobName == job.folder.lastPathComponent }
            try permanentlyDeleteTrash(Set(deletion.map(\.id)))
            try require(!FileManager.default.fileExists(atPath: weights.path), "weight maps were not permanently removed")
        }
        // Existing 0.7 settings had no Drizzle key. Preserve every old value.
        options.drizzle = nil
        let oldJSON = try JSONEncoder().encode(options)
        let restored = try JSONDecoder().decode(BatchOptions.self, from: oldJSON)
        try require(!restored.drizzleOptions.enabled && restored.referenceID == inputs[0].id && restored.twoPass && restored.scale == 2, "0.7 settings compatibility")
        for invalid in 0..<4 {
            var settings = options
            settings.drizzleOptions.enabled = true
            switch invalid { case 0: settings.debayer = true; case 1: settings.register = false; case 2: settings.drizzleOptions.pixelFraction = .nan; default: settings.drizzleOptions.useFlat = true }
            var rejected = false
            do { _ = try SirilWorkflow.script(files: invalid == 3 ? Array(inputs.prefix(4)) : inputs, options: settings) } catch { rejected = true }
            try require(rejected, "invalid Drizzle configuration \(invalid) accepted")
        }
    }
}
