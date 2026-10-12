// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum PhotometricFields {
    static func fields(for tool: NativeTool) -> [ToolField] {
        var fields: [ToolField] = [
            .number("backgroundLow", "背景下限 Sigma", 2.8, 0.1, 10), .number("backgroundHigh", "背景上限 Sigma", 2, 0.1, 10),
            .choice("magnitudeMode", "极限星等", ["自动", "自动加偏移", "绝对星等"]), .number("magnitude", "星等 / 偏移", 0, -10, 30)]
        if tool == .pcc { fields += [.choice("catalog", "星表", ["自动", "NOMAD", "Gaia DR3", "APASS"])] }
        else {
            fields += [.toggle("mono", "单色相机与独立 RGB 滤镜", false),
                .toggle("narrowband", "窄带响应", false)]
            for (channel, wavelength) in [("r", 656.3), ("g", 500.7), ("b", 486.1)] {
                fields += [.number(channel + "wl", channel.uppercased() + " 中心波长 nm", wavelength, 380, 700),
                           .number(channel + "bw", channel.uppercased() + " 带宽 nm", 5, 1, 40)]
            }
            fields += [.toggle("atmosphere", "大气消光校正", false), .number("height", "观测海拔 m", 10, -500, 10000),
                       .number("pressure", "海平面气压 hPa", 1013.25, 1, 1500)]
        }
        return fields
    }
}

enum SpectralModels {
    static let bundled: [String: [String]] = {
        guard let directory = Bundle.main.url(forResource: "SPCC", withExtension: nil),
              let data = try? Data(contentsOf: directory.appendingPathComponent("models-index.schema.json")),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return values
    }()
    static func names(_ type: String) -> [String] { bundled[type] ?? [] }
}

struct SpectralSettings: Codable, Equatable, Sendable {
    var monoSensor = "Generic mono sensor", oscSensor = ""
    var red = "", green = "", blue = ""
    var oscFilter = "No filter", lowPass = "Full spectrum (no filter)", white = "Average Spiral Galaxy"
    func validate(mono: Bool, dslr: Bool) throws {
        let selections = mono ? [("MONO_SENSOR", monoSensor), ("MONO_FILTER_RED", red), ("MONO_FILTER_GREEN", green), ("MONO_FILTER_BLUE", blue)] :
            [("OSC_SENSOR", oscSensor), ("OSC_FILTER", oscFilter)] + (dslr ? [("OSC_LPF", lowPass)] : [])
        for (type, value) in selections + [("WB_REF", white)] {
            guard SpectralModels.names(type).contains(value), !value.contains("\""), !value.contains("\n"), !value.contains("\r") else {
                throw EngineError.failed("请选择资料库中的传感器、各通道滤镜和白平衡参考。")
            }
        }
    }
}

extension NativeToolRecipe {
    var spectralSettings: SpectralSettings { get { spectral ?? SpectralSettings() } set { spectral = newValue } }
    func photometricCommand() throws -> String {
        func n(_ key: String) -> String { Self.format(number(key)) }
        var command = tool == .pcc ? "pcc" : "spcc"
        command += " -bgtol=\(n("backgroundLow")),\(n("backgroundHigh"))"
        if number("magnitudeMode") == 1 { command += " -limitmag=" + (number("magnitude") >= 0 ? "+" : "") + n("magnitude") }
        if number("magnitudeMode") == 2 { command += " -limitmag=" + n("magnitude") }
        if tool == .pcc {
            let catalog = ["", "nomad", "gaia", "apass"][Int(number("catalog"))]
            if !catalog.isEmpty { command += " -catalog=" + catalog }
            return command
        }
        let selected = spectralSettings
        try selected.validate(mono: number("mono") == 1, dslr: true)
        // Siril's parser quotes the entire option token, including its prefix.
        func option(_ name: String, _ value: String) -> String { " \"-" + name + "=" + value + "\"" }
        if number("mono") == 1 {
            command += option("monosensor", selected.monoSensor) + option("rfilter", selected.red) + option("gfilter", selected.green) + option("bfilter", selected.blue)
        } else {
            command += option("oscsensor", selected.oscSensor) + option("oscfilter", selected.oscFilter)
            command += option("osclpf", selected.lowPass)
        }
        command += option("whiteref", selected.white)
        if number("narrowband") == 1 {
            command += " -narrowband"
            for channel in ["r", "g", "b"] { command += " -\(channel)wl=\(n(channel + "wl")) -\(channel)bw=\(n(channel + "bw"))" }
        }
        if number("atmosphere") == 1 { command += " -atmos -obsheight=\(n("height")) -pressure=\(n("pressure")) -slp" }
        return command
    }
}

struct SpectralEditor: View {
    @Binding var settings: SpectralSettings
    let mono: Bool, dslr: Bool
    private func picker(_ title: String, _ type: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择").tag("")
            ForEach(SpectralModels.names(type), id: \.self) { Text($0).tag($0) }
        }
    }
    var body: some View {
        Section("原版光谱资料库") {
            if mono {
                picker("单色传感器", "MONO_SENSOR", $settings.monoSensor)
                picker("红滤镜", "MONO_FILTER_RED", $settings.red)
                picker("绿滤镜", "MONO_FILTER_GREEN", $settings.green)
                picker("蓝滤镜", "MONO_FILTER_BLUE", $settings.blue)
            } else {
                picker("彩色传感器", "OSC_SENSOR", $settings.oscSensor)
                picker("外置滤镜", "OSC_FILTER", $settings.oscFilter)
                if dslr { picker("低通滤镜", "OSC_LPF", $settings.lowPass) }
            }
            picker("白平衡参考", "WB_REF", $settings.white)
        }
    }
}
