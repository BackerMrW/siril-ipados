// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension SirilEngine {
    func aberrationInspectorSelfTest() async throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Aberration inspector: " + message) }
        }
        let source = documents.appendingPathComponent("simulator-tilt-source.fits")
        let original = try Data(contentsOf: source), analysis = ImageAnalysisEngine()
        let details = try await analysis.open(source)
        try require(details.width == 512 && details.height == 512, "independent field unavailable")
        for mode in [NativeDisplayMode.linear, .automatic] {
            var display = NativeDisplaySettings(); display.mode = mode
            let whole = try await analysis.preview(channel: -1, settings: display)
            let reference = [UInt8](whole.data)
            for side in [127, 256] {
                let panels = try await analysis.aberrationPanels(sampling: side, window: 381, channel: -1, display: display)
                try require(panels.count == 9, "missing tiles")
                for panel in panels {
                    let origins = side == 127 ? [0, 192, 385] : [0, 128, 256]
                    let x0 = origins[panel.id % 3], y0 = origins[panel.id / 3]
                    try require(panel.region == ImageSelection(x: x0, y: y0, width: side, height: side) &&
                        panel.bytes.width == side && panel.bytes.height == side, "native region or owned tile dimensions")
                    let bytes = [UInt8](panel.bytes.data)
                    for y in 0..<side { for x in 0..<side { for c in 0..<4 {
                        try require(bytes[(y * side + x) * 4 + c] == reference[((y + y0) * 512 + x + x0) * 4 + c],
                            "tile recomputed local display statistics or lost source pixels")
                    } } }
                }
            }
        }
        var rejected = false
        do { _ = try await analysis.aberrationPanels(sampling: 126, window: 381, channel: -1, display: NativeDisplaySettings()) }
        catch { rejected = true }
        try require(rejected, "invalid native panel settings accepted")
        let cancelled = Task { try await analysis.aberrationPanels(sampling: 256, window: 381, channel: -1, display: NativeDisplaySettings()) }
        cancelled.cancel()
        var stopped = false
        do { _ = try await cancelled.value } catch is CancellationError { stopped = true }
        try require(stopped && (try Data(contentsOf: source)) == original, "cancelled mosaic returned a result or changed its source")
    }
}
