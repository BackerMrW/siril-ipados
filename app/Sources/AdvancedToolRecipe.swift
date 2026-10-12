// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct CurveKnot: Codable, Equatable, Sendable {
    var x: Double, y: Double
}
struct CurveChannel: Codable, Equatable, Sendable {
    var points = [CurveKnot(x: 0, y: 0), CurveKnot(x: 1, y: 1)]
    var rangeEnabled = false
    var low = 0.0, high = 1.0, feather = 0.25
    func validate() throws {
        guard (2...100).contains(points.count), points.first?.x == 0, points.last?.x == 1,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              zip(points, points.dropFirst()).allSatisfy({ $0.0.x < $0.1.x }),
              [low, high, feather].allSatisfy({ $0.isFinite && (0...1).contains($0) }), low <= high else {
            throw EngineError.failed("曲线点必须按X递增，端点X为0和1；亮度范围和羽化须在0–1内。")
        }
    }
}
struct CurveStage: Codable, Equatable, Sendable {
    var algorithm = 2
    var channels = [CurveChannel](repeating: CurveChannel(), count: 7)
    func validate() throws {
        guard (0...2).contains(algorithm), channels.count == 7 else { throw EngineError.failed("原版曲线通道或插值算法无效。") }
        for channel in channels { try channel.validate() }
    }
}
struct CurveRecipe: Codable, Equatable, Sendable {
    var kind = "curves"
    var current = CurveStage()
    var stages: [CurveStage] = []
    var selectedChannel = 0
    var logarithmic = false
    var zoom = 1.0
    static let channels = ["RGB / 灰度", "R", "G", "B", "亮度 L*", "色度 C*", "饱和度 S"]
    func validate() throws {
        guard kind == "curves", (0...6).contains(selectedChannel), stages.count <= 30, zoom.isFinite, (1...100).contains(zoom) else { throw EngineError.failed("曲线阶段或通道无效。") }
        for stage in stages + [current] { try stage.validate() }
    }
    func plotted(channel: Int? = nil) -> [Float] {
        guard let data = try? JSONEncoder().encode(current), let json = String(data: data, encoding: .utf8) else { return [] }
        var values = [Float](repeating: 0, count: 257)
        let count = values.count
        let ok = json.withCString { siril_curve_plot($0, Int32(channel ?? selectedChannel), &values, count) }
        return ok != 0 ? values : []
    }
}
struct PMBinding: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var imageID: UUID?
}
struct PMParameter: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var expression: String
}
struct PMPreset: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var expressions: [String]
    var singleRGB: Bool
    var parameters: [PMParameter]
}
struct PixelMathRecipe: Codable, Equatable, Sendable {
    var kind = "pixelMath"
    var expressions = ["$T", "I1", "I1"]
    var singleRGB = true
    var doSum = true
    var rescale = false
    var low = 0.0, high = 1.0
    var bindings: [PMBinding] = []
    var parameters: [PMParameter] = []
    var presets: [PMPreset] = []
    static func symbol(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil &&
            !["gfit", "T", "e", "pi"].contains(name)
    }
    func validate() throws {
        guard kind == "pixelMath", expressions.count == 3, bindings.count <= 10, parameters.count <= 64, presets.count <= 100,
              [low, high].allSatisfy({ $0.isFinite && (0...1).contains($0) }), low <= high,
              (singleRGB ? [expressions[0]] : expressions).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 16384 }),
              bindings.allSatisfy({ Self.symbol($0.name) && $0.imageID != nil }),
              parameters.allSatisfy({ Self.symbol($0.name) && !$0.expression.isEmpty && $0.expression.utf8.count <= 4096 }) else {
            throw EngineError.failed("像素数学表达式、图像变量或参数无效；最多10个图像变量。")
        }
        let names = bindings.map(\.name) + parameters.map(\.name)
        guard Set(names).count == names.count else { throw EngineError.failed("图像变量和参数名称不能重复。") }
        if !singleRGB && expressions.contains(where: { $0.contains("$T") }) {
            throw EngineError.failed("原版三表达式模式使用单通道图像变量；请分别选择灰度图像，使用其变量名。")
        }
    }
    func expandedExpressions() throws -> [String] {
        try validate()
        return try expressions.map { initial in
            var result = initial
            // Repeat to resolve parameter-to-parameter references; bounded
            // expansion rejects cycles and oversized settings before C parsing.
            for _ in 0...parameters.count {
                var changed = false
                for parameter in parameters {
                    let regex = try NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: parameter.name) + #"\b"#)
                    let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
                    for match in matches.reversed() {
                        if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: "(" + parameter.expression + ")"); changed = true }
                    }
                    guard result.utf8.count <= 16384 else { throw EngineError.failed("参数展开过长或存在循环引用。") }
                }
                if !changed { return result }
            }
            throw EngineError.failed("参数存在循环引用。")
        }
    }
}
extension NativeToolRecipe {
    func validateAdvancedStorage() throws {
        if tool == .curves {
            let recipe = curveSettings
            guard recipe.kind == "curves", (0...6).contains(recipe.selectedChannel), recipe.stages.count <= 30 else { throw EngineError.failed("保存的曲线结构无效。") }
            for stage in recipe.stages + [recipe.current] {
                guard (0...2).contains(stage.algorithm), stage.channels.count == 7 else { throw EngineError.failed("保存的曲线通道无效。") }
                for channel in stage.channels {
                    guard (2...100).contains(channel.points.count), channel.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                          [channel.low, channel.high, channel.feather].allSatisfy(\.isFinite) else { throw EngineError.failed("保存的曲线点无效。") }
                }
            }
        }
        if tool == .pixelMath {
            let recipe = mathSettings
            guard recipe.kind == "pixelMath", recipe.expressions.count == 3, recipe.bindings.count <= 10,
                  recipe.parameters.count <= 64, recipe.presets.count <= 100,
                  recipe.expressions.allSatisfy({ $0.utf8.count <= 16384 }), recipe.low.isFinite, recipe.high.isFinite else { throw EngineError.failed("保存的像素数学结构无效。") }
        }
    }
    var curveSettings: CurveRecipe { get { curves ?? CurveRecipe() } set { curves = newValue } }
    var mathSettings: PixelMathRecipe { get { pixelMath ?? PixelMathRecipe() } set { pixelMath = newValue } }
    func advancedSettings(paths: [UUID: String] = [:]) throws -> String? {
        if tool == .curves {
            try curveSettings.validate()
            return String(data: try JSONEncoder().encode(curveSettings), encoding: .utf8)
        }
        if tool == .pixelMath {
            let settings = mathSettings
            let bindings: [[String: String]] = try settings.bindings.map { binding in
                guard let id = binding.imageID, let path = paths[id] else { throw EngineError.failed("像素数学变量图像已删除或未选择。") }
                return ["name": binding.name, "path": path]
            }
            let json: [String: Any] = ["kind": "pixelMath", "expressions": try settings.expandedExpressions(),
                "singleRGB": settings.singleRGB, "doSum": settings.doSum, "rescale": settings.rescale,
                "low": settings.low, "high": settings.high, "bindings": bindings]
            return String(data: try JSONSerialization.data(withJSONObject: json, options: .sortedKeys), encoding: .utf8)
        }
        return nil
    }
}
