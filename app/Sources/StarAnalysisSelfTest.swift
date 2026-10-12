// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func starAnalysisSelfTest() async throws {
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw EngineError.failed("Star analysis: " + message) } }
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("star-tests-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [FITSRecord] = []
        defer {
            for record in records { try? fm.removeItem(at: record.url); try? fm.removeItem(at: record.url.appendingPathExtension("stars.json")) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func fixture(_ name: String, w: Int = 128, h: Int = 96, channels: Int = 1,
                     extra: [String] = [], value: (Int, Int, Int) -> Float) throws -> FITSRecord {
            let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    \(channels == 3 ? 3 : 2)", "NAXIS1  = \(w)", "NAXIS2  = \(h)"] + (channels == 3 ? ["NAXIS3  = 3"] : []) + ["EXPTIME =                   30"] + extra + ["END"]
            var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for c in 0..<channels { for row in 0..<h { for x in 0..<w {
                var encoded = value(x, h - 1 - row, c).bitPattern.bigEndian
                withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
            } } }
            bytes.append(Data(repeating: 0, count: (2880 - bytes.count % 2880) % 2880))
            let url = folder.appendingPathComponent(name + ".fits"); try bytes.write(to: url)
            let file = try importFile(url); records.append(file); return file
        }
        func gaussian(_ x: Int, _ y: Int, centerX: Double = 40, centerY: Double = 45, amplitude: Double = 0.45) -> Double {
            0.03 + amplitude * exp(-pow((Double(x) - centerX) / 3, 2) / 2 - pow((Double(y) - centerY) / 2, 2) / 2)
        }
        let gaussianFile = try fixture("gaussian", extra: ["FOCALLEN=                 1000", "XPIXSZ  =                 3.76", "YPIXSZ  =                 3.76"]) { x, y, _ in Float(gaussian(x, y)) }
        let sourceBytes = try Data(contentsOf: gaussianFile.url)
        let analysis = ImageAnalysisEngine(); _ = try await analysis.open(gaussianFile.url)
        let area = ImageSelection(x: 6, y: 10, width: 71, height: 71)
        var settings = StarSettings()
        let star = try await analysis.fitStar(region: area, settings: settings)
        try require(abs(star.x - 40.5) < 0.01 && abs(star.y - 45.5) < 0.01, "independent displayed Gaussian centre \(star.x),\(star.y)")
        let factor = sqrt(8 * log(2.0))
        try require(abs(star.fwhmX - 3 * factor) < 0.02 && abs(star.fwhmY - 2 * factor) < 0.02 && abs(star.background - 0.03) < 0.0001 && abs(star.amplitude - 0.45) < 0.001, "independent elliptical Gaussian fit")
        try require(abs(star.angularX / star.fwhmX - 206.264806 * 3.76 / 1000) < 0.00002, "pixels versus angular FWHM")
        settings.photometry = true; settings.aperture = 12
        let measured = try await analysis.fitStar(region: area, settings: settings)
        let flux = 2 * Double.pi * 3 * 2 * 0.45
        let expectedMagnitude = -2.5 * log10(flux), poisson = sqrt(flux * 2.3 * 65535)
        try require(measured.photometryValid && abs(measured.magnitude - expectedMagnitude) < 0.001, "independent wide-aperture integrated Gaussian magnitude \(measured.magnitude) != \(expectedMagnitude)")
        try require(abs(measured.magnitudeError - 1.0857 / poisson) < 0.00002 && abs(measured.snr - 10 * log10(poisson)) < 0.02, "independent Poisson uncertainty/SNR")
        // Hand-selected fits must drive the real original PSF generator,
        // with saturated stars excluded and pixel units retained.
        var saturatedNative = measured.native
        saturatedNative.saturated = 1; saturatedNative.fwhm_x = 99
        let saturated = try StarMeasurement(saturatedNative)
        var selectedRecipe = NativeToolRecipe(tool: .deconvolution, file: gaussianFile)
        selectedRecipe.values["ks"] = 9; selectedRecipe.values["estimateOnly"] = 1
        try selectedRecipe.useSelectedStars([measured, star, saturated], file: gaussianFile)
        try require(selectedRecipe.number("psfSource") == 2 && abs(selectedRecipe.number("fwhm") - 3 * factor) < 0.02 &&
            abs(selectedRecipe.number("ratio") - 1.5) < 0.01, "selected PSF means, saturated exclusion and pixel units")
        let selectedSession = NativeToolSession(); try await selectedSession.open(gaussianFile)
        try await selectedSession.compute(selectedRecipe, library: records)
        let center = try await selectedSession.pixel(view: 4, x: 4, y: 4)[0]
        let adjacent = try await selectedSession.pixel(view: 4, x: 5, y: 4)[0]
        try require(abs(adjacent / center - Float(exp(-1.0 / 18))) < 0.002, "selected original Gaussian kernel pixels")
        await selectedSession.close()
        let selectedJSON = try JSONEncoder().encode(selectedRecipe)
        let restoredSelection = try JSONDecoder().decode(NativeToolRecipe.self, from: selectedJSON)
        try require(restoredSelection == selectedRecipe, "selected PSF parameter replay")
        var symmetricRecipe = selectedRecipe; symmetricRecipe.values["symmetric"] = 1; symmetricRecipe.values["autoSize"] = 1
        try symmetricRecipe.useSelectedStars([measured], file: gaussianFile)
        try require(symmetricRecipe.number("ratio") == 1 && symmetricRecipe.number("ks") == 29, "selected symmetric PSF and original automatic kernel size")
        var invalidSelection = selectedRecipe
        var selectionRejected = false
        do { try invalidSelection.useSelectedStars([saturated], file: gaussianFile) } catch { selectionRejected = true }
        try require(selectionRejected && invalidSelection == selectedRecipe, "all-saturated selection changed PSF")
        var mixedNative = measured.native; mixedNative.channel = 1
        let mixed = try StarMeasurement(mixedNative)
        selectionRejected = false
        do { try invalidSelection.useSelectedStars([measured, mixed], file: gaussianFile) } catch { selectionRejected = true }
        try require(selectionRejected && invalidSelection == selectedRecipe, "mixed-channel selection changed PSF")
        settings.forceRadius = false
        let dynamic = try await analysis.fitStar(region: area, settings: settings)
        try require(dynamic.photometryValid && abs(dynamic.magnitude - expectedMagnitude) < 0.001, "original dynamic aperture")
        var invalid = settings; invalid.maximumPixel = 5000
        let failedPhoto = try await analysis.fitStar(region: area, settings: invalid)
        try require(!failedPhoto.photometryValid && failedPhoto.photometryError != 0 && abs(failedPhoto.fwhmX - measured.fwhmX) < 0.001, "failed photometry mislabeled or fit discarded")
        let small = try await analysis.fitStar(region: ImageSelection(x: 30, y: 35, width: 21, height: 21), settings: settings)
        try require(!small.photometryValid && small.photometryError != 0, "too-small sky annulus was marked valid")
        for convergence in 1...3 {
            var precise = StarSettings(); precise.convergence = convergence
            let fitted = try await analysis.fitStar(region: area, settings: precise)
            try require(abs(fitted.fwhmX - 3 * factor) < 0.02, "original convergence \(convergence)")
        }
        settings = StarSettings(); settings.maximum = 50
        let detected = try await analysis.findStars(region: nil, settings: settings)
        try require(detected.contains(where: { abs($0.x - 40.5) < 0.02 && abs($0.y - 45.5) < 0.02 }), "original peaker coordinates/fit")
        let excluded = try await analysis.findStars(region: ImageSelection(x: 85, y: 5, width: 35, height: 30), settings: settings)
        try require(excluded.isEmpty, "ROI detection searched outside region")
        let moffat = try fixture("moffat") { x, y, _ in
            Float(0.03 + 0.45 * pow(1 + pow(Double(x - 40) / 4, 2) + pow(Double(y - 45) / 3, 2), -2.8))
        }
        _ = try await analysis.open(moffat.url); settings.profile = 1
        let m = try await analysis.fitStar(region: area, settings: settings)
        let widthFactor = 2 * sqrt(pow(2, 1 / 2.8) - 1)
        try require(abs(m.beta - 2.8) < 0.05 && abs(m.fwhmX - 4 * widthFactor) < 0.04 && abs(m.fwhmY - 3 * widthFactor) < 0.04, "independent Moffat beta/FWHM \(m.beta),\(m.fwhmX),\(m.fwhmY)")
        let rgb = try fixture("rgb", channels: 3) { x, y, c in Float(gaussian(x, y, amplitude: 0.2 + 0.1 * Double(c))) }
        _ = try await analysis.open(rgb.url); settings = StarSettings()
        for c in 0..<3 {
            settings.channel = c
            let r = try await analysis.fitStar(region: area, settings: settings)
            try require(r.channel == c && abs(r.amplitude - (0.2 + 0.1 * Double(c))) < 0.001, "original RGB channel selection")
        }
        let cfa = try fixture("cfa", extra: ["BAYERPAT= 'BGGR'"]) { x, y, _ in Float(gaussian(x, y)) }
        _ = try await analysis.open(cfa.url); settings = StarSettings()
        let cfaStars = try await analysis.findStars(region: nil, settings: settings)
        try require(cfaStars.contains(where: { abs($0.x - 40.5) < 0.3 && abs($0.y - 45.5) < 0.3 }), "original CFA green-interpolation finder")
        var badSettings = settings; badSettings.sigma = .nan
        var invalidSucceeded = false
        do { _ = try await analysis.fitStar(region: area, settings: badSettings); invalidSucceeded = true } catch {}
        try require(!invalidSucceeded, "nonfinite star settings accepted")
        invalidSucceeded = false
        do { _ = try await analysis.fitStar(region: ImageSelection(x: -1, y: 0, width: 71, height: 71), settings: settings); invalidSucceeded = true } catch {}
        try require(!invalidSucceeded, "outside-image PSF region accepted")
        _ = try await analysis.open(gaussianFile.url); settings = StarSettings()
        let lst = folder.appendingPathComponent("stars.lst"), table = folder.appendingPathComponent("stars.fits")
        try await analysis.saveStars([measured], settings: settings, to: lst, fitsTable: false)
        try await analysis.saveStars([measured], settings: settings, to: table, fitsTable: true)
        try require(try String(contentsOf: lst).contains("Gaussian") && Data(contentsOf: table).count >= 5760, "original .lst/FITS table export")
        let tableBytes = try Data(contentsOf: table)
        var overwritten = false
        do { try await analysis.saveStars([m], settings: settings, to: table, fitsTable: true); overwritten = true } catch {}
        try require(!overwritten && (try Data(contentsOf: table)) == tableBytes, "star table overwrote existing file")
        var h = StarHistory(file: gaussianFile); h.record(StarEdit(settings: settings, stars: [measured, star]))
        h.record(StarEdit(settings: settings, stars: [measured])); h.undo()
        try require(h.current.stars.count == 2, "star deletion undo")
        try h.save(for: gaussianFile); var reopened = try StarHistory.load(for: gaussianFile); reopened.redo()
        try require(reopened.current.stars.count == 1, "persistent star deletion redo")
        reopened.undo(); reopened.record(StarEdit(settings: settings, stars: [star])); try require(reopened.future.isEmpty, "star history branch")
        try reopened.save(for: gaussianFile); let historyBytes = try Data(contentsOf: StarHistory.url(for: gaussianFile))
        try saveLibrary(baseline + records)
        _ = try moveToTrash(ids: [gaussianFile.id])
        guard let trash = trashEntries().first(where: { $0.records.contains(where: { $0.id == gaussianFile.id }) }) else { throw EngineError.failed("Star analysis trash missing") }
        try require(!fm.fileExists(atPath: try StarHistory.url(for: gaussianFile).path), "star sidecar left after gallery deletion")
        _ = try restoreTrash(trash.id)
        try require(try Data(contentsOf: StarHistory.url(for: gaussianFile)) == historyBytes && Data(contentsOf: gaussianFile.url) == sourceBytes, "star history/source byte-exact restoration")
        // Five reference stars each lose a different frame: every reference
        // passes the original 80% rule, but their simultaneous intersection is empty.
        // The original engine must reject the curve without a zero-sized GSL plot.
        var disjoint: [FITSRecord] = []
        for frame in 0..<5 {
            disjoint.append(try fixture("disjoint-\(frame)", w: 512, h: 96) { x, y, _ in
                var signal = 0.03
                for index in 0..<6 {
                    let amplitude = index > 0 && index - 1 == frame ? 1.1 : 0.15
                    signal += amplitude * exp(-(pow(Double(x - (40 + index * 80)), 2) + pow(Double(y - 45), 2)) / 18)
                }
                return Float(signal)
            })
        }
        let disjointJob = try createSequence(files: disjoint)
        defer { try? fm.removeItem(at: disjointJob.folder) }
        guard let disjointLocation = sequenceLocations(job: disjointJob.folder.lastPathComponent).first else { throw EngineError.failed("Missing disjoint-reference sequence") }
        var disjointRecipe = SequencePhotometryRecipe(); disjointRecipe.framing = 0; disjointRecipe.settings.aperture = 12
        disjointRecipe.regions = (0..<6).map { ImageSelection(x: 5 + $0 * 80, y: 10, width: 71, height: 71) }
        let disjointReportURL = try sequencePhotometry(disjointLocation, recipe: disjointRecipe)
        let disjointReport = try JSONDecoder().decode(SequencePhotometryReport.self, from: Data(contentsOf: disjointReportURL.appendingPathComponent("report.json")))
        for index in 1..<6 {
            try require(disjointReport.rows.filter { $0.star == index && $0.measurement?.photometryValid == true }.count == 4, "disjoint references did not exercise the original 80% rule")
        }
        disjointRecipe.lightCurve = true; disjointRecipe.settings.forceRadius = false
        var emptyCurveSucceeded = false
        do { _ = try sequencePhotometry(disjointLocation, recipe: disjointRecipe); emptyCurveSucceeded = true } catch {}
        try require(!emptyCurveSucceeded, "empty simultaneous reference intersection created a light curve")
        try await sequencePhotometrySelfTest(folder: folder, fixture: { name, factor, shift, minute in
            try fixture(name, w: 256, h: 128, extra: ["DATE-OBS= '2026-10-12T10:0\(minute):00.000'"]) { x, y, _ in
                let dx = Double(x) - (64 + shift), dy = Double(y - 64)
                let target = 0.15 * factor * exp(-(dx * dx + dy * dy) / 18)
                let reference = 0.15 * exp(-(pow(Double(x - 192), 2) + dy * dy) / 18)
                return Float(0.03 + target + reference)
            }
        })
        _ = try moveToTrash(ids: [gaussianFile.id])
        guard let finalTrash = trashEntries().first(where: { $0.records.contains(where: { $0.id == gaussianFile.id }) }) else { throw EngineError.failed("Star final trash missing") }
        try permanentlyDeleteTrash([finalTrash.id])
        try require(!fm.fileExists(atPath: try StarHistory.url(for: gaussianFile).path), "permanent star history cleanup")
        print("PASS: original dynamic Gaussian/Moffat PSF, independent centres/FWHM/Poisson photometry, finder ROI/RGB, tables, persistent star undo/delete/restore and original sequence differential light curve")
    }
    private func sequencePhotometrySelfTest(folder: URL, fixture: (String, Double, Double, Int) throws -> FITSRecord) async throws {
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw EngineError.failed("Sequence photometry: " + message) } }
        let factors = [1.0, 2.0, 1.5], shifts = [0.0, 2.0, 4.0]
        let files = try factors.indices.map { try fixture("sequence-\($0)", factors[$0], shifts[$0], $0) }
        let job = try createSequence(files: files)
        defer { try? FileManager.default.removeItem(at: job.folder) }
        guard let location = sequenceLocations(job: job.folder.lastPathComponent).first else { throw EngineError.failed("Photometry test sequence missing") }
        let process = try sequenceFolder(location)
        let sources = try FileManager.default.contentsOfDirectory(at: process, includingPropertiesForKeys: nil).filter { ["seq", "fit", "fits"].contains($0.pathExtension) }
        let original = try sources.map { ($0, try Data(contentsOf: $0)) }
        var recipe = SequencePhotometryRecipe()
        recipe.current = 0; recipe.framing = 1; recipe.lightCurve = true; recipe.settings.aperture = 12
        recipe.regions = [ImageSelection(x: 29, y: 29, width: 71, height: 71), ImageSelection(x: 157, y: 29, width: 71, height: 71)]
        var edits = SequencePhotometryHistory(source: location)
        edits.record(recipe)
        var removed = recipe; removed.regions.removeLast(); edits.record(removed); edits.undo()
        try savePhotometryHistory(edits)
        let reopened = SirilEngine(); var restored = try await reopened.photometryHistory(location)
        try require(restored.current == recipe && !restored.future.isEmpty, "persisted sequence region undo")
        restored.redo(); try require(restored.current == removed, "sequence region redo")
        restored.undo(); restored.record(SequencePhotometryRecipe()); try require(restored.future.isEmpty, "sequence photometry history branch")
        let result = try sequencePhotometry(location, recipe: recipe)
        let reportURL = result.appendingPathComponent("report.json")
        let report = try JSONDecoder().decode(SequencePhotometryReport.self, from: Data(contentsOf: reportURL))
        try require(report.rows.count == 6 && report.rows.allSatisfy({ $0.measurement?.photometryValid == true }) && report.curve.count == 3, "actual per-frame original photometry/differential curve")
        for i in factors.indices {
            let point = report.curve[i]
            let predicted = -2.5 * log10(factors[i])
            try require(abs(point.magnitude - predicted) < 0.001, "independent flux-ratio differential magnitude \(point.magnitude) != \(predicted)")
            try require(abs((point.time - report.curve[0].time) * 86400 - Double(i * 60)) < 0.08, "original Julian mid-exposure timestamps")
            let measurement = report.rows.first { $0.star == 0 && $0.frame == i }!.measurement!
            try require(abs(measurement.x - (64.5 + shifts[i])) < 0.02 && abs(measurement.y - 64.5) < 0.02, "original follow-star coordinates")
        }
        for (url, bytes) in original { try require(try Data(contentsOf: url) == bytes, "PSF analysis changed original sequence or FITS") }
        let state = try inspectSequence(location)
        var included = state.selection; included.included[1] = false; try editSequence(location, selection: included)
        recipe.framing = 0
        let subset = try sequencePhotometry(location, recipe: recipe)
        let subsetReport = try JSONDecoder().decode(SequencePhotometryReport.self, from: Data(contentsOf: subset.appendingPathComponent("report.json")))
        try require(subsetReport.curve.count == 2 && subsetReport.rows.filter { $0.frame == 1 }.allSatisfy({ !$0.included && $0.measurement == nil }), "excluded frame entered photometry")
        recipe.framing = 2; recipe.lightCurve = false
        let fallback = try sequencePhotometry(location, recipe: recipe)
        let fallbackReport = try JSONDecoder().decode(SequencePhotometryReport.self, from: Data(contentsOf: fallback.appendingPathComponent("report.json")))
        try require(fallbackReport.rows.filter(\.included).allSatisfy { $0.measurement != nil }, "registered framing original fallback")
        let saved = try Data(contentsOf: reportURL)
        guard let task = jobHistory().first(where: { $0.id == location.job }) else { throw EngineError.failed("Photometry parent task missing") }
        try trashJob(task)
        guard let trash = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("Photometry task trash missing") }
        try require(!FileManager.default.fileExists(atPath: reportURL.path), "photometry report not removed with task")
        _ = try restoreTrash(trash.id)
        try require(try Data(contentsOf: reportURL) == saved, "original light-curve report restoration")
        try trashJob(task)
        guard let final = trashEntries().first(where: { $0.jobName == location.job }) else { throw EngineError.failed("Photometry final task trash missing") }
        try permanentlyDeleteTrash([final.id])
        try require(!FileManager.default.fileExists(atPath: job.folder.path), "permanent photometry cleanup")
    }
}
