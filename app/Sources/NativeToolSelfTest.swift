// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func nativeToolSelfTest() async throws {
        func require(_ ok: Bool, _ text: String) throws { if !ok { throw EngineError.failed("Native tools: " + text) } }
        let fm = FileManager.default
        let folder = documents.appendingPathComponent("native-tools-test-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let width = 96, height = 96
        let header = ["SIMPLE  =                    T", "BITPIX  =                  -32", "NAXIS   =                    3", "NAXIS1  =                   96", "NAXIS2  =                   96", "NAXIS3  =                    3", "ROWORDER= 'TOP-DOWN'", "END"].map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined().padding(toLength: 2880, withPad: " ", startingAt: 0)
        var bytes = Data(header.utf8)
        var values: [Float] = []
        for c in 0..<3 { for y in 0..<height { for x in 0..<width {
            let bases = [0.12, 0.32, 0.22]
            let dx = Double(x - 45), dy = Double(y - 48)
            let pixel = Float(bases[c] + 0.0002 * Double(x) + 0.0001 * Double(y) + 0.2 * exp(-(dx * dx + dy * dy) / 8))
            values.append(pixel)
            var encoded = pixel.bitPattern.bigEndian
            withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
        } } }
        bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
        let fixture = folder.appendingPathComponent("tools-rgb.fits"); try bytes.write(to: fixture)
        let file = try importFile(fixture)
        defer { try? fm.removeItem(at: file.url); try? fm.removeItem(at: file.url.appendingPathExtension("tools.json")) }
        let sourceBytes = try Data(contentsOf: file.url)
        let session = NativeToolSession(); try await session.open(file)
        let x = 21, y = 25
        let expected = (0..<3).map { values[$0 * width * height + y * width + x] }
        let original = try await session.pixel(view: 0, x: x, y: y)
        try require(original == expected, "independent top-down fixture did not read exact planes")
        var records = [file]
        var jobs: [ProcessingJob] = []
        // Every actual native tool must execute, return finite full-resolution
        // pixels and preserve the original. No fake success from command text.
        for tool in NativeTool.allCases {
            var recipe = NativeToolRecipe(tool: tool, file: file)
            if tool == .crop { recipe.values["x"] = 16; recipe.values["y"] = 24; recipe.values["width"] = 64; recipe.values["height"] = 48 }
            if [.ghs, .inverseGHS, .modifiedAsinh, .inverseModifiedAsinh].contains(tool) { recipe.values["D"] = 0.8; recipe.values["SP"] = 0.1 }
            if tool == .linearStretch { recipe.values["BP"] = 0.05 }
            if tool == .asinh { recipe.values["stretch"] = 10 }
            if tool == .mtf || tool == .inverseMTF { recipe.values["mid"] = 0.25 }
            if tool == .greenNoise { recipe.values["preserve"] = 0 }
            if tool == .saturation { recipe.values["amount"] = 0.3 }
            if tool == .guided { recipe.values["diameter"] = 2 }
            try await session.compute(recipe, library: records)
            let info = try await session.info(view: 1)
            let actual = try await session.pixel(view: 1, x: 10, y: 10)
            try require(info.width > 0 && info.height > 0 && info.channels == 3 && actual.allSatisfy(\.isFinite), "\(tool.rawValue) did not return finite RGB pixels")
            switch tool {
            case .negative:
                let after = try await session.pixel(view: 1, x: x, y: y)
                try require(zip(after, expected).allSatisfy { abs($0.0 - (1 - $0.1)) < 2e-6 }, "negative pixels")
            case .mtf:
                let after = try await session.pixel(view: 1, x: x, y: y)
                try require(zip(after, expected).allSatisfy { abs(Double($0.0) - (-0.75 * Double($0.1)) / (-0.5 * Double($0.1) - 0.25)) < 2e-6 }, "independent MTF formula")
            case .greenNoise:
                let after = try await session.pixel(view: 1, x: x, y: y)
                try require(abs(after[1] - min(expected[1], (expected[0] + expected[2]) / 2)) < 2e-6 && after[0] == expected[0] && after[2] == expected[2], "SCNR average-neutral pixels")
            case .crop:
                let after = try await session.pixel(view: 1, x: 0, y: 0)
                let corner = (0..<3).map { values[$0 * width * height + 24 * width + 16] }
                try require(info.width == 64 && info.height == 48 && after == corner, "crop selection coordinates or pixels")
            case .mirrorHorizontal, .mirrorVertical, .rotate180:
                let fromX = tool == .mirrorVertical ? x : width - 1 - x
                let fromY = tool == .mirrorHorizontal ? y : height - 1 - y
                let mirrored = (0..<3).map { values[$0 * width * height + fromY * width + fromX] }
                let after = try await session.pixel(view: 1, x: x, y: y)
                try require(after == mirrored, "\(tool.rawValue) coordinates")
            case .binning:
                let after = try await session.pixel(view: 1, x: 10, y: 10)
                for c in 0..<3 {
                    let mean = (values[c * width * height + 20 * width + 20] + values[c * width * height + 20 * width + 21] + values[c * width * height + 21 * width + 20] + values[c * width * height + 21 * width + 21]) / 4
                    try require(info.width == 48 && info.height == 48 && abs(after[c] - mean) < 2e-6, "independent binning mean")
                }
            case .wavelets, .ccm, .resample:
                let after = try await session.pixel(view: 1, x: x, y: y)
                try require(zip(after, expected).allSatisfy { abs($0.0 - $0.1) < 2e-5 }, "identity \(tool.rawValue) changed pixels")
            default: break
            }
            try require(try Data(contentsOf: file.url) == sourceBytes, "tool changed imported original")
            print("PASS: native tool \(tool.rawValue) executed original worker and preserved source")
        }
        for depth in 0..<3 {
            var masked = NativeToolRecipe(tool: .negative, file: file)
            masked.mask.values["mode"] = 2; masked.mask.values["depth"] = Double(depth)
            try await session.compute(masked, library: records)
            let after = try await session.pixel(view: 1, x: x, y: y), mask = try await session.pixel(view: 2, x: x, y: y)[0]
            try require(abs(mask - expected[0]) < (depth == 0 ? 0.004 : 0.00002), "original channel mask precision")
            for c in 0..<3 { try require(abs(after[c] - (expected[c] * (1 - mask) + (1 - expected[c]) * mask)) < 2e-5, "mask was not applied to original pixels") }
            masked.mask.values["invert"] = 1
            try await session.compute(masked, library: records)
            let inverted = try await session.pixel(view: 2, x: x, y: y)[0]
            try require(abs(inverted - (1 - mask)) < 2e-5, "mask inversion changed orientation or precision")
        }
        var masked = NativeToolRecipe(tool: .negative, file: file)
        masked.mask.values["mode"] = 1; masked.mask.values["blur"] = 1; masked.mask.values["threshold"] = 1; masked.mask.values["low"] = 0.1; masked.mask.values["high"] = 0.8
        masked.mask.values["feather"] = 1; masked.mask.values["factor"] = 0.8
        try await session.compute(masked, library: records)
        let maskedPixel = try await session.pixel(view: 1, x: x, y: y)
        let job = try prepareNativeToolJob(file: file, recipe: masked, library: records); jobs.append(job)
        let output = try await session.export(masked, to: job)
        var saved = try importFile(output, role: .results); saved.parentID = file.id; records.append(saved)
        try require(saved.hasMask == true, "export/import lost the original mask")
        let savedSession = NativeToolSession(); try await savedSession.open(saved)
        var inherited = NativeToolRecipe(tool: .resample, file: saved)
        try await savedSession.compute(inherited, library: records)
        let restoredMask = try await savedSession.pixel(view: 2, x: x, y: y)[0]
        let beforeMask = try await session.pixel(view: 2, x: x, y: y)[0]
        let restoredPixel = try await savedSession.pixel(view: 1, x: x, y: y)
        try require(restoredMask == beforeMask && restoredPixel == maskedPixel, "saved mask or identity geometry pixels changed")
        inherited.values["mode"] = 1; inherited.values["size"] = 48
        try await savedSession.compute(inherited, library: records)
        let resizedMaskInfo = try await savedSession.info(view: 2)
        try require(resizedMaskInfo.width == 48 && resizedMaskInfo.height == 48, "native geometry did not resize the inherited mask")
        await savedSession.close()
        var changed = masked; changed.values["unused"] = 4
        var rejected = false
        do { _ = try await session.export(changed, to: job) } catch { rejected = true }
        try require(rejected, "stale parameters exported")
        changed = NativeToolRecipe(tool: .ghs, file: file); changed.values["LP"] = 0.8; changed.values["SP"] = 0.1
        rejected = false
        do { try await session.compute(changed, library: records) } catch { rejected = true }
        try require(rejected, "invalid protection ranges computed")
        rejected = false
        do { _ = try await session.export(masked, to: job) } catch { rejected = true }
        try require(rejected, "failed compute retained an applicable prior preview")
        await session.close()

        let existingLibrary = loadLibrary()
        var history = try nativeToolHistory(saved, tool: .resample)
        history.record(inherited); try saveNativeToolHistory(history, file: saved)
        let historyBytes = try Data(contentsOf: saved.url.appendingPathExtension("tools.json"))
        let maskBytes = try Data(contentsOf: saved.url.appendingPathExtension("mask.fits"))
        try saveLibrary(existingLibrary + [saved])
        _ = try moveToTrash(ids: [saved.id])
        guard let deletion = trashEntries().first(where: { $0.records.contains(where: { $0.id == saved.id }) }) else { throw EngineError.failed("Tool companion trash missing") }
        _ = try restoreTrash(deletion.id)
        try require(try Data(contentsOf: saved.url.appendingPathExtension("tools.json")) == historyBytes, "persistent mask/tool history restoration")
        try require(try Data(contentsOf: saved.url.appendingPathExtension("mask.fits")) == maskBytes, "saved mask restoration")
        var reopened = try nativeToolHistory(saved, tool: .resample)
        reopened.step(redo: false); try require(reopened.current != inherited, "persisted parameter undo")
        reopened.step(redo: true); try require(reopened.current == inherited, "persisted parameter redo")
        reopened.step(redo: false); reopened.record(NativeToolRecipe(tool: .rotate180, file: saved)); try require(reopened.future.isEmpty, "new tool edit retained redo branch")
        _ = try moveToTrash(ids: [saved.id])
        let trash = Set(trashEntries().filter { $0.records.contains(where: { $0.id == saved.id }) }.map(\.id)); try permanentlyDeleteTrash(trash)
        try require(!fm.fileExists(atPath: saved.url.path) && !fm.fileExists(atPath: saved.url.appendingPathExtension("mask.fits").path), "permanent cleanup retained source companions")
        try saveLibrary(existingLibrary)

        for format in NativeImageFormat.allCases {
            let image = try read(file.url); defer { siril_image_free(image) }
            let url = folder.appendingPathComponent(format.rawValue + "." + format.ext)
            try require(url.path.withCString { siril_image_export(image, $0, format.native, format.depth, 100) } != 0, "original \(format.rawValue) export")
            try require(url.path.withCString { siril_image_export(image, $0, format.native, format.depth, 100) } == 0, "format overwrite allowed")
            let imported = try importFile(url)
            let reader = ImageAnalysisEngine(); let details = try await reader.open(imported.url)
            let pixel = try await reader.pixel(x: x, y: y).values
            try require(details.channels == 3 && details.width == width && details.height == height, "format RGB shape/orientation")
            let tolerance: Float = format == .jpeg ? 0.035 : format.depth == 8 ? 0.008 : format.depth == 16 ? 0.00004 : 0.000002
            try require(zip(pixel, expected).allSatisfy { abs($0.0 - $0.1) < tolerance }, "\(format.rawValue) imported pixel precision or orientation")
            try fm.removeItem(at: imported.url)
            print("PASS: original \(format.rawValue) export/import preserved full-size RGB planes at declared precision")
        }
        for ext in ["jpg", "png", "tif"] {
            let bad = folder.appendingPathComponent("invalid." + ext); try Data("not an image".utf8).write(to: bad)
            rejected = false
            do { _ = try importFile(bad) } catch { rejected = true }
            try require(rejected, "malformed \(ext) did not fail safely")
        }
        for job in jobs {
            guard let task = jobHistory().first(where: { $0.id == job.folder.lastPathComponent }) else { throw EngineError.failed("Tool task missing") }
            try trashJob(task)
            try permanentlyDeleteTrash(Set(trashEntries().filter { $0.jobName == task.id }.map(\.id)))
        }
        try require(try Data(contentsOf: file.url) == sourceBytes, "exports, masks or cleanup changed source pixels")
    }
}
