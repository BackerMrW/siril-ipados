// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func fftToolSelfTest() async throws -> [ProcessingJob] {
        func require(_ ok: Bool, _ text: String) throws { if !ok { throw EngineError.failed("FFT: " + text) } }
        let fm = FileManager.default
        let folder = documents.appendingPathComponent("fft-tests-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        var records: [FITSRecord] = [], jobs: [ProcessingJob] = []
        defer { for file in records { try? fm.removeItem(at: file.url); try? fm.removeItem(at: file.url.appendingPathExtension("tools.json")) } }
        // Odd, rectangular input catches incorrect shifts and accidental swaps.
        // Direct DFT is deliberately independent of Siril/FFTW, in FITS row order.
        let w = 7, h = 5, n = w * h
        for channels in [1, 3] { for blank in [false, true] {
            var values = [Float]()
            for i in 0..<(channels * n) {
                let base = 0.1 + Double(i / n) * 0.12
                let column = Double(i % w) * 0.021
                let row = Double((i % n) / w) * 0.013
                let impulse = i % n == 9 ? 0.3 : 0.0
                values.append(blank ? 0 : Float(base + column + row + impulse))
            }
            let cards = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    \(channels == 1 ? 2 : 3)", "NAXIS1  =                    \(w)", "NAXIS2  =                    \(h)"] + (channels == 3 ? ["NAXIS3  =                    3"] : []) + ["END"]
            var data = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for v in values { var bits = v.bitPattern.bigEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
            data.append(Data(repeating: 0, count: (2880 - data.count % 2880) % 2880))
            let fixture = folder.appendingPathComponent("fft-\(channels)-\(blank).fits"); try data.write(to: fixture)
            let file = try importFile(fixture); records.append(file)
            let inputBytes = try Data(contentsOf: file.url)
            let session = NativeToolSession(); try await session.open(file)
            var magnitudes = [[Double]](), phases = [[Double]](), norms = [Double]()
            for c in 0..<channels {
                var mag = [Double](), ph = [Double]()
                for ky in 0..<h { for kx in 0..<w {
                    var re = 0.0, im = 0.0
                    for y in 0..<h { for x in 0..<w {
                        let angle = -2 * Double.pi * (Double(kx * x) / Double(w) + Double(ky * y) / Double(h))
                        let v = Double(values[c * n + y * w + x]); re += v * cos(angle); im += v * sin(angle)
                    } }
                    mag.append(hypot(re, im)); ph.append(atan2(im, re))
                } }
                magnitudes.append(mag); phases.append(ph); norms.append(mag.max()!)
            }
            for order in [0, 1] {
                var forward = NativeToolRecipe(tool: .fftDirect, file: file); forward.values["order"] = Double(order)
                try await session.compute(forward, library: records)
                for y in 0..<h { for x in 0..<w {
                    let kx = order == 0 ? (x + w / 2) % w : x
                    let ky = order == 0 ? (h - 1 - y + h / 2) % h : h - 1 - y
                    let amplitude = try await session.pixel(view: 1, x: x, y: y)
                    let phase = try await session.pixel(view: 3, x: x, y: y)
                    for c in 0..<channels {
                        let expected = norms[c] > 0 ? magnitudes[c][ky * w + kx] / norms[c] : 0
                        try require(abs(Double(amplitude[c]) - expected) < 0.000003, "independent DFT modulus/odd shift, c=\(c), x=\(x), y=\(y)")
                        // Phase of zero coefficients is undefined; compare significant bins only.
                        if magnitudes[c][ky * w + kx] > 0.0001 {
                            let expectedPhase = (phases[c][ky * w + kx] + Double.pi) / (2 * Double.pi)
                            let delta = abs(Double(phase[c]) - expectedPhase)
                            try require(min(delta, abs(delta - 1)) < 0.0001, "independent DFT phase")
                        }
                        try require(phase[c].isFinite, "zero-plane phase is not finite")
                    }
                } }
                let job = try prepareNativeToolJob(file: file, recipe: forward, library: records); jobs.append(job)
                let amplitudeURL = try await session.export(forward, to: job)
                let phaseURL = job.folder.appendingPathComponent("process/fft-phase.fits")
                let amplitude = try importFile(amplitudeURL, role: .results), phase = try importFile(phaseURL, role: .results)
                records += [amplitude, phase]
                let spectrumBytes = try Data(contentsOf: amplitude.url), phaseBytes = try Data(contentsOf: phase.url)
                let inverseSession = NativeToolSession(); try await inverseSession.open(amplitude)
                var inverse = NativeToolRecipe(tool: .fftInverse, file: amplitude); inverse.phaseID = phase.id
                try await inverseSession.compute(inverse, library: records)
                let header = try await inverseSession.header(view: 1)
                try require(!header.contains("DFTTYPE") && !header.contains("DFTORD"), "spatial inverse retained stale DFT metadata")
                for y in 0..<h { for x in 0..<w {
                    let restored = try await inverseSession.pixel(view: 1, x: x, y: y)
                    for c in 0..<channels { try require(abs(restored[c] - values[c * n + (h - 1 - y) * w + x]) < 0.000005, "inverse round-trip full-resolution pixels") }
                } }
                if channels == 3 && !blank {
                    let replay = try prepareNativeToolJob(file: amplitude, recipe: inverse, library: records); jobs.append(replay)
                    _ = try run(replay)
                    let reader = ImageAnalysisEngine(); _ = try await reader.open(replay.folder.appendingPathComponent("process/result.fits"))
                    let pixel = try await reader.pixel(x: 2, y: 1).values
                    for c in 0..<channels { try require(abs(pixel[c] - values[c * n + (h - 2) * w + 2]) < 0.000005, "inverse copied-pair script replay") }
                    let forwardReplay = try prepareNativeToolJob(file: file, recipe: forward, library: records); jobs.append(forwardReplay)
                    let outputs = try run(forwardReplay)
                    try require(outputs.contains(where: { $0.lastPathComponent == "fft-phase.fits" }), "forward replay lost second spectrum")
                    var history = NativeToolHistory(sourceID: amplitude.id, width: w, height: h, current: inverse)
                    var changed = inverse; changed.phaseID = amplitude.id
                    history.record(changed); history.step(redo: false)
                    try saveNativeToolHistory(history, file: amplitude)
                    let restoredHistory = try nativeToolHistory(amplitude, tool: .fftInverse)
                    try require(restoredHistory.current == inverse && restoredHistory.future == [changed], "persisted FFT pair undo/redo")
                    inverse.phaseID = amplitude.id
                    var rejected = false
                    do { try await inverseSession.compute(inverse, library: records) } catch { rejected = true }
                    try require(rejected, "SPECTRUM incorrectly accepted as PHASE")
                    rejected = false
                    do { _ = try await inverseSession.export(inverse, to: job) } catch { rejected = true }
                    try require(rejected, "failed inverse exported stale result")
                    inverse.phaseID = file.id
                    rejected = false
                    do { try await inverseSession.compute(inverse, library: records) } catch { rejected = true }
                    try require(rejected, "ordinary input incorrectly accepted as phase spectrum")
                }
                await inverseSession.close()
                try require(try Data(contentsOf: amplitude.url) == spectrumBytes && Data(contentsOf: phase.url) == phaseBytes, "inverse changed pair inputs")
                // Task deletion includes both spectrum files and saved JSON, and restoration is exact.
                guard let task = jobHistory().first(where: { $0.id == job.folder.lastPathComponent }) else { throw EngineError.failed("FFT task missing") }
                let savedPhase = try Data(contentsOf: phaseURL)
                try trashJob(task)
                guard let entry = trashEntries().first(where: { $0.jobName == task.id }) else { throw EngineError.failed("FFT task trash missing") }
                _ = try restoreTrash(entry.id)
                try require(try Data(contentsOf: phaseURL) == savedPhase, "task restoration lost original phase bytes")
            }
            await session.close()
            try require(try Data(contentsOf: file.url) == inputBytes, "FFT changed original")
        } }
        // Desktop integer spectra are inverted using Siril's own ushort kernel,
        // including its rounding, then normalized through the original converter.
        let intCards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    3", "NAXIS1  =                    7", "NAXIS2  =                    5", "NAXIS3  =                    3", "BZERO   =                32768", "BSCALE  =                    1", "END"]
        var intBytes = Data(intCards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
        var intValues = [UInt16]()
        for i in 0..<(3 * n) {
            let value = UInt16(12000 + (i / n) * 7000 + (i % n) * 170)
            intValues.append(value)
            var encoded = (value ^ 0x8000).bigEndian
            withUnsafeBytes(of: &encoded) { intBytes.append(contentsOf: $0) }
        }
        intBytes.append(Data(repeating: 0, count: (2880 - intBytes.count % 2880) % 2880))
        let intURL = folder.appendingPathComponent("desktop-integer.fits"); try intBytes.write(to: intURL)
        let integer = try importFile(intURL); records.append(integer)
        let intScript = "set16bits\nload lights/frame_00001.fits\nfftd process/fft-modulus.fits process/fft-phase.fits\nclose\nset32bits\n"
        let integerJob = try prepareJob(files: [integer], script: intScript); jobs.append(integerJob)
        _ = try run(integerJob)
        let integerModulus = try importFile(integerJob.folder.appendingPathComponent("process/fft-modulus.fits"), role: .results)
        let integerPhase = try importFile(integerJob.folder.appendingPathComponent("process/fft-phase.fits"), role: .results)
        records += [integerModulus, integerPhase]
        let integerSession = NativeToolSession(); try await integerSession.open(integerModulus)
        var inverse = NativeToolRecipe(tool: .fftInverse, file: integerModulus); inverse.phaseID = integerPhase.id
        try await integerSession.compute(inverse, library: records)
        for y in 0..<h { for x in 0..<w {
            let restored = try await integerSession.pixel(view: 1, x: x, y: y)
            for c in 0..<3 {
                let expected = Float(intValues[c * n + (h - 1 - y) * w + x]) / 65535
                try require(abs(restored[c] - expected) < 0.0003, "original integer FFT pair inverse precision")
            }
        } }
        await integerSession.close()
        return jobs
    }
}
