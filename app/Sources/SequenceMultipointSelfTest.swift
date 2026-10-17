// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func multipointSelfTest() throws {
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("multipoint-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var imported: [FITSRecord] = []
        defer {
            for input in imported { try? fm.removeItem(at: input.url) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Multipoint: " + message) }
        }
        let oldRecipe = try JSONEncoder().encode(SequenceMultipointSettings())
        let oldDecoded = try JSONDecoder().decode(SequenceMultipointSettings.self, from: oldRecipe)
        try require(oldDecoded.advanced == nil && oldDecoded.native.global_search == 34 && oldDecoded.native.debayer == 7 &&
            oldDecoded.native.stack_frames == -1 && oldDecoded.native.seed == 1, "old recipes must retain original advanced defaults")
        func expected(_ x: Int, _ y: Int, _ channel: Int) -> UInt16 {
            let dx = Double(x) - 127.5, dy = Double(y) - 127.5
            let distance = sqrt(dx * dx + dy * dy)
            let disc = max(0, min(1, (104 - distance) / 8))
            let texture = 24000 + 6000 * sin(Double(x) / 6) * cos(Double(y) / 7) + 4000 * sin(Double(x + y) / 4)
            return UInt16(max(0, min(65535, disc * texture * (1 - 0.2 * Double(channel)))))
        }
        for channels in [1, 3] {
            var inputs: [FITSRecord] = []
            for frame in 0..<3 {
                var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    \(channels == 1 ? 2 : 3)",
                    "NAXIS1  =                  256", "NAXIS2  =                  256"]
                if channels == 3 { cards.append("NAXIS3  =                    3") }
                cards += ["BZERO   =                32768", "BSCALE  =                    1", "ROWORDER= '\(channels == 1 ? "BOTTOM-UP" : "TOP-DOWN")'", "END"]
                var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
                for channel in 0..<channels { for row in 0..<256 { for x in 0..<256 {
                    // An excluded bright frame must not enter the reference or stack.
                    let value: UInt16 = frame == 1 ? 60000 : expected(x, 255 - row, channel)
                    var encoded = (value ^ 0x8000).bigEndian
                    withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
                } } }
                bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
                let path = folder.appendingPathComponent("\(channels)-\(frame).fits")
                try bytes.write(to: path)
                let input = try importFile(path); imported.append(input); inputs.append(input)
            }
            let job = try createSequence(files: inputs)
            defer { try? fm.removeItem(at: job.folder) }
            guard let source = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Multipoint source sequence missing") }
            try editSequence(source, selection: SequenceSelection(included: [true, false, true], reference: 0))
            let process = try sequenceFolder(source), metadata = try Data(contentsOf: process.appendingPathComponent(source.name))
            let sourceBytes = try inputs.map { try Data(contentsOf: $0.url) }
            var settings = SequenceMultipointSettings()
            settings.planet = true; settings.halfBox = 16; settings.search = 4
            settings.structure = 0; settings.normalize = false; settings.refine = false
            settings.dewarp = false; settings.smoothRadius = 0; settings.floatOutput = true
            let result = try stackMultipoint(source, settings: settings)
            let summary = try JSONDecoder().decode(SequenceMultipointSummary.self, from: Data(contentsOf: result.deletingLastPathComponent().appendingPathComponent("multipoint-summary.json")))
            try require(summary.frames == 3 && summary.included == 2 && summary.points > 0 && summary.stackSize == 2,
                "original AP/frame counts and selected-frame ranking")
            try require(fm.fileExists(atPath: result.deletingLastPathComponent().appendingPathComponent("analysis.mpp").path), "missing independently saved analysis")
            var error = [CChar](repeating: 0, count: 512); let capacity = error.count
            guard let image = result.path.withCString({ siril_image_read($0, &error, capacity) }) else { throw EngineError.failed(String(cString: error)) }
            var info = SirilImageInfo()
            try require(siril_image_info(image, &info) != 0 && info.width == 256 && info.height == 256 && info.channels == channels,
                "centroid identity stack geometry and channels: \(info.width)x\(info.height), \(info.channels)")
            var worst: Float = 0
            for y in 0..<256 { for x in 0..<256 {
                var pixel = [Float](repeating: 0, count: 3)
                if siril_image_pixel(image, Int32(x), Int32(y), &pixel) != channels { worst = 1 }
                for channel in 0..<channels {
                    worst = max(worst, abs(pixel[channel] - Float(expected(x, y, channel)) / 65535))
                }
            } }
            siril_image_free(image)
            try require(worst < 4.0 / 65535, "independent identical-frame pixels, channels=\(channels), error=\(worst)")
            let savedRuns = try multipointRuns(source)
            try require(savedRuns.count == 1 && savedRuns[0].id == result.deletingLastPathComponent().lastPathComponent,
                "saved analysis discovery")
            let reopened = try multipointAnalysis(source, runID: savedRuns[0].id, display: NativeDisplaySettings())
            try require(reopened.width == 256 && reopened.height == 256 && reopened.frames == 3 && reopened.included == 2 &&
                reopened.registered && reopened.points.count == summary.points && !reopened.preview.data.isEmpty,
                "reopened reference, metadata, points and native preview")
            try require(reopened.points.allSatisfy { point in
                point.x >= 0 && point.x < 256 && point.y >= 0 && point.y < 256 && point.structure.isFinite &&
                point.box.x >= 0 && point.box.y >= 0 && point.box.width > 0 && point.box.height > 0 &&
                point.box.x + point.box.width <= 256 && point.box.y + point.box.height <= 256 &&
                point.x >= point.box.x && point.x <= point.box.x + point.box.width &&
                point.y >= point.box.y && point.y <= point.box.y + point.box.height
            }, "displayed AP centres and boxes")
            if channels == 1 {
                let sidecar = result.deletingLastPathComponent().appendingPathComponent("analysis.mpp")
                guard let analysis = sidecar.path.withCString({ siril_multipoint_open($0, &error, capacity) }) else { throw EngineError.failed(String(cString: error)) }
                guard let reference = siril_multipoint_reference(analysis, &error, capacity) else {
                    siril_multipoint_close(analysis); throw EngineError.failed(String(cString: error))
                }
                siril_multipoint_close(analysis)
                var referenceError: Float = 0
                for y in 0..<256 { for x in 0..<256 {
                    var pixel = [Float](repeating: 0, count: 3)
                    if siril_image_pixel(reference, Int32(x), Int32(y), &pixel) != 1 { referenceError = 1 }
                    referenceError = max(referenceError, abs(pixel[0] - Float(expected(x, y, 0)) / 65535))
                } }
                siril_image_free(reference)
                try require(referenceError < 2.0 / 65535, "independent saved mean-frame pixels after analysis handle closed")
                try Data(contentsOf: sidecar).write(to: documents.appendingPathComponent("native-multipoint-analysis.mpp"), options: .atomic)
                let originalAnalysis = try Data(contentsOf: sidecar), originalResult = try Data(contentsOf: result)
                var editedID = try editMultipoint(source, runID: savedRuns[0].id, edit: .clear)
                let editFolder = try multipointFolder(source, runID: editedID)
                try require(editedID != savedRuns[0].id, "editing must fork completed analysis")
                var edited = try multipointAnalysis(source, runID: editedID, display: NativeDisplaySettings())
                try require(edited.points.isEmpty && !edited.registered, "clear must invalidate registered shifts")
                var emptyRejected = false
                do { _ = try resumeMultipoint(source, runID: editedID) } catch { emptyRejected = true }
                try require(emptyRejected, "restack accepted empty edited AP set")
                editedID = try editMultipoint(source, runID: editedID, edit: .add(x: 128, y: 128, halfBox: 16))
                editedID = try editMultipoint(source, runID: editedID, edit: .resize(index: 0, halfBox: 20))
                editedID = try editMultipoint(source, runID: editedID, edit: .move(index: 0, x: 130, y: 126))
                edited = try multipointAnalysis(source, runID: editedID, display: NativeDisplaySettings())
                try require(edited.points.count == 1 && edited.points[0].x == 130 && edited.points[0].y == 126 &&
                    edited.points[0].box.width == 40 && edited.points[0].box.height == 40, "native add/resize/move and top-left coordinate roundtrip")
                let movedPoints = edited.points
                editedID = try editMultipoint(source, runID: editedID, edit: .remove(index: 0))
                editedID = try editMultipoint(source, runID: editedID, edit: .undo)
                edited = try multipointAnalysis(source, runID: editedID, display: NativeDisplaySettings())
                try require(edited.points == movedPoints, "undo must restore exact bounds and structure")
                editedID = try editMultipoint(source, runID: editedID, edit: .redo)
                edited = try multipointAnalysis(source, runID: editedID, display: NativeDisplaySettings())
                try require(edited.points.isEmpty, "redo must restore removal")
                let historyPath = editFolder.appendingPathComponent("multipoint-edit.json")
                let beforeFailure = try Data(contentsOf: historyPath)
                var editRejected = false
                do { _ = try editMultipoint(source, runID: editedID, edit: .add(x: -1, y: 128, halfBox: 16)) }
                catch { editRejected = true }
                try require(editRejected && (try Data(contentsOf: historyPath)) == beforeFailure, "failed edit changed persisted history")
                editedID = try editMultipoint(source, runID: editedID, edit: .auto)
                edited = try multipointAnalysis(source, runID: editedID, display: NativeDisplaySettings())
                try require(edited.points.count == summary.points, "original auto-placement after empty AP set")
                editedID = try editMultipoint(source, runID: editedID, edit: .remove(index: 0))
                let resumed = try resumeMultipoint(source, runID: editedID)
                let resumedSummary = try JSONDecoder().decode(SequenceMultipointSummary.self,
                    from: Data(contentsOf: resumed.deletingLastPathComponent().appendingPathComponent("multipoint-summary.json")))
                try require(resumedSummary.points == summary.points - 1 && resumedSummary.included == 2,
                    "resume regenerated automatic grid instead of consuming edited APs")
                guard let resumedImage = resumed.path.withCString({ siril_image_read($0, &error, capacity) }) else {
                    throw EngineError.failed(String(cString: error))
                }
                var resumeError: Float = 0
                for y in 116..<140 { for x in 116..<140 {
                    var pixel = [Float](repeating: 0, count: 3)
                    if siril_image_pixel(resumedImage, Int32(x), Int32(y), &pixel) != 1 { resumeError = 1 }
                    resumeError = max(resumeError, abs(pixel[0] - Float(expected(x, y, 0)) / 65535))
                } }
                siril_image_free(resumedImage)
                try require(resumeError < 4.0 / 65535, "edited AP restack changed independent identity pixels: \(resumeError)")
                try require(try Data(contentsOf: sidecar) == originalAnalysis && Data(contentsOf: result) == originalResult,
                    "editing/restack changed original analysis or result")
                try require(try Data(contentsOf: editFolder.appendingPathComponent("analysis.mpp")) == originalAnalysis,
                    "undo history duplicated or rewrote base mean frame")
                for step in 0..<32 {
                    editedID = try editMultipoint(source, runID: editedID, edit: .move(index: 0, x: 120 + step % 2, y: 128))
                }
                let limited = try multipointHistory(editFolder)
                try require(limited?.past.count == 30 && limited?.future.isEmpty == true, "history must keep at most 30 snapshots")
                editedID = try editMultipoint(source, runID: editedID, edit: .undo)
                editedID = try editMultipoint(source, runID: editedID, edit: .resize(index: 0, halfBox: 18))
                let branched = try multipointHistory(editFolder)
                try require(branched?.future.isEmpty == true, "editing after undo must discard redo branch")
                let analyzed = try stackMultipoint(source, settings: settings, phase: 1)
                let analyzedID = analyzed.deletingLastPathComponent().lastPathComponent
                let analyzedBytes = try Data(contentsOf: analyzed)
                let stageA = try multipointAnalysis(source, runID: analyzedID, display: NativeDisplaySettings())
                try require(!stageA.registered && stageA.points.count == summary.points &&
                    !fm.fileExists(atPath: analyzed.deletingLastPathComponent().appendingPathComponent("result.fits").path),
                    "analyze-only must save reference and APs without shifts or stack")
                var unregisteredRejected = false
                do { _ = try resumeMultipoint(source, runID: analyzedID, phase: 3) } catch { unregisteredRejected = true }
                try require(unregisteredRejected, "stack-only accepted unregistered analysis")
                let stageEditedID = try editMultipoint(source, runID: analyzedID, edit: .remove(index: 0))
                let registered = try resumeMultipoint(source, runID: stageEditedID, phase: 2)
                let registeredID = registered.deletingLastPathComponent().lastPathComponent
                let registeredBytes = try Data(contentsOf: registered)
                let stageB = try multipointAnalysis(source, runID: registeredID, display: NativeDisplaySettings())
                try require(stageB.registered && stageB.points.count == summary.points - 1 &&
                    !fm.fileExists(atPath: registered.deletingLastPathComponent().appendingPathComponent("result.fits").path),
                    "register-only must consume edited grid, save shifts and omit stack")
                let stagedResult = try resumeMultipoint(source, runID: registeredID, phase: 3)
                guard let stagedImage = stagedResult.path.withCString({ siril_image_read($0, &error, capacity) }),
                      let combinedImage = resumed.path.withCString({ siril_image_read($0, &error, capacity) }) else {
                    throw EngineError.failed(String(cString: error))
                }
                var stagedInfo = SirilImageInfo()
                var stagedError: Float = 0
                try require(siril_image_info(stagedImage, &stagedInfo) != 0 && stagedInfo.width == 256 && stagedInfo.height == 256,
                    "staged identity geometry")
                for y in 0..<256 { for x in 0..<256 {
                    var a = [Float](repeating: 0, count: 3), b = a
                    if siril_image_pixel(stagedImage, Int32(x), Int32(y), &a) != 1 ||
                        siril_image_pixel(combinedImage, Int32(x), Int32(y), &b) != 1 { stagedError = 1 }
                    stagedError = max(stagedError, abs(a[0] - b[0]))
                } }
                siril_image_free(stagedImage); siril_image_free(combinedImage)
                try require(stagedError == 0, "staged A/edit/B/C differs from combined edited B/C: \(stagedError)")
                try require(try Data(contentsOf: analyzed) == analyzedBytes && Data(contentsOf: registered) == registeredBytes,
                    "staged processing modified its input sidecars")
                var advanced = SequenceMultipointAdvanced()
                advanced.globalSearch = 12; advanced.referencePercent = 100
                advanced.brightness = 1; advanced.contrast = 1; advanced.gridStep = 8
                advanced.referenceFrames = 2; advanced.debayer = 4; advanced.aviBayer = 2
                advanced.zeroMean = true; advanced.fastChanging = true; advanced.seed = false
                advanced.stackFrames = 1; advanced.stackMethod = 1
                var denseSettings = settings; denseSettings.advanced = advanced
                let densePath = try stackMultipoint(source, settings: denseSettings, phase: 1)
                guard let dense = densePath.path.withCString({ siril_multipoint_open($0, &error, capacity) }) else {
                    throw EngineError.failed(String(cString: error))
                }
                var baked = SirilMultipointOptions()
                let bakedOK = siril_multipoint_options(dense, &baked)
                siril_multipoint_close(dense)
                try require(bakedOK != 0 && baked.global_search == 12 && baked.reference_percent == 100 &&
                    baked.brightness == 1 && baked.contrast == 1 && baked.grid_step == 8 && baked.reference_frames == 2 &&
                    baked.debayer == 4 && baked.avi_bayer == 2 && baked.zero_mean == 1 && baked.fast_changing == 1 &&
                    baked.seed == 0 && baked.stack_frames == 1 && baked.stack_method == 1,
                    "advanced settings must reach original saved config")
                let denseID = densePath.deletingLastPathComponent().lastPathComponent
                let denseSnapshot = try multipointAnalysis(source, runID: denseID, display: NativeDisplaySettings())
                try require(denseSnapshot.points.count > summary.points &&
                    denseSnapshot.points.contains(where: { $0.patch.width < $0.box.width || $0.patch.height < $0.box.height }),
                    "dense placement must retain original independent measurement/merge sizes")
                let denseEdited = try editMultipoint(source, runID: denseID, edit: .remove(index: 0))
                let denseReopened = try multipointAnalysis(source, runID: denseEdited, display: NativeDisplaySettings())
                try require(denseReopened.points.count == denseSnapshot.points.count - 1,
                    "dense AP history wrongly requires merge patch to contain measurement box")
                var invalidAdvanced = denseSettings; invalidAdvanced.advanced?.globalSearch = 65
                var advancedRejected = false
                do { _ = try stackMultipoint(source, settings: invalidAdvanced, phase: 1) } catch { advancedRejected = true }
                try require(advancedRejected, "out-of-range advanced option accepted")
            }
            var wrongSourceRejected = false
            do { _ = try multipointAnalysis(SequenceLocation(job: source.job, name: "unrelated.seq"), runID: savedRuns[0].id, display: NativeDisplaySettings()) }
            catch { wrongSourceRejected = true }
            try require(wrongSourceRejected, "opened analysis belonging to another sequence")
            if channels == 3 { for (planet, warp) in [(true, false), (false, false), (true, true)] {
                var local = settings; local.dewarp = true; local.planet = planet
                if planet { local.refine = true; local.smoothRadius = 2.5 }
                if warp {
                    var advanced = SequenceMultipointAdvanced()
                    advanced.zeroMean = true; advanced.referenceFrames = 1
                    advanced.stackMethod = 1; advanced.stackFrames = 1
                    local.advanced = advanced; local.scale = 1.5
                }
                let warped = try stackMultipoint(source, settings: local)
                guard let aligned = warped.path.withCString({ siril_image_read($0, &error, capacity) }) else { throw EngineError.failed(String(cString: error)) }
                var alignedInfo = SirilImageInfo()
                try require(siril_image_info(aligned, &alignedInfo) != 0 && alignedInfo.channels == 3 &&
                    Double(alignedInfo.width) > 200 * local.scale && Double(alignedInfo.width) <= 256 * local.scale &&
                    Double(alignedInfo.height) > 200 * local.scale && Double(alignedInfo.height) <= 256 * local.scale,
                    "original locally aligned common-area geometry, planet=\(planet), warp=\(warp): \(alignedInfo.width)x\(alignedInfo.height)")
                var colorError: Float = 0, peak: Float = 0
                for y in 0..<Int(alignedInfo.height) { for x in 0..<Int(alignedInfo.width) {
                    var pixel = [Float](repeating: 0, count: 3)
                    if siril_image_pixel(aligned, Int32(x), Int32(y), &pixel) != 3 { colorError = 1 }
                    peak = max(peak, pixel[0])
                    colorError = max(colorError, max(abs(pixel[1] - 0.8 * pixel[0]), abs(pixel[2] - 0.6 * pixel[0])))
                } }
                siril_image_free(aligned)
                try require(peak > 0.3 && colorError < 4.0 / 65535,
                    "independent RGB linearity under original local warps and excluded bright-frame isolation, planet=\(planet), warp=\(warp), error=\(colorError)")
            } }
            try require(try Data(contentsOf: process.appendingPathComponent(source.name)) == metadata, "changed source sequence metadata")
            for (i, input) in inputs.enumerated() { try require(try Data(contentsOf: input.url) == sourceBytes[i], "changed source FITS pixels") }
            var invalid = settings; invalid.stackPercent = 101
            var rejected = false
            do { _ = try stackMultipoint(source, settings: invalid) } catch { rejected = true }
            try require(rejected, "invalid frame selection accepted")
        }
    }
}
