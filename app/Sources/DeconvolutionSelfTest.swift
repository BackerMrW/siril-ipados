// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func deconvolutionSelfTest(file: FITSRecord, expected: [Float], x: Int, y: Int) async throws -> [ProcessingJob] {
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw EngineError.failed("Deconvolution: " + message) } }
        let fm = FileManager.default, sourceBytes = try Data(contentsOf: file.url)
        let folder = documents.appendingPathComponent("deconv-tests-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        var records = [file], jobs: [ProcessingJob] = []
        defer { for item in records.dropFirst() { try? fm.removeItem(at: item.url); try? fm.removeItem(at: item.url.appendingPathExtension("tools.json")) } }
        func fixture(name: String, w: Int, h: Int, channels: Int, values: [Float]) throws -> FITSRecord {
            let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    \(channels == 3 ? 3 : 2)", "NAXIS1  = \(w)", "NAXIS2  = \(h)"] + (channels == 3 ? ["NAXIS3  =                    3"] : []) + ["ROWORDER= 'TOP-DOWN'", "END"]
            var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for c in 0..<channels { for row in 0..<h { for col in 0..<w {
                var value = values[c * w * h + (h - 1 - row) * w + col].bitPattern.bigEndian
                withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
            } } }
            bytes.append(Data(repeating: 0, count: (2880 - bytes.count % 2880) % 2880))
            let url = folder.appendingPathComponent(name + ".fits"); try bytes.write(to: url)
            let record = try importFile(url); records.append(record); return record
        }
        var delta = [Float](repeating: 0, count: 27)
        for c in 0..<3 { delta[c * 9 + 4] = 1 }
        let rgbKernel = try fixture(name: "rgb-delta", w: 3, h: 3, channels: 3, values: delta)
        let monoKernel = try fixture(name: "mono-delta", w: 3, h: 3, channels: 1, values: Array(delta.prefix(9)))
        let emptyKernel = try fixture(name: "zero-psf", w: 3, h: 3, channels: 1, values: [Float](repeating: 0, count: 9))
        let constant = try fixture(name: "constant", w: 32, h: 32, channels: 1, values: [Float](repeating: 0.25, count: 1024))
        let black = try fixture(name: "black", w: 32, h: 32, channels: 1, values: [Float](repeating: 0, count: 1024))
        let session = NativeToolSession(); try await session.open(file)
        var recipe = NativeToolRecipe(tool: .deconvolution, file: file)
        recipe.values["psfSource"] = 2; recipe.values["ks"] = 9; recipe.values["estimateOnly"] = 1
        recipe.values["ratio"] = 1.5; recipe.values["angle"] = 30
        try await session.compute(recipe, library: records)
        let kernelInfo = try await session.info(view: 4)
        try require(kernelInfo.width == 9 && kernelInfo.height == 9 && kernelInfo.channels == 1, "original manual PSF shape")
        // TOP-DOWN sensor metadata makes save_kernel flip to canonical FITS
        // order; the displayed PSF reverses FITS rows back to these coordinates.
        let theta = -Double.pi / 6, sx = 3 / sqrt(8 * log(2.0)), sy = sx / 1.5
        let aa = pow(cos(theta), 2) / (2 * sx * sx) + pow(sin(theta), 2) / (2 * sy * sy)
        let bb = sin(2 * theta) / (4 * sx * sx) - sin(2 * theta) / (4 * sy * sy)
        let cc = pow(sin(theta), 2) / (2 * sx * sx) + pow(cos(theta), 2) / (2 * sy * sy)
        for py in 0..<9 { for px in 0..<9 {
            let u = Double(px - 4), v = Double(py - 4)
            let predicted = exp(-(aa * u * u + 2 * bb * u * v + cc * v * v))
            let pixel = try await session.pixel(view: 4, x: px, y: py)[0]
            try require(abs(Double(pixel) - predicted) < 0.000003, "independent elliptical Gaussian PSF")
        } }
        let same = try await session.pixel(view: 1, x: x, y: y)
        try require(same == expected, "PSF-only computation changed source pixels")
        let psfJob = try prepareNativeToolJob(file: file, recipe: recipe, library: records); jobs.append(psfJob)
        let psfURL = try await session.export(recipe, to: psfJob)
        try require(psfURL.lastPathComponent == "native-psf.fits" && !fm.fileExists(atPath: psfJob.folder.appendingPathComponent("process/result.fits").path), "PSF-only save duplicated the full source")
        let savedPSF = try importFile(psfURL, role: .results); records.append(savedPSF)
        recipe.values["profile"] = 1; recipe.values["angle"] = 0; recipe.values["ratio"] = 1.2
        try await session.compute(recipe, library: records)
        for py in 0..<9 { for px in 0..<9 {
            let u = Double(px - 4), v = Double(py - 4), alpha = 0.6667 * 3
            let predicted = pow(1 + u * u / (alpha * alpha) + v * v / pow(alpha / 1.2, 2), -4.5)
            let pixel = try await session.pixel(view: 4, x: px, y: py)[0]
            try require(abs(Double(pixel) - predicted) < 0.000003, "independent Moffat PSF")
        } }
        for profile in [2, 3] {
            recipe.values["profile"] = Double(profile)
            recipe.values["diameter"] = 150; recipe.values["focal"] = 750; recipe.values["pixelSize"] = 3.76; recipe.values["obstruction"] = 20
            try await session.compute(recipe, library: records)
            let center = try await session.pixel(view: 4, x: 4, y: 4)[0]
            try require(center.isFinite && center > 0, "original Disc/Airy PSF missing")
        }
        recipe = NativeToolRecipe(tool: .deconvolution, file: file)
        recipe.values["psfSource"] = 3; recipe.psfID = rgbKernel.id
        recipe.values["rlMethod"] = 0; recipe.values["regularization"] = 2; recipe.values["iterations"] = 1
        try await session.compute(recipe, library: records)
        let identity = try await session.pixel(view: 1, x: x, y: y)
        try require(zip(identity, expected).allSatisfy { abs($0.0 - $0.1) < 0.00003 }, "independent multiplicative RL unit-PSF identity")
        let rgbInfo = try await session.info(view: 4)
        let rgbPSF = try await session.pixel(view: 4, x: 1, y: 1)
        try require(rgbInfo.channels == 3 && rgbPSF == [1, 1, 1], "RGB PSF export overread/wrong channels")
        let resultJob = try prepareNativeToolJob(file: file, recipe: recipe, library: records); jobs.append(resultJob)
        let output = try await session.export(recipe, to: resultJob)
        let imported = try importNativeResult(output, parent: file.id); records += imported
        try require(imported.count == 2 && imported.first!.url.lastPathComponent.hasSuffix("native-psf.fits") && imported.last!.parentID == file.id, "result and actual PSF not imported independently")
        let replay = try prepareNativeToolJob(file: file, recipe: recipe, library: records); jobs.append(replay)
        _ = try run(replay)
        let reader = ImageAnalysisEngine(); _ = try await reader.open(replay.folder.appendingPathComponent("process/result.fits"))
        let replayed = try await reader.pixel(x: x, y: y).values
        try require(zip(replayed, identity).allSatisfy { abs($0.0 - $0.1) < 0.000001 }, "saved custom-PSF recipe/input replay")
        recipe.psfID = monoKernel.id
        try await session.compute(recipe, library: records)
        let monoIdentity = try await session.pixel(view: 1, x: x, y: y)
        try require(zip(monoIdentity, expected).allSatisfy { abs($0.0 - $0.1) < 0.00004 }, "original mono-kernel RGB luminance pipeline identity")
        recipe.values["method"] = 2; recipe.values["alpha"] = 500; recipe.psfID = rgbKernel.id
        try await session.compute(recipe, library: records)
        let wiener = try await session.pixel(view: 1, x: x, y: y)
        try require(zip(wiener, expected).allSatisfy { abs($0.0 - $0.1 / 1.002) < 0.00004 }, "independent Wiener unit-PSF frequency gain")
        var masked = recipe; masked.mask.values["mode"] = 2
        try await session.compute(masked, library: records)
        let blended = try await session.pixel(view: 1, x: x, y: y)
        let mask = try await session.pixel(view: 2, x: x, y: y)[0]
        for c in 0..<3 { try require(abs(blended[c] - (expected[c] * (1 - mask) + wiener[c] * mask)) < 0.00002, "original deconvolution mask blend") }
        let flatSession = NativeToolSession(); try await flatSession.open(constant)
        for method in [0, 1, 2] {
            var flat = NativeToolRecipe(tool: .deconvolution, file: constant)
            flat.values["psfSource"] = 3; flat.psfID = monoKernel.id; flat.values["method"] = Double(method)
            flat.values["iterations"] = 2; flat.values["rlMethod"] = 0; flat.values["regularization"] = 2; flat.values["alpha"] = 500
            try await flatSession.compute(flat, library: records)
            let pixel = try await flatSession.pixel(view: 1, x: 16, y: 16)[0]
            let predicted: Float = method == 2 ? 0.25 / 1.002 : 0.25
            try require(abs(pixel - predicted) < 0.0001, "independent constant fixed point for original SB/RL/Wiener")
            if method == 1 {
                for rlMethod in [0, 1] { for regularization in [0, 1, 2] {
                    flat.values["rlMethod"] = Double(rlMethod); flat.values["regularization"] = Double(regularization); flat.values["stopping"] = 1
                    try await flatSession.compute(flat, library: records)
                    let pixel = try await flatSession.pixel(view: 1, x: 16, y: 16)[0]
                    try require(abs(pixel - 0.25) < 0.0001, "original RL methods/regularizers/stopping constant pixels")
                } }
            }
        }
        await flatSession.close()
        var generated = NativeToolRecipe(tool: .deconvolution, file: file)
        generated.values["estimateOnly"] = 1; generated.values["ks"] = 9; generated.values["psfSource"] = 1
        try await session.compute(generated, library: records)
        let measured = try await session.pixel(view: 4, x: 5, y: 4)[0]
        try require(abs(measured - exp(-0.125)) < 0.035, "star PSF did not use measured known Gaussian width")
        var opticalBytes = sourceBytes
        for (index, card) in ["FOCALLEN=               1000.0", "APERTURE=                150.0", "XPIXSZ  =                 3.76", "YPIXSZ  =                 3.76", "END"].enumerated() {
            let text = card.padding(toLength: 80, withPad: " ", startingAt: 0)
            let offset = (7 + index) * 80
            opticalBytes.replaceSubrange(offset..<(offset + 80), with: text.utf8)
        }
        let opticalURL = folder.appendingPathComponent("optical-metadata.fits"); try opticalBytes.write(to: opticalURL)
        let optical = try importFile(opticalURL); records.append(optical)
        let opticalSession = NativeToolSession(); try await opticalSession.open(optical)
        let opticalInfo = try await opticalSession.info(view: 0)
        try require(opticalInfo.focal_length == 1000 && opticalInfo.aperture == 150 && abs(opticalInfo.pixel_size_x - 3.76) < 0.00001, "original parsed FITS optical metadata bridge")
        let opticalRecipe = generated
        try await opticalSession.compute(opticalRecipe, library: records)
        let opticalKernel = try await opticalSession.pixel(view: 4, x: 5, y: 4)[0]
        try require(abs(opticalKernel - measured) < 0.00003, "angular metadata changed the pixel PSF width")
        await opticalSession.close()
        generated.values["psfSource"] = 0; generated.values["ks"] = 7; generated.values["blindIterations"] = 1
        for blind in [1, 0] {
            generated.values["blindMethod"] = Double(blind); generated.values["inner"] = 2; generated.values["outer"] = 1; generated.values["tries"] = 4
            try await session.compute(generated, library: records)
            let info = try await session.info(view: 4), center = try await session.pixel(view: 4, x: 3, y: 3)
            try require(info.width == 7 && center.allSatisfy(\.isFinite), "original ℓ0/SI blind kernel")
        }
        generated.values["blindMethod"] = 1; generated.values["multiscale"] = 1
        try await session.compute(generated, library: records)
        let multi = try await session.pixel(view: 4, x: 3, y: 3)
        try require(multi.allSatisfy(\.isFinite), "original multiscale PSF")
        recipe.psfID = emptyKernel.id
        var rejected = false
        do { try await session.compute(recipe, library: records) } catch { rejected = true }
        try require(rejected, "zero-normalization PSF accepted")
        rejected = false
        do { _ = try await session.export(recipe, to: resultJob) } catch { rejected = true }
        try require(rejected, "failed deconvolution exported stale result")
        let blackSession = NativeToolSession(); try await blackSession.open(black)
        var blackRecipe = NativeToolRecipe(tool: .deconvolution, file: black); blackRecipe.values["psfSource"] = 3; blackRecipe.psfID = monoKernel.id
        blackRecipe.values["regularization"] = 2; blackRecipe.values["rlMethod"] = 0; blackRecipe.values["iterations"] = 1
        rejected = false
        do { try await blackSession.compute(blackRecipe, library: records) } catch { rejected = true }
        try require(rejected, "original RL zero-channel error was reported as success")
        blackRecipe.values["psfSource"] = 1; blackRecipe.values["estimateOnly"] = 1
        rejected = false
        do { try await blackSession.compute(blackRecipe, library: records) } catch { rejected = true }
        try require(rejected, "empty-image star PSF was reported successful")
        await blackSession.close(); await session.close()
        var history = NativeToolHistory(sourceID: file.id, width: file.width, height: file.height, current: recipe)
        var previous = recipe; previous.psfID = rgbKernel.id; history.record(previous); history.step(redo: false)
        try saveNativeToolHistory(history, file: file)
        let restored = try nativeToolHistory(file, tool: .deconvolution)
        try require(restored.current == recipe && restored.future == [previous], "PSF source/settings persistent undo/redo")
        let existing = loadLibrary(); try saveLibrary(existing + imported)
        let outputBytes = try imported.map { try Data(contentsOf: $0.url) }
        _ = try moveToTrash(ids: Set(imported.map(\.id)))
        guard let trash = trashEntries().first(where: { Set($0.records.map(\.id)) == Set(imported.map(\.id)) }) else { throw EngineError.failed("Deconvolution pair trash missing") }
        _ = try restoreTrash(trash.id)
        try require(try imported.map { try Data(contentsOf: $0.url) } == outputBytes, "restored result/PSF bytes changed")
        _ = try moveToTrash(ids: Set(imported.map(\.id)))
        try permanentlyDeleteTrash(Set(trashEntries().filter { $0.records.contains(where: { imported.map(\.id).contains($0.id) }) }.map(\.id)))
        try require(imported.allSatisfy { !fm.fileExists(atPath: $0.url.path) }, "result/PSF permanent cleanup failed")
        try saveLibrary(existing)
        try require(try Data(contentsOf: file.url) == sourceBytes, "deconvolution changed imported source")
        return jobs
    }
}
