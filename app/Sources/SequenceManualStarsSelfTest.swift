// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func manualStarsRegistrationSelfTest() throws {
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("manual-stars-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var imported: [FITSRecord] = []
        defer {
            for input in imported { try? fm.removeItem(at: input.url) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Manual stars: " + message) }
        }
        let centres = [(32.25, 32.75), (88.25, 38.75), (63.25, 91.75)]
        let boxes = centres.map { x, y in ImageSelection(x: Int(x) - 12, y: Int(y) - 12, width: 25, height: 25) }
        func brightness(_ x: Double, _ y: Double) -> Float {
            var value = 0.1
            for (cx, cy) in centres { value += 0.6 * exp(-((x - cx) * (x - cx) + (y - cy) * (y - cy)) / 8) }
            return Float(value)
        }
        for topDown in [false, true] { for rotation in [false, true] {
            var inputs: [FITSRecord] = [], blank = Data()
            let shifts = [(0.0, 0.0), (3.0, -2.0), (-4.0, 5.0)]
            let angles = rotation ? [0.0, 0.025, -0.04] : [0.0, 0.0, 0.0]
            for i in 0..<3 {
                let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    2",
                    "NAXIS1  =                  128", "NAXIS2  =                  128", "ROWORDER= '\(topDown ? "TOP-DOWN" : "BOTTOM-UP")'", "END"]
                var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
                blank = bytes
                let c = cos(angles[i]), s = sin(angles[i]), dx = shifts[i].0, dy = shifts[i].1
                for row in 0..<128 { for x in 0..<128 {
                    let px = Double(x) - 64 - dx, py = Double(127 - row) - 64 - dy
                    var pixel = brightness(c * px + s * py + 64, -s * px + c * py + 64).bitPattern.bigEndian
                    withUnsafeBytes(of: &pixel) { bytes.append(contentsOf: $0) }
                    var zero = Float(0.1).bitPattern.bigEndian
                    withUnsafeBytes(of: &zero) { blank.append(contentsOf: $0) }
                } }
                bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
                blank.append(contentsOf: repeatElement(UInt8(0), count: (2880 - blank.count % 2880) % 2880))
                let path = folder.appendingPathComponent("\(topDown)-\(rotation)-\(i).fits")
                try bytes.write(to: path)
                let input = try importFile(path); imported.append(input); inputs.append(input)
            }
            let job = try createSequence(files: inputs)
            defer { try? fm.removeItem(at: job.folder) }
            guard let source = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Manual star sequence missing") }
            let process = try sequenceFolder(source), metadata = process.appendingPathComponent(source.name)
            let originals = try inputs.map { try Data(contentsOf: $0.url) }
            let selection = SequenceSelection(included: [true, false, true], reference: 0)
            try editSequence(source, selection: selection)
            for count in [2, 3] { for follow in [false, true] {
                let recipe = SequencePatternRecipe(method: .manualStars, region: boxes[0], layer: 0, moved: 0,
                    stars: Array(boxes.prefix(count)), rotation: rotation, follow: follow)
                try measurePatternRegistration(source, recipe: recipe)
                let measured = try inspectSequence(source)
                try require(measured.selection == selection, "changed participation/reference")
                for frame in measured.frames.filter(\.included) {
                    try require(frame.native.stars == count && abs(frame.native.fwhm - 4.70964) < 0.06 && frame.value(.quality) == nil, "PSF count/width/quality")
                }
                let lines = try String(contentsOf: metadata, encoding: .utf8).components(separatedBy: .newlines).filter { $0.hasPrefix("R0 ") }
                guard lines.count == 3, let marker = lines[2].range(of: " H ") else { throw EngineError.failed("Manual star matrices missing") }
                let h = lines[2][marker.upperBound...].split(separator: " ").compactMap { Double($0) }
                let c = cos(angles[2]), s = sin(angles[2]), dx = shifts[2].0, dy = shifts[2].1
                let expected = [c, -s, 64 - c * (64 + dx) + s * (63 - dy), s, c,
                    63 - s * (64 + dx) - c * (63 - dy), 0, 0, 1]
                try require(h.count >= 9 && zip(h, expected).allSatisfy { abs($0 - $1) < 0.06 }, "independently predicted rigid matrix")
                var options = BatchOptions(); options.transform = rotation ? .similarity : .shift
                options.interpolation = rotation ? .linear : .none; options.scale = 1; options.drizzleOptions.enabled = false
                let output = try applySequenceRegistration(source, options: options, layer: 0)
                let generated = try inspectSequence(output)
                try require(generated.info.count == 2 && generated.info.reference == 0, "output frame count/reference")
                var error = [CChar](repeating: 0, count: 512); let capacity = error.count
                guard let image = process.path.withCString({ directory in output.name.withCString { siril_sequence_frame(directory, $0, 1, &error, capacity) } }) else { throw EngineError.failed(String(cString: error)) }
                var maxError: Float = 0, sumError = 0.0, samples = 0
                for y in 20..<108 { for x in 20..<108 {
                    var pixel = [Float](repeating: 0, count: 3)
                    let channels = siril_image_pixel(image, Int32(x), Int32(y), &pixel)
                    let difference = abs(pixel[0] - brightness(Double(x), Double(y)))
                    if channels != 1 { maxError = 1 }
                    maxError = max(maxError, difference); sumError += Double(difference); samples += 1
                } }
                siril_image_free(image)
                try require(maxError < (rotation ? 0.04 : 3e-6) && sumError / Double(samples) < (rotation ? 0.002 : 1e-6), "actual aligned Gaussian pixels")
                let trash = try trashSequenceOutput(output); try permanentlyDeleteTrash([trash])
            } }
            let beforeFailure = try Data(contentsOf: metadata)
            let last = process.appendingPathComponent("light_00003.fit"), withheld = process.appendingPathComponent("withheld-manual.fit")
            try fm.moveItem(at: last, to: withheld); try blank.write(to: last)
            var rejected = false
            do { try measurePatternRegistration(source, recipe: SequencePatternRecipe(method: .manualStars, region: boxes[0], layer: 0, moved: 0,
                stars: boxes, rotation: rotation, follow: false)) } catch { rejected = true }
            try fm.removeItem(at: last); try fm.moveItem(at: withheld, to: last)
            try require(rejected && Data(contentsOf: metadata) == beforeFailure, "starless frame did not restore metadata")
            for (i, input) in inputs.enumerated() { try require(try Data(contentsOf: input.url) == originals[i], "changed source image bytes") }
        } }
    }
}
