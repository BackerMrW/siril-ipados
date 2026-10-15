// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func patternRegistrationSelfTest() throws {
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("pattern-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var inputs: [FITSRecord] = []
        defer {
            for input in inputs { try? fm.removeItem(at: input.url) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw EngineError.failed("Pattern registration: " + message) }
        }
        func pattern(_ x: Int, _ y: Int) -> Float {
            let index = UInt32(((y + 128) % 128) * 128 + (x + 128) % 128)
            var hash = index &* 1664525 &+ 1013904223
            hash = (hash ^ (hash >> 16)) &* 2246822519
            return 0.1 + 0.6 * Float(hash & 65535) / 65535
        }
        let shifts = [(0, 0), (3, -2), (-4, 5)]
        for (i, shift) in shifts.enumerated() {
            let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    2", "NAXIS1  =                  128", "NAXIS2  =                  128", "END"]
            var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for row in 0..<128 { for x in 0..<128 {
                var encoded = pattern(x - shift.0, 127 - row - shift.1).bitPattern.bigEndian
                withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
            } }
            bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
            let path = folder.appendingPathComponent("pattern-\(i).fits"); try bytes.write(to: path)
            inputs.append(try importFile(path))
        }
        let job = try createSequence(files: inputs)
        defer { try? fm.removeItem(at: job.folder) }
        guard let source = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Pattern fixture sequence missing") }
        let process = try sequenceFolder(source)
        let selection = SequenceSelection(included: [true, false, true], reference: 0)
        try editSequence(source, selection: selection)
        let sourceURLs = try (0..<3).map { try sequenceKeywordSource("process/light_" + String(format: "%05d.fit", $0 + 1), under: job.folder) }
        let sourceBytes = try sourceURLs.map { try Data(contentsOf: $0) }
        var options = BatchOptions(); options.transform = .shift; options.interpolation = .none
        options.scale = 1; options.drizzleOptions.enabled = false
        for method in [SequencePatternMethod.dft, .kombat] {
            let recipe = SequencePatternRecipe(method: method, region: ImageSelection(x: 32, y: 32, width: 64, height: 64), layer: 0, moved: 0.25)
            try measurePatternRegistration(source, recipe: recipe)
            let measured = try inspectSequence(source)
            try require(measured.selection == selection && measured.frames[0].native.has_registration != 0 && measured.frames[1].native.has_registration == 0 && measured.frames[2].native.has_registration != 0, "\(method) selection/reference and excluded-frame matrices")
            for frame in measured.frames.filter(\.included) {
                try require(frame.value(.quality) == frame.native.quality && (0...1).contains(frame.native.quality), "\(method) normalized quality endpoint omitted from graph")
            }
            try require(measured.frames[1].value(.quality) == nil, "excluded unmeasured frame has a plotted quality")
            // H maps the displaced frame into the reference in displayed
            // coordinates: input (-4,+5) needs correction (+4,-5).
            try require(abs(measured.frames[2].native.translation_x - 4) < 0.35 && abs(measured.frames[2].native.translation_y + 5) < 0.35, "\(method) independent known integer shift: \(measured.frames[2].native.translation_x),\(measured.frames[2].native.translation_y)")
            let output = try applySequenceRegistration(source, options: options, layer: 0)
            let generated = try inspectSequence(output)
            try require(generated.info.count == 2 && generated.info.reference == 0 && generated.frames.map { $0.native.file_number } == [1, 3], "\(method) applied output numbering/reference")
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            for frame in 0..<2 {
                guard let image = process.path.withCString({ directory in output.name.withCString { siril_sequence_frame(directory, $0, Int32(frame), &error, capacity) } }) else { throw EngineError.failed(String(cString: error)) }
                defer { siril_image_free(image) }
                for y in 40..<88 { for x in 40..<88 {
                    var pixel = [Float](repeating: 0, count: 3)
                    try require(siril_image_pixel(image, Int32(x), Int32(y), &pixel) == 1 && abs(pixel[0] - pattern(x, y)) < 2e-6, "\(method) actual applied pattern pixels")
                } }
            }
            let deletion = try trashSequenceOutput(output); try permanentlyDeleteTrash([deletion])
            for (i, url) in sourceURLs.enumerated() { try require(try Data(contentsOf: url) == sourceBytes[i], "pattern measurement/application changed source pixels") }
        }
        let beforeFailure = try Data(contentsOf: process.appendingPathComponent(source.name))
        let invalid = SequencePatternRecipe(method: .dft, region: ImageSelection(x: 32, y: 32, width: 64, height: 63), layer: 0, moved: 0.25)
        var rejected = false
        do { try measurePatternRegistration(source, recipe: invalid) } catch { rejected = true }
        try require(rejected, "non-square DFT selection accepted")
        let missing = process.appendingPathComponent("light_00003.fit"), withheld = process.appendingPathComponent("withheld-pattern.fit")
        try fm.moveItem(at: missing, to: withheld)
        rejected = false
        do { try measurePatternRegistration(source, recipe: SequencePatternRecipe(method: .dft, region: ImageSelection(x: 32, y: 32, width: 64, height: 64), layer: 0, moved: 0.25)) } catch { rejected = true }
        try fm.moveItem(at: withheld, to: missing)
        try require(rejected && Data(contentsOf: process.appendingPathComponent(source.name)) == beforeFailure, "failed pattern registration changed original sequence metadata")
        try require(try inspectSequence(source).selection == selection, "failed pattern registration changed selection/reference")
        try singleStarRegistrationSelfTest()
    }
    func singleStarRegistrationSelfTest() throws {
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("single-star-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var inputs: [FITSRecord] = []
        defer {
            for input in inputs { try? fm.removeItem(at: input.url) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func require(_ ok: Bool, _ message: String) throws {
            if !ok { throw EngineError.failed("Single star registration: " + message) }
        }
        func star(_ x: Int, _ y: Int) -> Float {
            let dx = Double(x) - 42.25, dy = Double(y) - 78.75
            return Float(0.1 + 0.6 * exp(-(dx * dx + dy * dy) / 8))
        }
        for topDown in [false, true] {
            var current: [FITSRecord] = [], blank = Data()
            for (i, shift) in [(0, 0), (3, -2), (-4, 5)].enumerated() {
                let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    2", "NAXIS1  =                  128", "NAXIS2  =                  128", "ROWORDER= '\(topDown ? "TOP-DOWN" : "BOTTOM-UP")'", "END"]
                var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
                blank = bytes
                for row in 0..<128 { for x in 0..<128 {
                    var encoded = star(x - shift.0, 127 - row - shift.1).bitPattern.bigEndian
                    withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
                    var zero = Float(0.1).bitPattern.bigEndian
                    withUnsafeBytes(of: &zero) { blank.append(contentsOf: $0) }
                } }
                bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
                blank.append(contentsOf: repeatElement(UInt8(0), count: (2880 - blank.count % 2880) % 2880))
                let path = folder.appendingPathComponent("star-\(topDown)-\(i).fits"); try bytes.write(to: path)
                let input = try importFile(path); inputs.append(input); current.append(input)
            }
            let job = try createSequence(files: current)
            defer { try? fm.removeItem(at: job.folder) }
            guard let source = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Single star sequence missing") }
            let process = try sequenceFolder(source)
            let selection = SequenceSelection(included: [true, false, true], reference: 0)
            try editSequence(source, selection: selection)
            let original = try current.map { try Data(contentsOf: $0.url) }
            var options = BatchOptions(); options.transform = .shift; options.interpolation = .none
            options.scale = 1; options.drizzleOptions.enabled = false
            for method in [SequencePatternMethod.singleStar, .followStar] {
                let recipe = SequencePatternRecipe(method: method, region: ImageSelection(x: 25, y: 58, width: 38, height: 43), layer: 0, moved: 0.25)
                try measurePatternRegistration(source, recipe: recipe)
                let measured = try inspectSequence(source)
                try require(measured.selection == selection && measured.frames[1].native.has_registration == 0, "selection/reference/excluded frame")
                for frame in measured.frames.filter(\.included) {
                    try require(frame.native.stars == 1 && abs(frame.native.fwhm - 4.70964) < 0.05 && frame.value(.quality) == nil, "original PSF width, count and unmeasured quality")
                }
                try require(abs(measured.frames[2].native.translation_x - 4) < 0.05 && abs(measured.frames[2].native.translation_y + 5) < 0.05, "independent known star displacement: \(method), \(topDown), \(measured.frames[2].native.translation_x), \(measured.frames[2].native.translation_y)")
                let output = try applySequenceRegistration(source, options: options, layer: 0)
                let generated = try inspectSequence(output)
                try require(generated.info.count == 2 && generated.info.reference == 0 && generated.frames.map { $0.native.file_number } == [1, 3], "applied frame mapping")
                var error = [CChar](repeating: 0, count: 512); let capacity = error.count
                for index in 0..<2 {
                    guard let image = process.path.withCString({ directory in output.name.withCString { siril_sequence_frame(directory, $0, Int32(index), &error, capacity) } }) else { throw EngineError.failed(String(cString: error)) }
                    defer { siril_image_free(image) }
                    for y in 60..<96 { for x in 28..<58 {
                        var pixel = [Float](repeating: 0, count: 3)
                        try require(siril_image_pixel(image, Int32(x), Int32(y), &pixel) == 1 && abs(pixel[0] - star(x, y)) < 2e-6, "actual aligned Gaussian pixels")
                    } }
                }
                let deletion = try trashSequenceOutput(output); try permanentlyDeleteTrash([deletion])
            }
            let metadata = try Data(contentsOf: process.appendingPathComponent(source.name))
            let last = process.appendingPathComponent("light_00003.fit"), withheld = process.appendingPathComponent("withheld-star.fit")
            try fm.moveItem(at: last, to: withheld); try blank.write(to: last)
            var rejected = false
            do { try measurePatternRegistration(source, recipe: SequencePatternRecipe(method: .singleStar, region: ImageSelection(x: 25, y: 58, width: 38, height: 43), layer: 0, moved: 0.25)) } catch { rejected = true }
            try fm.removeItem(at: last); try fm.moveItem(at: withheld, to: last)
            try require(rejected && Data(contentsOf: process.appendingPathComponent(source.name)) == metadata, "starless included frame did not roll back metadata")
            for (i, input) in current.enumerated() { try require(try Data(contentsOf: input.url) == original[i], "changed source image bytes") }
        }
    }
}
