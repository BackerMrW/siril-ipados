// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct AberrationPanel: Sendable, Identifiable {
    let id: Int
    let region: ImageSelection
    let bytes: PreviewBytes
}
extension ImageAnalysisEngine {
    func aberrationPanels(sampling: Int, window: Int, channel: Int, display: NativeDisplaySettings) throws -> [AberrationPanel] {
        guard let image, (127...1024).contains(sampling), (300...1600).contains(window), (-1...2).contains(channel) else {
            throw EngineError.failed("像差检查参数无效或图像未打开。")
        }
        var panels: [AberrationPanel] = []
        for index in 0..<9 {
            try Task.checkCancellation()
            var preview = SirilPreview(), region = SirilRegion()
            let ok = try display.withNative {
                siril_image_aberration_panel(image, Int32(sampling), Int32(window), Int32(index), Int32(channel), &$0, &region, &preview)
            }
            guard ok != 0, let pixels = preview.rgba else { throw EngineError.failed("原版显示变换无法生成像差面板。") }
            defer { siril_preview_free(&preview) }
            panels.append(AberrationPanel(id: index, region: ImageSelection(x: Int(region.x), y: Int(region.y), width: Int(region.width), height: Int(region.height)),
                bytes: PreviewBytes(data: Data(bytes: pixels, count: Int(preview.width) * Int(preview.height) * 4),
                    width: Int(preview.width), height: Int(preview.height))))
        }
        return panels
    }
}
