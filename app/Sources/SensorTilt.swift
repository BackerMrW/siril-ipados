// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct SensorTiltPoint: Codable, Equatable, Sendable {
    let x: Double, y: Double
}
struct SensorTiltResult: Codable, Equatable, Sendable {
    let stars: Int, channel: Int, width: Int, height: Int
    let mean: Double, centre: Double, outer: Double, difference: Double, percent: Double, offAxis: Double
    let quadrants: [Double]
    let points: [SensorTiltPoint]
    init(_ raw: SirilSensorTilt) throws {
        var raw = raw
        func array<T>(_ tuple: inout T) -> [Double] {
            withUnsafeBytes(of: &tuple) { Array($0.bindMemory(to: Double.self)) }
        }
        let q = array(&raw.quadrant), x = array(&raw.x), y = array(&raw.y)
        guard raw.stars > 0, raw.width > 0, raw.height > 0,
              q.count == 4, x.count == 4, y.count == 4,
              (q + x + y + [raw.mean, raw.centre, raw.outer, raw.difference, raw.percent, raw.off_axis]).allSatisfy(\.isFinite),
              q.allSatisfy({ $0 > 0 }) else { throw EngineError.failed("倾斜分析没有完整的有效分区结果。") }
        stars = Int(raw.stars); channel = Int(raw.channel); width = Int(raw.width); height = Int(raw.height)
        mean = raw.mean; centre = raw.centre; outer = raw.outer
        difference = raw.difference; percent = raw.percent; offAxis = raw.off_axis; quadrants = q
        points = zip(x, y).map { SensorTiltPoint(x: $0.0, y: $0.1) }
    }
}
extension ImageAnalysisEngine {
    func sensorTilt(settings: StarSettings) throws -> SensorTiltResult {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var info = SirilImageInfo(); _ = siril_image_info(image, &info)
        try settings.validate(channels: Int(info.channels))
        var finder = settings.finder, result = SirilSensorTilt(), error = [CChar](repeating: 0, count: 1024)
        let capacity = error.count
        guard siril_image_sensor_tilt(image, &finder, &result, &error, capacity) != 0 else {
            throw EngineError.failed(String(cString: error))
        }
        return try SensorTiltResult(result)
    }
}
