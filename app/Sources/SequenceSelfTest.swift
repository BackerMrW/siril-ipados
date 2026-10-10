// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func sequenceSelfTest() async throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw EngineError.failed("Sequence App check: " + message) }
        }
        guard let source = Bundle.main.url(forResource: "light", withExtension: "fits") else { throw EngineError.failed("Sequence fixture missing") }
        let reader = ImageAnalysisEngine()
        func pixels(_ url: URL) async throws -> [Float] {
            _ = try await reader.open(url)
            var values: [Float] = []
            for y in 0..<2 { for x in 0..<2 { values.append(try await reader.pixel(x: x, y: y).values[0]) } }
            return values
        }
        let light = try importFile(source)
        let temporary = documents.appendingPathComponent("sequence-high.fits")
        var bytes = try Data(contentsOf: source)
        // This bundled 2x2 FLOAT_IMG has one header block. Add a known offset
        // in FITS big-endian storage; expected pixels come from a separate read.
        for i in 0..<4 {
            let offset = 2880 + i * 4
            let bits = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var high = (Float(bitPattern: bits) + 0.4).bitPattern.bigEndian
            withUnsafeBytes(of: &high) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        try bytes.write(to: temporary)
        let high = try importFile(temporary)
        defer {
            try? FileManager.default.removeItem(at: light.url)
            try? FileManager.default.removeItem(at: high.url)
            try? FileManager.default.removeItem(at: temporary)
        }
        let baseline = try await pixels(light.url)
        let job = try createSequence(files: [light, light, high])
        defer { try? FileManager.default.removeItem(at: job.folder) }
        guard let location = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Created sequence missing") }
        let before = try inspectSequence(location)
        try require(before.info.count == 3 && before.info.included == 3 && before.info.width == 2 && before.info.layers == 1, "native metadata")
        let preview = try sequencePreview(location, index: 2, automatic: false)
        try require(preview.width == 2 && preview.height == 2 && preview.data.count == 16, "native full-frame preview")
        var options = BatchOptions()
        options.register = false; options.rejection = .none; options.normalization = .none; options.outputNormalization = false
        let all = try stackSequence(location, options: options, layer: 0)
        let alias = documents.appendingPathComponent("sequence-job-parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents.appendingPathComponent("Jobs"))
        defer { try? FileManager.default.removeItem(at: alias) }
        try require(try resultFiles(in: alias.appendingPathComponent(location.job)).contains(all), "sandbox parent alias hid restack results")
        let allBytes = try Data(contentsOf: all)
        let allPixels = try await pixels(all)
        for i in 0..<4 { try require(abs(allPixels[i] - baseline[i] - 0.4 / 3) < 2e-5, "all-frame mean pixel") }
        let selected = SequenceSelection(included: [true, true, false], reference: 0)
        try editSequence(location, selection: selected)
        let subset = try stackSequence(location, options: options, layer: 0)
        let subsetPixels = try await pixels(subset)
        for i in 0..<4 { try require(abs(subsetPixels[i] - baseline[i]) < 2e-5, "excluded high frame still contributed") }
        try require(try Data(contentsOf: all) == allBytes, "restack changed previous result")
        // Recreate the Swift actor to exercise persisted history, not UI state.
        let reopened = SirilEngine()
        try await reopened.editSequence(location, undo: true)
        try require(try await reopened.inspectSequence(location).selection == before.selection, "cross-relaunch undo")
        try await reopened.editSequence(location, redo: true)
        try require(try await reopened.inspectSequence(location).selection == selected, "cross-relaunch redo")
        let processInputs = try FileManager.default.contentsOfDirectory(at: job.folder.appendingPathComponent("process"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "fit" }
        let rawInputs = try FileManager.default.contentsOfDirectory(at: job.folder.appendingPathComponent("lights"), includingPropertiesForKeys: nil)
        try require(processInputs.count == 3 && rawInputs.count == 3, "restack duplicated input frames")
        for run in try FileManager.default.contentsOfDirectory(at: job.folder.appendingPathComponent("SequenceRuns"), includingPropertiesForKeys: nil) {
            let fitNames = try FileManager.default.contentsOfDirectory(atPath: run.path).filter { $0.hasSuffix(".fits") || $0.hasSuffix(".fit") }
            try require(fitNames == ["result.fits"], "restack copied FITS inputs into run")
        }
        let statsCSV = try sequenceStatistics(location)
        try require(try String(contentsOf: statsCSV).contains("mean"), "original statistics CSV missing mean")
        let stats = try inspectSequence(location)
        for frame in stats.frames.prefix(2) {
            try require(frame.native.has_statistics != 0 && abs(frame.native.mean - Double(baseline.reduce(0, +) / 4)) < 2e-5, "native normalized statistics")
        }
        try require(try String(contentsOf: exportSequenceQuality(location, layer: 0)).contains("included,reference"), "quality CSV")
        try editSequence(location, undo: true)
        let branch = SequenceSelection(included: [true, false, true], reference: 2)
        try editSequence(location, selection: branch)
        try require(try sequenceHistory(location, snapshot: inspectSequence(location)).future.isEmpty, "new edit retained redo branch")
        let seq = job.folder.appendingPathComponent("process").appendingPathComponent(location.name)
        let edits = job.folder.appendingPathComponent("SequenceEdits")
        let history = edits.appendingPathComponent(location.name + ".json")
        let journal = edits.appendingPathComponent(location.name + ".journal.json")
        let original = try Data(contentsOf: seq), savedHistory = try Data(contentsOf: history)
        try JSONEncoder().encode(SequenceEditJournal(sequence: original, history: savedHistory)).write(to: journal, options: .atomic)
        try Data("interrupted upstream writer".utf8).write(to: seq, options: .atomic)
        try require(try inspectSequence(location).selection == branch && Data(contentsOf: seq) == original && Data(contentsOf: history) == savedHistory, "interrupted edit recovery")
        try require(!FileManager.default.fileExists(atPath: journal.path), "recovered journal retained")
        activeJobIDs.insert(location.job)
        var protected = false
        do { _ = try inspectSequence(location) } catch { protected = true }
        activeJobIDs.remove(location.job)
        try require(protected, "running task allowed sequence edit")
        var invalid = false
        do { _ = try sequencePreview(location, index: 3) } catch { invalid = true }
        try require(invalid, "invalid frame index accepted")
        let raw = job.folder.appendingPathComponent("process/light_00003.fit")
        let rawPixels = try await pixels(raw)
        for i in 0..<4 { try require(abs(rawPixels[i] - baseline[i] - 0.4) < 2e-5, "exclusion altered original frame") }
        guard let task = jobHistory().first(where: { $0.id == location.job }) else { throw EngineError.failed("Sequence task history missing") }
        try require(task.results.contains(all) && task.results.contains(subset), "restacks absent from task results")
        try trashJob(task)
        guard let deletion = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("Sequence task trash missing") }
        _ = try restoreTrash(deletion.id)
        try require(try inspectSequence(location).selection == branch && Data(contentsOf: all) == allBytes, "task restore lost selection or old result")
        try trashJob(task)
        try permanentlyDeleteTrash(Set(trashEntries().filter { $0.jobName == location.job }.map(\.id)))
        try require(!FileManager.default.fileExists(atPath: seq.path), "permanent task cleanup retained sequence")
    }

    func sequenceRegistrationSelfTest() async throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw EngineError.failed("Sequence registration App check: " + message) }
        }
        var inputs: [FITSRecord] = []
        let originalLibrary = loadLibrary()
        defer {
            try? saveLibrary(originalLibrary)
            for input in inputs { try? FileManager.default.removeItem(at: input.url) }
        }
        for i in 0..<4 {
            guard let url = Bundle.main.url(forResource: "drizzle-bayer-\(i)", withExtension: "fits") else { throw EngineError.failed("Registration fixture missing") }
            inputs.append(try importFile(url))
        }
        guard let flatSource = Bundle.main.url(forResource: "drizzle-flat", withExtension: "fits") else { throw EngineError.failed("Registration flat fixture missing") }
        let flat = try importFile(flatSource, role: .flats); inputs.append(flat)
        try saveLibrary(originalLibrary + inputs)
        let flatBytes = try Data(contentsOf: flat.url)
        let job = try createSequence(files: inputs)
        defer { try? FileManager.default.removeItem(at: job.folder) }
        guard let source = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Registration sequence missing") }
        let process = job.folder.appendingPathComponent("process")
        let sourceURLs = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil).filter { $0.pathExtension == "fit" }
        let sourceBytes = try sourceURLs.map { try Data(contentsOf: $0) }
        let selection = SequenceSelection(included: [true, false, true, true], reference: 2)
        try editSequence(source, selection: selection)
        var options = BatchOptions()
        options.transform = .shift; options.minimumPairs = 4; options.maximumStars = 100
        options.interpolation = .linear; options.scale = 2
        options.rejection = .none; options.normalization = .none; options.outputNormalization = false
        options.drizzleOptions.enabled = false
        try measureSequence(source, options: options, layer: 0)
        try require(try inspectSequence(source).selection == selection, "two-pass analysis overrode explicit reference")
        let measuredBytes = try Data(contentsOf: process.appendingPathComponent(source.name))
        let first = try applySequenceRegistration(source, options: options, layer: 0)
        let metadata = try inspectSequence(first)
        try require(metadata.info.count == 3 && metadata.info.width == 512 && metadata.info.height == 512 && metadata.info.reference == 1, "output dimensions/count/reference mapping: \(metadata.info.width)x\(metadata.info.height), count \(metadata.info.count), reference \(metadata.info.reference)")
        try require(metadata.frames.map { Int($0.native.file_number) } == [1, 3, 4], "excluded middle frame exported")
        let reader = ImageAnalysisEngine()
        func centroid(_ url: URL) async throws -> (Double, Double) {
            let details = try await reader.open(url)
            try require(details.width == 512 && details.height == 512, "actual FITS size")
            var flux = 0.0, xSum = 0.0, ySum = 0.0
            for y in 49..<73 { for x in 51..<76 {
                let value = max(0, Double(try await reader.pixel(x: x, y: y).values[0]) - 0.004)
                flux += value; xSum += Double(x) * value; ySum += Double(y) * value
            } }
            try require(flux > 1, "star disappeared from interpolated output")
            return (xSum / flux, ySum / flux)
        }
        let generatedURLs = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(first.base) && $0.pathExtension == "fit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let preserved = try generatedURLs.map { try Data(contentsOf: $0) }
        var centers: [(Double, Double)] = []
        for url in generatedURLs { centers.append(try await centroid(url)) }
        for center in centers { try require(abs(center.0 - centers[1].0) < 0.8 && abs(center.1 - centers[1].1) < 0.8, "subpixel star alignment") }
        let second = try applySequenceRegistration(source, options: options, layer: 0)
        try require(first != second && sequenceLocations(job: source.job).contains(first) && sequenceLocations(job: source.job).contains(second), "unique outputs missing from browser")
        for (i, url) in generatedURLs.enumerated() { try require(try Data(contentsOf: url) == preserved[i], "reapply overwrote previous FITS") }
        try require(try Data(contentsOf: process.appendingPathComponent(source.name)) == measuredBytes, "application changed source sequence")
        try editSequence(source, selection: SequenceSelection(included: [true, true, true, true], reference: 2))
        var rejected = false
        do { _ = try applySequenceRegistration(source, options: options, layer: 0) } catch { rejected = true }
        try require(rejected, "unmeasured newly included frame accepted")
        try editSequence(source, undo: true)
        try require(try inspectSequence(source).selection == selection, "application broke selection undo")
        options.drizzleOptions.enabled = true; options.drizzleOptions.useFlat = true; options.drizzleOptions.matchWeightBitDepth = true
        let drizzled = try applySequenceRegistration(source, options: options, layer: 0, flat: flat)
        let drizzleInfo = try inspectSequence(drizzled, layer: 1)
        try require(drizzleInfo.info.drizzle != 0 && drizzleInfo.info.layers == 3 && drizzleInfo.info.width == 512 && drizzleInfo.info.count == 3 && drizzleInfo.info.reference == 1, "Bayer Drizzle output metadata")
        let weights = try FileManager.default.contentsOfDirectory(at: process.appendingPathComponent("drizztmp"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(drizzled.base) }
        try require(weights.count == 3, "excluded frame drizzle weight map exported")
        let details = try await reader.open(weights[0])
        try require(details.header.contains("BITPIX  =                  -32"), "matched weight-map precision")
        let weightBytes = try weights.map { try Data(contentsOf: $0) }
        // Independent FITS decoding checks the native weighted stack, rather
        // than comparing generated script text or native statistics caches.
        func floats(_ url: URL) throws -> [Float] {
            let data = try Data(contentsOf: url)
            var end = 0
            while end + 80 <= data.count {
                if String(data: data[end..<(end + 8)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) == "END" { break }
                end += 80
            }
            let start = ((end + 80 + 2879) / 2880) * 2880, count = 512 * 512 * 3
            guard start + count * 4 <= data.count else { throw EngineError.failed("Truncated float FITS fixture") }
            return (0..<count).map { i in
                let offset = start + i * 4
                return Float(bitPattern: data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            }
        }
        let outputURLs = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(drizzled.base) && $0.pathExtension == "fit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let weightURLs = weights.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let outputValues = try outputURLs.map(floats), weightValues = try weightURLs.map(floats)
        let stacked = try stackSequence(drizzled, options: options, layer: 1)
        let actual = try floats(stacked)
        for channel in 0..<3 { for y in 100..<106 { for x in 100..<106 {
            let i = channel * 512 * 512 + y * 512 + x
            var sum = 0.0, weight = 0.0
            for frame in 0..<3 { sum += Double(outputValues[frame][i]) * Double(weightValues[frame][i]); weight += Double(weightValues[frame][i]) }
            try require(weight > 0 && abs(Double(actual[i]) - sum / weight) < 2e-5, "weighted Drizzle stack channel \(channel)")
        } } }
        for (i, url) in sourceURLs.enumerated() { try require(try Data(contentsOf: url) == sourceBytes[i], "application changed source pixels") }
        try require(try Data(contentsOf: flat.url) == flatBytes, "Drizzle altered gallery flat")
        var impossible = options
        impossible.filters = [QualityFilter(enabled: true, metric: .nbstars, limit: .threshold, value: 10000)]
        rejected = false
        do { _ = try applySequenceRegistration(source, options: impossible, layer: 0, flat: flat) } catch { rejected = true }
        try require(rejected, "zero-output native filtering reported success")
        guard let task = jobHistory().first(where: { $0.id == source.job }) else { throw EngineError.failed("Registration task missing") }
        try trashJob(task)
        guard let deletion = trashEntries().first(where: { $0.jobName == source.job }) else { throw EngineError.failed("Registration trash missing") }
        _ = try restoreTrash(deletion.id)
        try require(try inspectSequence(drizzled, layer: 1).info.count == 3, "restored output sequence missing")
        for (i, url) in weights.enumerated() { try require(try Data(contentsOf: url) == weightBytes[i], "restored weight bytes changed") }
        try trashJob(task)
        try permanentlyDeleteTrash(Set(trashEntries().filter { $0.jobName == source.job }.map(\.id)))
        try require(!FileManager.default.fileExists(atPath: process.path) && FileManager.default.fileExists(atPath: flat.url.path), "permanent cleanup retained outputs or deleted gallery master")
    }

    func makeSequenceDemo() throws {
        var files: [FITSRecord] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file.url) } }
        for i in 0..<4 {
            guard let source = Bundle.main.url(forResource: "drizzle-bayer-\(i)", withExtension: "fits") else { throw EngineError.failed("Sequence quality fixture missing") }
            files.append(try importFile(source))
        }
        let job = try createSequence(files: files)
        guard let location = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Sequence demo missing") }
        try editSequence(location, selection: SequenceSelection(included: [true, true, true, true], reference: 0))
        var options = BatchOptions(); options.transform = .shift; options.minimumPairs = 4; options.maximumStars = 100
        try measureSequence(location, options: options, layer: 0)
        let measured = try inspectSequence(location)
        guard measured.frames.allSatisfy({ $0.native.fwhm > 0 && $0.native.stars > 0 }) else { throw EngineError.failed("Actual sequence quality missing") }
        try editSequence(location, selection: SequenceSelection(included: [true, true, true, false], reference: 0))
        try JSONEncoder().encode(location).write(to: documents.appendingPathComponent("simulator-sequence-location.json"), options: .atomic)
    }
}
