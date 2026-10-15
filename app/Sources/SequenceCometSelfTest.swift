// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func cometRegistrationSelfTest() throws {
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw EngineError.failed("Comet registration: " + message) } }
        let fm = FileManager.default, library = loadLibrary()
        let fixtureFolder = documents.appendingPathComponent("comet-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
        defer { try? saveLibrary(library); try? fm.removeItem(at: fixtureFolder) }
        let width = 96, height = 80
        let selection = SequenceSelection(included: [true, true, false, true], reference: 1)
        for variant in 0..<3 {
            let registered = variant == 1, channels = variant == 2 ? 3 : 1
            let layer = channels == 3 ? 1 : 0
            func gaussian(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ sigma: Double) -> Double {
                exp(-((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (2 * sigma * sigma))
            }
            func pixel(_ frame: Int, _ c: Int, _ x: Int, _ y: Int) -> Float {
                let cameraX = registered ? Double(frame * 2) : 0, cameraY = registered ? Double(frame) : 0
                let cx = 35 + cameraX + Double(3 * frame), cy = 42 + cameraY - Double(2 * frame)
                let object = 0.6 * gaussian(Double(x), Double(y), cx, cy, 2)
                let stars = 0.2 * gaussian(Double(x), Double(y), 15 + cameraX, 15 + cameraY, 1.5)
                    + 0.2 * gaussian(Double(x), Double(y), 73 + cameraX, 60 + cameraY, 1.5)
                return Float((0.1 + object + stars) * (1 - 0.1 * Double(c)))
            }
            func hdu(_ frame: Int, extensionImage: Bool = false) -> Data {
                var cards = [extensionImage ? "XTENSION= 'IMAGE   '" : "SIMPLE  =                    T", "BITPIX  =                  -32",
                    "NAXIS   =                    \(channels == 3 ? 3 : 2)", "NAXIS1  = \(width)", "NAXIS2  = \(height)"]
                if channels == 3 { cards.append("NAXIS3  =                    3") }
                if extensionImage { cards += ["PCOUNT  =                    0", "GCOUNT  =                    1"] }
                cards += ["EXPTIME =                   30", "DATE-OBS= '2026-10-15T00:0\(frame):00.000'", "ROWORDER= '\(variant == 1 ? "TOP-DOWN" : "BOTTOM-UP")'", "END"]
                var data = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
                for c in 0..<channels { for row in 0..<height { for x in 0..<width {
                    var encoded = pixel(frame, c, x, height - 1 - row).bitPattern.bigEndian
                    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
                } } }
                data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880)); return data
            }
            var inputs: [FITSRecord] = []
            defer { for input in inputs { try? fm.removeItem(at: input.url) } }
            let job: ProcessingJob, source: SequenceLocation
            if variant == 2 {
                job = try prepareJob(files: [], script: "# Independent RGB FITSEQ moving-object fixture\n")
                var container = hdu(0)
                for frame in 1..<4 { container.append(hdu(frame, extensionImage: true)) }
                let process = job.folder.appendingPathComponent("process")
                try container.write(to: process.appendingPathComponent("comet_multi.fit"))
                var error = [CChar](repeating: 0, count: 512); let capacity = error.count
                try require(process.path.withCString { siril_sequence_discover($0, &error, capacity) } != 0, "RGB FITSEQ discovery")
                source = SequenceLocation(job: job.folder.lastPathComponent, name: "comet_multi.seq")
            } else {
                for frame in 0..<4 {
                    let url = fixtureFolder.appendingPathComponent("comet-\(variant)-\(frame).fits")
                    try hdu(frame).write(to: url); inputs.append(try importFile(url))
                }
                job = try createSequence(files: inputs)
                guard let discovered = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Comet fixture sequence missing") }
                source = discovered
            }
            defer { try? fm.removeItem(at: job.folder) }
            try editSequence(source, selection: selection)
            let process = try sequenceFolder(source), sourceURL = process.appendingPathComponent(source.name)
            if registered {
                // Independent known stellar matrices, not another registration
                // algorithm's estimate: camera drift is (+2,+1) per minute.
                var text = try String(contentsOf: sourceURL, encoding: .utf8)
                for i in 0..<4 { text += "R0 4 4 1 0.5 0.1 12 H 1 0 \((1 - i) * 2) 0 1 \(1 - i) 0 0 1\n" }
                try text.write(to: sourceURL, atomically: true, encoding: .utf8)
            }
            let sourceBytes = try Data(contentsOf: sourceURL)
            let inputPaths = try sequenceFilePaths(source).filter { $0 != "process/" + source.name }
            let inputBytes = try inputPaths.map { try Data(contentsOf: sequenceTrashPath($0, under: job.folder)) }
            let cameraX = registered ? 6.0 : 0, cameraY = registered ? 3.0 : 0
            var recipe = SequenceCometRecipe(); recipe.layer = layer
            recipe.first = CometAnchor(frame: 0, x: 35, y: 42)
            recipe.second = CometAnchor(frame: 3, x: 44 + cameraX, y: 36 + cameraY)
            var history = SequenceCometHistory(source: source); history.record(recipe)
            var edited = recipe; edited.first?.x += 0.25
            history.record(edited); history.step(redo: false)
            try saveCometHistory(history)
            let reopened = try cometHistory(source)
            try require(reopened.current == recipe && reopened.future == [edited], "anchor/channel history reopen and undo")
            history.step(redo: true); try require(history.current == edited, "anchor redo")
            let output = try registerComet(source, recipe: recipe)
            let generated = try inspectSequence(output, layer: layer)
            let numbers: [Int32] = variant == 2 ? [0, 1, 2, 3] : [1, 2, 3, 4]
            try require(generated.selection == selection && generated.frames.map({ $0.native.file_number }) == numbers, "full numbering, excluded frame and nonzero reference")
            for frame in generated.frames.filter(\.included) {
                let x = Double((1 - frame.id) * (registered ? 5 : 3)), y = Double((1 - frame.id) * (registered ? -1 : -2))
                try require(abs(frame.native.translation_x - x) < 2e-5 && abs(frame.native.translation_y - y) < 2e-5, "independent timed/composed matrix, variant \(variant), frame \(frame.id)")
                if !registered { try require(frame.value(.quality) == nil, "new moving-object matrix invented a zero quality measurement") }
                else { try require(frame.native.quality == 0.5 && frame.native.fwhm == 4, "inherited stellar measurements lost") }
            }
            let outputRecord = try sequenceOutputRecords(job: source.job).first { $0.location == output }
            guard let outputRecord else { throw EngineError.failed("Comet output provenance missing") }
            let velocity = try JSONDecoder().decode([Double].self, from: Data(contentsOf: outputRecord.folder.appendingPathComponent("comet-velocity.json")))
            try require(velocity.count == 2 && abs(velocity[0] - 180) < 2e-4 && abs(velocity[1] + 120) < 2e-4, "independent anchor speed in reference pixels/hour")
            let prefix = String(output.name.dropLast(source.name.count))
            for (i, path) in inputPaths.enumerated() {
                let input = try sequenceTrashPath(path, under: job.folder)
                let detached = input.deletingLastPathComponent().appendingPathComponent(prefix + input.lastPathComponent)
                try require(try fm.attributesOfItem(atPath: detached.path)[.type] as? FileAttributeType == .typeRegular && Data(contentsOf: detached) == inputBytes[i], "independent regular output bytes, including excluded/container frames")
            }
            _ = try recordSequenceResult(entry: source, source: source, output: output)
            try require(try replaySequenceResult(source, redo: false).history.current == source, "whole-sequence undo")
            try require(try replaySequenceResult(source, redo: true).history.current == output, "whole-sequence redo")
            var apply = BatchOptions(); apply.transform = .shift; apply.interpolation = .none; apply.scale = 1; apply.drizzleOptions.enabled = false
            let aligned = try applySequenceRegistration(output, options: apply, layer: layer)
            let alignedInfo = try inspectSequence(aligned, layer: layer)
            try require(alignedInfo.info.count == 3 && alignedInfo.info.reference == 1 && alignedInfo.frames.map({ $0.native.file_number }) == [numbers[0], numbers[1], numbers[3]], "applied participating frame/reference map")
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            for frame in 0..<3 {
                guard let image = process.path.withCString({ directory in aligned.name.withCString { siril_sequence_frame(directory, $0, Int32(frame), &error, capacity) } }) else { throw EngineError.failed("Comet aligned frame missing") }
                defer { siril_image_free(image) }
                for y in 30..<53 { for x in 28..<54 {
                    var actual = [Float](repeating: 0, count: 3)
                    try require(Int(siril_image_pixel(image, Int32(x), Int32(y), &actual)) == channels, "applied pixel channels")
                    for c in 0..<channels {
                        let cx = registered ? 40.0 : 38.0, cy = registered ? 41.0 : 40.0
                        let predicted = Float((0.1 + 0.6 * gaussian(Double(x), Double(y), cx, cy, 2)) * (1 - 0.1 * Double(c)))
                        try require(abs(actual[c] - predicted) < 3e-6, "actual independently aligned moving object pixels")
                    }
                } }
            }
            var rejected = false
            do { _ = try trashSequenceOutput(output) } catch { rejected = true }
            try require(rejected, "deleted comet source still required by applied output")
            let appliedTrash = try trashSequenceOutput(aligned); try permanentlyDeleteTrash([appliedTrash])
            let outputPaths = try sequenceFilePaths(output)
            let outputBytes = try outputPaths.map { try Data(contentsOf: sequenceTrashPath($0, under: job.folder)) }
            let trash = try trashSequenceOutput(output); _ = try restoreTrash(trash)
            for (i, path) in outputPaths.enumerated() { try require(try Data(contentsOf: sequenceTrashPath(path, under: job.folder)) == outputBytes[i], "comet output trash/restore changed bytes") }
            let finalTrash = try trashSequenceOutput(output); try permanentlyDeleteTrash([finalTrash])
            try require(try Data(contentsOf: sourceURL) == sourceBytes, "comet workflow changed original sequence metadata")
            for (i, path) in inputPaths.enumerated() { try require(try Data(contentsOf: sequenceTrashPath(path, under: job.folder)) == inputBytes[i], "comet workflow changed source FITS/container") }
            if variant == 0 {
                var reverse = recipe; reverse.first = recipe.second; reverse.second = recipe.first
                let reversed = try registerComet(source, recipe: reverse)
                let reversedInfo = try inspectSequence(reversed)
                try require(abs(reversedInfo.frames[0].native.translation_x - 3) < 2e-5 && abs(reversedInfo.frames[3].native.translation_y - 4) < 2e-5, "reversed timestamp/anchor order changed physical motion")
                let reversedTrash = try trashSequenceOutput(reversed); try permanentlyDeleteTrash([reversedTrash])
                let interrupted = job.folder.appendingPathComponent("SequenceRuns").appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: interrupted, withIntermediateDirectories: true)
                let interruptedPrefix = "r_" + interrupted.lastPathComponent.replacingOccurrences(of: "-", with: "") + "_"
                let interruptedOutput = SequenceLocation(job: source.job, name: interruptedPrefix + source.name)
                try JSONEncoder().encode(recipe).write(to: interrupted.appendingPathComponent("comet.json"))
                try JSONEncoder().encode(source).write(to: interrupted.appendingPathComponent("source-location.json"))
                try JSONEncoder().encode(interruptedOutput).write(to: interrupted.appendingPathComponent("output-sequence.json"))
                try JSONEncoder().encode(JobState(created: Date(), updated: Date(), state: "运行中", inputCount: 3, message: "Interrupted fixture")).write(to: interrupted.appendingPathComponent("job.json"))
                try sourceBytes.write(to: process.appendingPathComponent(interruptedOutput.name))
                let link = process.appendingPathComponent(interruptedPrefix + "partial.fit")
                try fm.createSymbolicLink(at: link, withDestinationURL: process.appendingPathComponent("light_00001.fit"))
                let temporary = interrupted.appendingPathComponent(UUID().uuidString + ".frame")
                try Data([1, 2, 3]).write(to: temporary)
                activeJobIDs.insert(source.job); try recoverCometRuns(job: source.job)
                try require(fm.fileExists(atPath: link.path), "recovery removed an active run")
                activeJobIDs.remove(source.job)
                let recovered = try sequenceOutputRecords(job: source.job).first { $0.location == interruptedOutput }
                try require(recovered?.available == false && recovered?.state.state == "彗星配准被中断" && !fm.fileExists(atPath: link.path) && !fm.fileExists(atPath: temporary.path), "interrupted link/detach recovery did not clean private outputs")
                try require(try Data(contentsOf: sourceURL) == sourceBytes && Data(contentsOf: process.appendingPathComponent("light_00001.fit")) == inputBytes[0], "interrupted recovery changed source")
                let frame = process.appendingPathComponent("light_00004.fit"), original = try Data(contentsOf: frame)
                let dateCard = stride(from: 0, to: 2880, by: 80).first { String(data: original[$0..<($0 + 8)], encoding: .ascii) == "DATE-OBS" }!
                for card in ["COMMENT missing date", "DATE-OBS= '2026-10-15T00:00:00.000'"] {
                    var invalid = original; invalid.replaceSubrange(dateCard..<(dateCard + 80), with: card.padding(toLength: 80, withPad: " ", startingAt: 0).utf8)
                    try invalid.write(to: frame)
                    rejected = false
                    do { _ = try registerComet(source, recipe: recipe) } catch { rejected = true }
                    try original.write(to: frame)
                    try require(rejected && Data(contentsOf: sourceURL) == sourceBytes, "missing/equal timestamp accepted or changed source")
                    try require(try sequenceOutputRecords(job: source.job).filter(\.available).isEmpty, "timestamp failure left a publishable partial sequence")
                }
                var invalid = recipe; invalid.first?.x = .nan
                rejected = false; do { _ = try registerComet(source, recipe: invalid) } catch { rejected = true }
                try require(rejected, "nonfinite anchor accepted")
                invalid = recipe; invalid.second?.frame = 0
                rejected = false; do { _ = try registerComet(source, recipe: invalid) } catch { rejected = true }
                try require(rejected, "same-frame anchors accepted")
                var invalidHistory = reopened; invalidHistory.current.first?.x = .nan
                rejected = false; do { try saveCometHistory(invalidHistory) } catch { rejected = true }
                try require(rejected && cometHistory(source).current == recipe, "invalid history overwrote saved anchors")
            }
        }
    }
}
