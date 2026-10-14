// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

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
        for mode in NativeDisplayMode.allCases {
            var display = NativeDisplaySettings(); display.mode = mode
            let rendered = try sequencePreview(location, index: 2, settings: display)
            try require(rendered.width == preview.width && rendered.height == preview.height, "Shared sequence display changed frame geometry")
        }
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
        let keywordSourcePaths = try sequenceFilePaths(location)
        let keywordSourceBytes = try keywordSourcePaths.map { try Data(contentsOf: sequenceKeywordSource($0, under: job.folder)) }
        let outsideFrame = job.folder.appendingPathComponent("process/keyword-outside.fit")
        try FileManager.default.createSymbolicLink(at: outsideFrame, withDestinationURL: light.url)
        var outsideRejected = false
        do { _ = try sequenceKeywordSource("process/keyword-outside.fit", under: job.folder) } catch { outsideRejected = true }
        try FileManager.default.removeItem(at: outsideFrame)
        try require(outsideRejected, "keyword copy followed a frame link outside its source job")
        var keywordEdit = FITSKeywordEdit(); keywordEdit.key = "OBJECT"; keywordEdit.value = "O'Brien sequence"
        let keywordOutput = try editSequenceFITSKeywords(location, edit: keywordEdit)
        let keywordJob = try sequenceFolder(keywordOutput).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: keywordJob) }
        try require(try inspectSequence(keywordOutput).selection == branch, "keyword output lost selection/reference")
        let keywordRecipe = try JSONDecoder().decode(FITSKeywordEdit.self, from: Data(contentsOf: keywordJob.appendingPathComponent("keywords.json")))
        try require(keywordRecipe == keywordEdit, "keyword sequence recipe not saved")
        let keywordPaths = try sequenceFilePaths(keywordOutput)
        for i in 0..<3 {
            let url = try sequenceTrashPath(keywordPaths[i + 1], under: keywordJob)
            let metadata = try await reader.open(url)
            try require(branch.included[i] ? metadata.object == keywordEdit.value : metadata.object != keywordEdit.value, "keyword edit ignored frame selection")
            let originalURL = try sequenceKeywordSource(keywordSourcePaths[i + 1], under: job.folder)
            let outputPixels = try await pixels(url), inputPixels = try await pixels(originalURL)
            try require(outputPixels == inputPixels, "keyword sequence changed pixels")
        }
        for (i, path) in keywordSourcePaths.enumerated() {
            try require(try Data(contentsOf: sequenceKeywordSource(path, under: job.folder)) == keywordSourceBytes[i], "keyword sequence changed source file bytes")
        }
        keywordEdit.action = .delete; keywordEdit.key = "NOEXIST"
        var keywordFailed = false
        do { _ = try editSequenceFITSKeywords(location, edit: keywordEdit) } catch { keywordFailed = true }
        try require(keywordFailed, "failed original keyword worker reported success")
        let keywordFailures = jobHistory().filter { $0.info.state == "编辑失败或取消" }
        for failed in keywordFailures {
            let root = documents.appendingPathComponent("Jobs").appendingPathComponent(failed.id)
            try require(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("process").path).isEmpty, "failed keyword job retained partial sequence")
        }
        let containerJob = try prepareJob(files: [], script: "# Independent FITSEQ App fixture\n")
        defer { try? FileManager.default.removeItem(at: containerJob.folder) }
        let sourceFITS = try Data(contentsOf: source)
        try require(sourceFITS.count == 5760, "independent FITSEQ fixture expects one header and data block")
        var container = sourceFITS
        let cards = ["XTENSION= 'IMAGE   '", "BITPIX  =                  -32", "NAXIS   =                    2", "NAXIS1  =                    2",
                     "NAXIS2  =                    2", "PCOUNT  =                    0", "GCOUNT  =                    1", "END"]
        let header = cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0)
        for _ in 0..<2 { container.append(Data(header.utf8)); container.append(sourceFITS[2880..<5760]) }
        let containerProcess = containerJob.folder.appendingPathComponent("process")
        try container.write(to: containerProcess.appendingPathComponent("keyword_multi.fit"))
        var containerError = [CChar](repeating: 0, count: 512); let errorCapacity = containerError.count
        try require(containerProcess.path.withCString { siril_sequence_discover($0, &containerError, errorCapacity) } != 0, "independent FITSEQ discovery")
        let containerLocation = SequenceLocation(job: containerJob.folder.lastPathComponent, name: "keyword_multi.seq")
        try editSequence(containerLocation, selection: selected)
        keywordEdit.action = .set; keywordEdit.key = "OBJECT"; keywordEdit.value = "Private FITSEQ"
        let editedContainer = try editSequenceFITSKeywords(containerLocation, edit: keywordEdit)
        let editedContainerProcess = try sequenceFolder(editedContainer)
        defer { try? FileManager.default.removeItem(at: editedContainerProcess.deletingLastPathComponent()) }
        try require(try inspectSequence(editedContainer).selection == selected, "FITSEQ output lost reference or excluded HDU")
        try require(try Data(contentsOf: containerProcess.appendingPathComponent("keyword_multi.fit")) == container, "FITSEQ editing changed source container bytes")
        var frameError = [CChar](repeating: 0, count: 512)
        for i in 0..<3 {
            guard let frame = editedContainerProcess.path.withCString({ directory in editedContainer.name.withCString { siril_sequence_frame(directory, $0, Int32(i), &frameError, errorCapacity) } }) else {
                throw EngineError.failed("Edited FITSEQ frame unavailable")
            }
            defer { siril_image_free(frame) }
            var info = SirilImageInfo(); try require(siril_image_info(frame, &info) != 0, "FITSEQ metadata")
            let object = withUnsafePointer(to: &info.object) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            try require(selected.included[i] ? object == keywordEdit.value : object != keywordEdit.value, "FITSEQ worker edited excluded HDU")
            for y in 0..<2 { for x in 0..<2 {
                var pixel: [Float] = [0, 0, 0]
                try require(siril_image_pixel(frame, Int32(x), Int32(y), &pixel) == 1 && pixel[0] == baseline[y * 2 + x], "FITSEQ worker changed float pixels")
            } }
        }
        let cropInputPaths = try sequenceFilePaths(location)
        let cropInputBytes = try cropInputPaths.map { try Data(contentsOf: sequenceKeywordSource($0, under: job.folder)) }
        let cropArea = ImageSelection(x: 1, y: 0, width: 1, height: 2)
        let cropped = try cropSequence(location, region: cropArea)
        let croppedInfo = try inspectSequence(cropped)
        try require(croppedInfo.info.count == 2 && croppedInfo.info.width == 1 && croppedInfo.info.height == 2 && croppedInfo.info.reference == 1,
            "selected sequence crop dimensions/count/reference")
        try require(croppedInfo.frames.map({ $0.native.file_number }) == [1, 3], "crop exported an excluded frame or changed original numbers")
        var cropError = [CChar](repeating: 0, count: 512); let cropCapacity = cropError.count
        for frame in croppedInfo.frames {
            guard let image = job.folder.appendingPathComponent("process").path.withCString({ directory in cropped.name.withCString {
                siril_sequence_frame(directory, $0, Int32(frame.id), &cropError, cropCapacity)
            } }) else { throw EngineError.failed("Cropped frame unavailable") }
            defer { siril_image_free(image) }
            for y in 0..<2 {
                var pixel: [Float] = [0, 0, 0]
                try require(siril_image_pixel(image, 0, Int32(y), &pixel) == 1 &&
                    abs(pixel[0] - baseline[y * 2 + 1] - (frame.native.file_number == 3 ? 0.4 : 0)) < 2e-5, "crop changed independent selected pixels")
            }
        }
        for (i, path) in cropInputPaths.enumerated() {
            try require(try Data(contentsOf: sequenceKeywordSource(path, under: job.folder)) == cropInputBytes[i], "crop changed source bytes or flags")
        }
        var cropRejected = false
        do { _ = try cropSequence(location, region: ImageSelection(x: Int.max, y: 0, width: 1, height: 2)) } catch { cropRejected = true }
        try require(cropRejected, "invalid crop coordinates accepted or overflowed")
        let cropStatus = try recordSequenceResult(entry: location, source: location, output: cropped)
        try require(cropStatus.history.current == cropped && cropStatus.canUndo, "crop missing from sequence result history")
        let cropUndo = try replaySequenceResult(location, redo: false)
        try require(cropUndo.history.current == location, "crop result undo lost source sequence")
        let cropRedo = try replaySequenceResult(location, redo: true)
        try require(cropRedo.history.current == cropped, "crop result redo lost saved output")
        _ = try replaySequenceResult(location, redo: false)
        var failureSelection = branch; failureSelection.reference = 0
        try editSequence(location, selection: failureSelection)
        let process = job.folder.appendingPathComponent("process"), runs = job.folder.appendingPathComponent("SequenceRuns")
        let priorCropRuns = Set(try FileManager.default.contentsOfDirectory(atPath: runs.path))
        let missingFrame = process.appendingPathComponent("light_00003.fit"), withheldFrame = process.appendingPathComponent("crop-withheld.fit")
        try FileManager.default.moveItem(at: missingFrame, to: withheldFrame)
        cropRejected = false
        do { _ = try cropSequence(location, region: cropArea) } catch { cropRejected = true }
        try FileManager.default.moveItem(at: withheldFrame, to: missingFrame)
        try editSequence(location, selection: branch)
        let failedRunNames = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter { !priorCropRuns.contains($0) }
        try require(cropRejected && failedRunNames.count == 1, "missing-frame crop did not create a failed run")
        let failedCropFolder = runs.appendingPathComponent(failedRunNames[0])
        let failedCropState = try JSONDecoder().decode(JobState.self, from: Data(contentsOf: failedCropFolder.appendingPathComponent("job.json")))
        let failedCropPrefix = "r_" + failedRunNames[0].replacingOccurrences(of: "-", with: "") + "_"
        try require(failedCropState.state == "裁剪失败或取消" && FileManager.default.fileExists(atPath: failedCropFolder.appendingPathComponent("crop.json").path) &&
            (try FileManager.default.contentsOfDirectory(atPath: process.path)).allSatisfy({ !$0.hasPrefix(failedCropPrefix) }), "failed crop retained partial output or lost its recipe")
        let croppedContainer = try cropSequence(containerLocation, region: cropArea)
        let croppedContainerInfo = try inspectSequence(croppedContainer)
        try require(croppedContainerInfo.info.count == 2 && croppedContainerInfo.info.width == 1 && croppedContainerInfo.info.height == 2 && croppedContainerInfo.info.reference == 0,
            "FITSEQ crop lost selected HDUs/dimensions/reference")
        for frame in croppedContainerInfo.frames {
            guard let image = containerProcess.path.withCString({ directory in croppedContainer.name.withCString {
                siril_sequence_frame(directory, $0, Int32(frame.id), &cropError, cropCapacity)
            } }) else { throw EngineError.failed("Cropped FITSEQ HDU unavailable") }
            defer { siril_image_free(image) }
            for y in 0..<2 {
                var pixel: [Float] = [0, 0, 0]
                try require(siril_image_pixel(image, 0, Int32(y), &pixel) == 1 && abs(pixel[0] - baseline[y * 2 + 1]) < 2e-5, "FITSEQ crop changed independent float pixels")
            }
        }
        try require(try Data(contentsOf: containerProcess.appendingPathComponent("keyword_multi.fit")) == container, "FITSEQ crop changed input container bytes")
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
        let measuredSnapshot = try inspectSequence(source)
        var registrationKeyword = FITSKeywordEdit(); registrationKeyword.key = "OBJECT"; registrationKeyword.value = "Registered sequence"
        let keywordSequence = try editSequenceFITSKeywords(source, edit: registrationKeyword)
        let keywordJob = try sequenceFolder(keywordSequence).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: keywordJob) }
        let retained = try inspectSequence(keywordSequence)
        try require(retained.selection == selection && retained.frames.count == measuredSnapshot.frames.count, "keyword editor changed registered sequence selection")
        for (before, after) in zip(measuredSnapshot.frames, retained.frames) {
            try require(before.native.file_number == after.native.file_number && before.native.has_registration == after.native.has_registration &&
                before.native.fwhm == after.native.fwhm && before.native.translation_x == after.native.translation_x && before.native.translation_y == after.native.translation_y,
                "keyword editor lost native registration measurements")
        }
        try require(try Data(contentsOf: process.appendingPathComponent(source.name)) == measuredBytes, "keyword editor changed source registration file")
        let first = try applySequenceRegistration(source, options: options, layer: 0)
        let metadata = try inspectSequence(first)
        try require(metadata.info.count == 3 && metadata.info.width == 512 && metadata.info.height == 512 && metadata.info.reference == 1, "output dimensions/count/reference mapping: \(metadata.info.width)x\(metadata.info.height), count \(metadata.info.count), reference \(metadata.info.reference)")
        try require(metadata.frames.map { Int($0.native.file_number) } == [1, 3, 4], "excluded middle frame exported")
        let reader = ImageAnalysisEngine()
        func floats(_ url: URL, channels: Int = 3, width: Int = 512, height: Int = 512) throws -> [Float] {
            let data = try Data(contentsOf: url)
            var end = 0
            while end + 80 <= data.count {
                if String(data: data[end..<(end + 8)], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) == "END" { break }
                end += 80
            }
            let start = ((end + 80 + 2879) / 2880) * 2880, count = width * height * channels
            guard start + count * 4 <= data.count else { throw EngineError.failed("Truncated float FITS fixture") }
            return (0..<count).map { i in
                let offset = start + i * 4
                return Float(bitPattern: data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            }
        }
        func centroid(_ url: URL) async throws -> (Double, Double) {
            let details = try await reader.open(url)
            try require(details.width == 512 && details.height == 512, "actual FITS size")
            // Locate the fixture's uniquely brightest star from the stored
            // pixels. Registration can change FITS row orientation; do not
            // assume a top-down display coordinate for a raw data plane.
            let values = try floats(url, channels: 1)
            guard let peak = values.indices.max(by: { values[$0] < values[$1] }) else { throw EngineError.failed("Empty registration output") }
            let peakX = peak % 512, peakY = peak / 512
            try require(abs(peakX - 63) <= 5 && peakY > 12 && peakY < 500, "scaled brightest-star position: \(peakX),\(peakY)")
            var flux = 0.0, xSum = 0.0, ySum = 0.0
            for y in (peakY - 12)..<(peakY + 13) { for x in (peakX - 12)..<(peakX + 13) {
                let value = max(0, Double(values[y * 512 + x]) - 0.004)
                flux += value; xSum += Double(x) * value; ySum += Double(y) * value
            } }
            try require(flux > 1, "star disappeared from interpolated output: flux \(flux)")
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

        let outputURLs = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(drizzled.base) && $0.pathExtension == "fit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let weightURLs = weights.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let preservedDrizzleBytes = try outputURLs.map { try Data(contentsOf: $0) }
        let preservedCropWeightBytes = try weightURLs.map { try Data(contentsOf: $0) }
        let outputValues = try outputURLs.map { try floats($0) }, weightValues = try weightURLs.map { try floats($0) }
        let drizzleSequenceBytes = try Data(contentsOf: process.appendingPathComponent(drizzled.name))
        try editSequence(drizzled, selection: SequenceSelection(included: [true, false, true], reference: 2))
        let cropArea = ImageSelection(x: 93, y: 87, width: 37, height: 29)
        let croppedDrizzle = try cropSequence(drizzled, region: cropArea)
        let cropInfo = try inspectSequence(croppedDrizzle, layer: 1)
        try require(cropInfo.info.drizzle != 0 && cropInfo.info.width == 37 && cropInfo.info.height == 29 &&
            cropInfo.info.count == 2 && cropInfo.info.reference == 1 && cropInfo.frames.map { $0.native.file_number } == [1, 4], "cropped Drizzle metadata/selection/reference")
        let croppedImages = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(croppedDrizzle.base) && $0.pathExtension == "fit" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let croppedWeights = try FileManager.default.contentsOfDirectory(at: process.appendingPathComponent("drizztmp"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(croppedDrizzle.base) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try require(croppedImages.count == 2 && croppedWeights.count == 2, "cropped Drizzle excluded-frame files")
        let croppedPixels = try croppedImages.map { try floats($0, width: 37, height: 29) }
        let croppedCounts = try croppedWeights.map { try floats($0, width: 37, height: 29) }
        for (out, input) in [0, 2].enumerated() {
            for channel in 0..<3 { for y in 0..<29 { for x in 0..<37 {
                let sourceIndex = channel * 512 * 512 + (512 - cropArea.y - 29 + y) * 512 + cropArea.x + x
                let target = channel * 37 * 29 + y * 37 + x
                try require(croppedPixels[out][target] == outputValues[input][sourceIndex] && croppedCounts[out][target] == weightValues[input][sourceIndex], "Drizzle crop independent pixel/weight geometry")
            } } }
        }
        let croppedStack = try stackSequence(croppedDrizzle, options: options, layer: 1)
        let croppedStackPixels = try floats(croppedStack, width: 37, height: 29)
        var coveredCrop = 0
        for i in croppedStackPixels.indices {
            let weight = Double(croppedCounts[0][i]) + Double(croppedCounts[1][i])
            let expected = weight > 0 ? (Double(croppedPixels[0][i]) * Double(croppedCounts[0][i]) + Double(croppedPixels[1][i]) * Double(croppedCounts[1][i])) / weight : 0
            try require(abs(Double(croppedStackPixels[i]) - expected) < 2e-5, "cropped Drizzle independent weighted stack")
            if weight > 0 { coveredCrop += 1 }
        }
        try require(coveredCrop > 100, "cropped Drizzle fixture has no weighted coverage")
        let withheldWeight = process.appendingPathComponent("drizztmp/withheld-crop-weight.fit")
        let runs = process.deletingLastPathComponent().appendingPathComponent("SequenceRuns")
        let previousRuns = Set(try FileManager.default.contentsOfDirectory(atPath: runs.path))
        try FileManager.default.moveItem(at: weightURLs[2], to: withheldWeight)
        var cropRejected = false
        do { _ = try cropSequence(drizzled, region: cropArea) } catch { cropRejected = true }
        try FileManager.default.moveItem(at: withheldWeight, to: weightURLs[2])
        try require(cropRejected, "missing Drizzle weight accepted")
        let failedRuns = Set(try FileManager.default.contentsOfDirectory(atPath: runs.path)).subtracting(previousRuns)
        try require(failedRuns.count == 1, "missing-weight crop has no retained run")
        for id in failedRuns {
            let prefix = "r_" + id.replacingOccurrences(of: "-", with: "") + "_"
            for directory in [process, process.appendingPathComponent("drizztmp")] {
                try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(prefix) }, "missing-weight crop left partial output")
            }
        }
        try editSequence(drizzled, undo: true)
        try require(try Data(contentsOf: process.appendingPathComponent(drizzled.name)) == drizzleSequenceBytes, "Drizzle crop changed source sequence")
        for (i, url) in weightURLs.enumerated() { try require(try Data(contentsOf: url) == preservedCropWeightBytes[i], "Drizzle crop changed source weights") }
        for (i, url) in outputURLs.enumerated() { try require(try Data(contentsOf: url) == preservedDrizzleBytes[i], "Drizzle crop changed source image") }
        let stacked = try stackSequence(drizzled, options: options, layer: 1)
        let actual = try floats(stacked)
        for channel in 0..<3 {
            var covered = 0
            for y in 100..<106 { for x in 100..<106 {
            let i = channel * 512 * 512 + y * 512 + x
            var sum = 0.0, weight = 0.0
            for frame in 0..<3 { sum += Double(outputValues[frame][i]) * Double(weightValues[frame][i]); weight += Double(weightValues[frame][i]) }
            if weight > 0 {
                covered += 1
                try require(abs(Double(actual[i]) - sum / weight) < 2e-5, "weighted Drizzle stack channel \(channel)")
            } else {
                try require(actual[i] == 0, "uncovered Drizzle pixel was not zero")
            }
        } }
            try require(covered >= 16, "insufficient Bayer weight coverage in channel \(channel)")
        }
        for (i, url) in sourceURLs.enumerated() { try require(try Data(contentsOf: url) == sourceBytes[i], "application changed source pixels") }
        try require(try Data(contentsOf: flat.url) == flatBytes, "Drizzle altered gallery flat")
        try await sequenceResultHistorySelfTest(source: source, registered: first, sibling: second, drizzle: drizzled)
        try sequenceOutputStorageSelfTest(source: source, output: drizzled, sibling: second, stacked: stacked)
        // The storage test deliberately excludes a frame to test persistent
        // flag undo. Restore the initial selection before comparing stacks.
        try editSequence(drizzled, undo: true)
        try require(try inspectSequence(drizzled, layer: 1).selection == drizzleInfo.selection, "restored selection undo failed before restacking")
        let recoveredStack = try stackSequence(drizzled, options: options, layer: 1)
        try require(try floats(recoveredStack) == actual, "weighted stack pixels changed after independent output restoration")
        var impossible = options
        impossible.filters = [QualityFilter(enabled: true, metric: .nbstars, limit: .threshold, value: 10000)]
        rejected = false
        do { _ = try applySequenceRegistration(source, options: impossible, layer: 0, flat: flat) } catch { rejected = true }
        try require(rejected, "zero-output native filtering reported success")
        _ = try recordSequenceResult(entry: source, source: source, output: drizzled)
        guard let task = jobHistory().first(where: { $0.id == source.job }) else { throw EngineError.failed("Registration task missing") }
        try trashJob(task)
        rejected = false
        do { _ = try sequenceResultStatus(source) } catch { rejected = true }
        try require(rejected && !FileManager.default.fileExists(atPath: process.deletingLastPathComponent().path), "reading trashed task history recreated its live folder")
        guard let deletion = trashEntries().first(where: { $0.jobName == source.job }) else { throw EngineError.failed("Registration trash missing") }
        _ = try restoreTrash(deletion.id)
        try require(try inspectSequence(drizzled, layer: 1).info.count == 3, "restored output sequence missing")
        let restoredHistory = try sequenceResultStatus(source)
        try require(restoredHistory.history.current == drizzled && restoredHistory.canUndo, "whole-task restore lost the durable result cursor")
        let restoredUndo = try replaySequenceResult(source, redo: false)
        let restoredRedo = try replaySequenceResult(source, redo: true)
        try require(restoredUndo.history.current == source && restoredRedo.history.current == drizzled, "whole-task restored result chain cannot undo/redo")
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
        _ = try applySequenceRegistration(location, options: options, layer: 0)
        options.drizzleOptions.enabled = true
        _ = try applySequenceRegistration(location, options: options, layer: 0)
        try JSONEncoder().encode(location).write(to: documents.appendingPathComponent("simulator-sequence-location.json"), options: .atomic)
    }
}
