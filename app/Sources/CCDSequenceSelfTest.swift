// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func ccdSequenceSelfTest() async throws {
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw EngineError.failed("CCD sequence: " + message) }
        }
        let fm = FileManager.default, baseline = loadLibrary()
        let source = documents.appendingPathComponent("simulator-tilt-source.fits")
        let original = try Data(contentsOf: source)
        try require(original.count >= 2880 + 512 * 512 * 4, "independent FITS source geometry")
        let input = try importFile(source)
        let scratch = documents.appendingPathComponent("ccd-frame-tests-" + UUID().uuidString)
        var secondInput: FITSRecord?
        var jobs: [URL] = []
        defer {
            for job in jobs { try? fm.removeItem(at: job) }
            if let secondInput { try? fm.removeItem(at: secondInput.url) }
            try? fm.removeItem(at: scratch)
            try? fm.removeItem(at: input.url); try? saveLibrary(baseline)
        }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        var reversed = Data(original.prefix(2880))
        for row in 0..<512 {
            let start = 2880 + (511 - row) * 512 * 4
            reversed.append(original.subdata(in: start..<(start + 512 * 4)))
        }
        reversed.append(contentsOf: original.dropFirst(2880 + 512 * 512 * 4))
        let reversedSource = scratch.appendingPathComponent("reversed.fits"); try reversed.write(to: reversedSource)
        let mirrored = try importFile(reversedSource); secondInput = mirrored
        var locations: [SequenceLocation] = []
        let regular = try createSequence(files: [input, mirrored]); jobs.append(regular.folder)
        guard let regularLocation = sequenceLocations(job: regular.folder.lastPathComponent).first else { throw EngineError.failed("CCD regular sequence missing") }
        locations.append(regularLocation)
        let container = try prepareJob(files: [input, mirrored], script: "set32bits\ncd lights\nconvert ccd -fitseq -out=../process\n")
        jobs.append(container.folder); _ = try run(container)
        var error = [CChar](repeating: 0, count: 512); let capacity = error.count
        try require(container.folder.appendingPathComponent("process").path.withCString({ siril_sequence_discover($0, &error, capacity) }) != 0,
            "CCD FITSEQ index discovery")
        guard let fitseq = sequenceLocations(job: container.folder.lastPathComponent).first else { throw EngineError.failed("CCD FITSEQ missing") }
        locations.append(fitseq)

        var ser = Data("LUCAM-RECORDER".utf8)
        let fields: [UInt32] = [0, 0, 0, 512, 512, 16, 2]
        for field in fields {
            var encoded = field.littleEndian; withUnsafeBytes(of: &encoded) { ser.append(contentsOf: $0) }
        }
        ser.append(Data(repeating: 0, count: 120))
        let epoch: UInt64 = 637134336000000000 // 2020-01-01 UTC in original SER ticks.
        for _ in 0..<2 { var encoded = epoch.littleEndian; withUnsafeBytes(of: &encoded) { ser.append(contentsOf: $0) } }
        try require(ser.count == 178, "independent SER header geometry")
        let floats = original.withUnsafeBytes { raw in
            (0..<(512 * 512)).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: 2880 + $0 * 4, as: UInt32.self).bigEndian) }
        }
        for frame in 0..<2 { for y in 0..<512 { for x in 0..<512 {
            let row = frame == 0 ? 511 - y : y
            var sample = UInt16((Double(floats[row * 512 + x]) * 65535).rounded()).littleEndian
            withUnsafeBytes(of: &sample) { ser.append(contentsOf: $0) }
        } } }
        for tick in [epoch, epoch + 10000000] { var encoded = tick.littleEndian; withUnsafeBytes(of: &encoded) { ser.append(contentsOf: $0) } }
        let serSource = documents.appendingPathComponent("simulator-ccd-sequence-source.ser")
        try ser.write(to: serSource, options: .atomic)
        let serLocation = try importSERSequence(serSource); jobs.append(try sequenceFolder(serLocation).deletingLastPathComponent())
        locations.append(serLocation)

        let direct = ImageAnalysisEngine(); _ = try await direct.open(source)
        var settings = StarSettings(); settings.radius = 12; settings.maximum = 2000
        let expected = try await direct.sensorTilt(settings: settings)
        var display = NativeDisplaySettings(); display.mode = .linear; display.useICC = false
        let reference = try await direct.preview(channel: -1, settings: display)
        var mirroredReference = Data()
        for row in 0..<512 {
            let start = (511 - row) * 512 * 4
            mirroredReference.append(reference.data.subdata(in: start..<(start + 512 * 4)))
        }
        let reader = ImageAnalysisEngine()
        for location in locations {
            let process = try sequenceFolder(location), root = process.deletingLastPathComponent()
            // The ownership list also contains the .seq index, which this
            // test intentionally edits between its two inclusion scenarios.
            // Check that index separately within each read-only phase.
            let paths = try sequenceFilePaths(location).filter { $0 != "process/" + location.name }
            let sources = try paths.map { try Data(contentsOf: sequenceKeywordSource($0, under: root)) }
            try editSequence(location, selection: SequenceSelection(included: [true, true], reference: 1))
            let meanIndex = try Data(contentsOf: process.appendingPathComponent(location.name))
            let meanFiles = Set(try fm.contentsOfDirectory(atPath: process.path))
            let meanSource = try ccdSequenceSource(location)
            try require(meanSource.details.includedFrames == [0, 1], "included-frame average source")
            _ = try await reader.openCCDSource(meanSource)
            let beforeMean = try await reader.preview(channel: -1, settings: display)
            let mean = try await reader.sensorTiltAverage(source: meanSource, settings: settings)
            for q in 0..<4 {
                let expectedMean = (expected.quadrants[q] + expected.quadrants[q ^ 2]) / 2
                try require(abs(mean.quadrants[q] - expectedMean) < 0.02, "independent per-quadrant equal-frame average")
            }
            try require(mean.stars == 16 && mean.percent == 22 && abs(mean.mean - expected.mean) < 0.02,
                "sequence average star count, tilt percentage or global FWHM")
            try require(try await reader.preview(channel: -1, settings: display).data == beforeMean.data,
                "sequence average did not restore reference image ownership")
            try require(try inspectSequence(location).selection == SequenceSelection(included: [true, true], reference: 1),
                "sequence average changed inclusion/reference")
            var badDetails = meanSource.details; badDetails.includedFrames = [0, 2]
            let badSource = CCDImageSource.frame(directory: try sequenceFolder(location), name: location.name, index: 1, details: badDetails)
            var rejected = false
            do { _ = try await reader.sensorTiltAverage(source: badSource, settings: settings) } catch { rejected = true }
            try require(rejected, "partially readable average accepted")
            try require(try await reader.preview(channel: -1, settings: display).data == beforeMean.data,
                "failed average did not restore reference image ownership")
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await reader.sensorTiltAverage(source: meanSource, settings: settings)
            }
            rejected = false
            do { _ = try await cancelled.value } catch is CancellationError { rejected = true }
            try require(rejected, "cancelled average published a result")
            try require(try Data(contentsOf: process.appendingPathComponent(location.name)) == meanIndex, "average changed source index bytes")
            try require(try Set(fm.contentsOfDirectory(atPath: process.path)) == meanFiles, "average created processing files")
            try editSequence(location, selection: SequenceSelection(included: [false, true], reference: 1))
            let bytes = try Data(contentsOf: process.appendingPathComponent(location.name))
            let files = Set(try fm.contentsOfDirectory(atPath: process.path))
            let includedSource = try ccdSequenceSource(location)
            try require(includedSource.details.includedFrames == [1], "excluded frame leaked into average source")
            let singleMean = try await reader.sensorTiltAverage(source: includedSource, settings: settings)
            for q in 0..<4 {
                try require(abs(singleMean.quadrants[q] - expected.quadrants[q ^ 2]) < 0.02, "average did not exclude frame zero")
            }
            for frameIndex in [1, 0] { // Read both distinct frames, including the excluded frame.
                let frame = try ccdFrameSource(location, index: frameIndex)
                _ = try await reader.openCCDSource(frame)
                let result = try await reader.sensorTilt(settings: settings)
                for q in 0..<4 {
                    let referenceQuadrant = frameIndex == 0 ? q : q ^ 2
                    try require(abs(result.quadrants[q] - expected.quadrants[referenceQuadrant]) < 0.02, "container/current-frame Gaussian tilt")
                }
                try require(result.stars == 16 && abs(result.difference - expected.difference) < 0.02, "sequence frame count or tilt changed")
                let preview = try await reader.preview(channel: -1, settings: display)
                let expectedPixels = frameIndex == 0 ? reference.data : mirroredReference
                try require(preview.width == reference.width && preview.height == reference.height && preview.data.count == reference.data.count,
                    "current-frame preview geometry changed")
                if location == serLocation {
                    // The independent SER deliberately quantizes Float32 to UInt16.
                    // Its 8-bit display can differ by one final rounding level.
                    let actual = [UInt8](preview.data), expectedBytes = [UInt8](expectedPixels)
                    try require(zip(actual, expectedBytes).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 1 }, "quantized SER preview pixels")
                } else { try require(preview.data == expectedPixels, "regular/FITSEQ frame pixels changed through inspector ownership") }
                let panels = try await reader.aberrationPanels(sampling: 256, window: 381, channel: -1, display: display)
                try require(panels.count == 9 && panels[4].region == ImageSelection(x: 128, y: 128, width: 256, height: 256), "current-frame native panel regions")
            }
            try require(try inspectSequence(location).selection == SequenceSelection(included: [false, true], reference: 1) &&
                Data(contentsOf: process.appendingPathComponent(location.name)) == bytes, "analysis changed source selection/reference or index bytes")
            for (i, path) in paths.enumerated() {
                try require(try Data(contentsOf: sequenceKeywordSource(path, under: root)) == sources[i], "analysis changed a source frame/container: " + location.name + " / " + path)
            }
            try require(try Set(fm.contentsOfDirectory(atPath: process.path)) == files, "read-only inspection expanded source frames or wrote processing files")
        }
        try require(try Data(contentsOf: source) == original && Data(contentsOf: input.url) == original &&
            Data(contentsOf: mirrored.url) == reversed && Data(contentsOf: serSource) == ser,
            "CCD analysis modified FITS/SER source bytes")
    }

    func makeCCDSequenceDemo() throws {
        let source = documents.appendingPathComponent("simulator-ccd-sequence-source.ser")
        let location = try importSERSequence(source)
        try editSequence(location, selection: SequenceSelection(included: [false, true], reference: 1))
        try JSONEncoder().encode(location).write(to: documents.appendingPathComponent("simulator-ccd-sequence-location.json"), options: .atomic)
    }
}
