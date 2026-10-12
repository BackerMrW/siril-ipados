// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

struct StarSettings: Codable, Equatable, Sendable {
    var channel = 0, profile = 0, convergence = 1, radius = 5, maximum = 1000
    var relax = false, photometry = false, forceRadius = true
    var sigma = 1.0, minRoundness = 0.5, maxRoundness = 1.0, minBeta = 1.5
    var minAmplitude = 0.0, maxAmplitude = 0.0, focal = 0.0, pixelSize = 0.0
    var gain = 2.3, inner = 20.0, outer = 30.0, aperture = 10.0, apertureFactor = 4.0
    var minimum = -1500.0, maximumPixel = 60000.0
    var finder: SirilStarFinder {
        SirilStarFinder(channel: Int32(channel), profile: Int32(profile), convergence: Int32(convergence),
            radius: Int32(radius), relax: relax ? 1 : 0, maximum: Int32(maximum), sigma: sigma,
            minimum_roundness: minRoundness, maximum_roundness: maxRoundness, minimum_beta: minBeta,
            minimum_amplitude: minAmplitude, maximum_amplitude: maxAmplitude, focal_length: focal, pixel_size: pixelSize)
    }
    var phot: SirilPhotometry {
        SirilPhotometry(enabled: photometry ? 1 : 0, force_radius: forceRadius ? 1 : 0, gain: gain,
            inner: inner, outer: outer, aperture: aperture, aperture_factor: apertureFactor, minimum: minimum, maximum: maximumPixel)
    }
    func validate(channels: Int) throws {
        guard (0..<channels).contains(channel), (0...1).contains(profile), (1...3).contains(convergence),
              (3...50).contains(radius), (1...10000).contains(maximum),
              [sigma, minRoundness, maxRoundness, minBeta, minAmplitude, maxAmplitude, focal, pixelSize,
               gain, inner, outer, aperture, apertureFactor, minimum, maximumPixel].allSatisfy(\.isFinite) else {
            throw EngineError.failed("星点分析参数超出范围或包含无效数值")
        }
    }
}
struct StarMeasurement: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    let channel: Int, profile: Int, saturated: Bool, photometryValid: Bool, photometryError: Int
    // Pixel coordinates and widths are never replaced by angular display values.
    let x: Double, y: Double, background: Double, amplitude: Double, fwhmX: Double, fwhmY: Double
    let angularX: Double, angularY: Double, angle: Double, beta: Double, rmse: Double
    let magnitude: Double, magnitudeError: Double, snr: Double, ra: Double, dec: Double
    init(_ r: SirilStarMeasurement) throws {
        let fields = [r.x, r.y, r.background, r.amplitude, r.fwhm_x, r.fwhm_y, r.angle, r.rmse, r.magnitude]
        guard fields.allSatisfy(\.isFinite), r.fwhm_x > 0, r.fwhm_y > 0 else { throw EngineError.failed("原版拟合未返回有效星像") }
        channel = Int(r.channel); profile = Int(r.profile); saturated = r.saturated != 0
        photometryValid = r.photometry_valid != 0; photometryError = Int(r.photometry_error)
        x = r.x; y = r.y; background = r.background; amplitude = r.amplitude
        fwhmX = r.fwhm_x; fwhmY = r.fwhm_y; angularX = r.angular_x; angularY = r.angular_y
        angle = r.angle; beta = r.beta; rmse = r.rmse; magnitude = r.magnitude
        magnitudeError = r.magnitude_error; snr = r.snr; ra = r.ra; dec = r.dec
    }
    var native: SirilStarMeasurement {
        SirilStarMeasurement(channel: Int32(channel), profile: Int32(profile), saturated: saturated ? 1 : 0,
            photometry_valid: photometryValid ? 1 : 0, photometry_error: Int32(photometryError),
            x: x, y: y, background: background, amplitude: amplitude, fwhm_x: fwhmX, fwhm_y: fwhmY,
            angular_x: angularX, angular_y: angularY, angle: angle, beta: beta, rmse: rmse,
            magnitude: magnitude, magnitude_error: magnitudeError, snr: snr, ra: ra, dec: dec)
    }
    var marker: SampleMarker { SampleMarker(id: 0, x: x, y: y, size: max(fwhmX, fwhmY) * 3, median: []) }
    var hasWCS: Bool { ra.isFinite && dec.isFinite && (0..<360).contains(ra) && (-90...90).contains(dec) }
    var roundness: Double { fwhmY / fwhmX }
    var fields: [Double] { [Double(channel), background, amplitude, x, y, ra, dec, fwhmX, fwhmY, magnitude, beta, roundness, angle, rmse] }
}
struct StarEdit: Codable, Equatable, Sendable {
    var settings = StarSettings()
    var stars: [StarMeasurement] = []
}
struct StarHistory: Codable, Equatable, Sendable {
    let sourceID: UUID, width: Int, height: Int
    var current = StarEdit(), past: [StarEdit] = [], future: [StarEdit] = []
    init(file: FITSRecord) { sourceID = file.id; width = file.width; height = file.height }
    mutating func record(_ edit: StarEdit) {
        guard current != edit else { return }
        past.append(current); if past.count > 30 { past.removeFirst(past.count - 30) }
        current = edit; future = []
    }
    mutating func undo() { if let edit = past.popLast() { future.append(current); current = edit } }
    mutating func redo() { if let edit = future.popLast() { past.append(current); current = edit } }
    static func url(for file: FITSRecord) throws -> URL {
        let root = try BackgroundEditHistory.url(for: file).deletingLastPathComponent()
        let url = root.appendingPathComponent(file.url.lastPathComponent + ".stars.json")
        guard url.resolvingSymlinksInPath().path == url.path else { throw EngineError.failed("星表记录不能写入符号链接") }
        return url
    }
    func save(for file: FITSRecord) throws { try JSONEncoder().encode(self).write(to: Self.url(for: file), options: .atomic) }
    static func load(for file: FITSRecord) throws -> Self {
        let url = try url(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self(file: file) }
        let h = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard h.sourceID == file.id, h.width == file.width, h.height == file.height, h.past.count <= 30, h.future.count <= 30,
              ([h.current] + h.past + h.future).allSatisfy({ $0.stars.count <= 10000 }) else {
            throw EngineError.failed("星点分析记录与原图不匹配")
        }
        return h
    }
}
extension ImageAnalysisEngine {
    func fitStar(region: ImageSelection, settings: StarSettings) throws -> StarMeasurement {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var info = SirilImageInfo(); _ = siril_image_info(image, &info)
        try settings.validate(channels: Int(info.channels))
        var area = region.native, finder = settings.finder, phot = settings.phot, result = SirilStarMeasurement()
        var error = [CChar](repeating: 0, count: 512)
        guard siril_image_fit_star(image, &area, &finder, &phot, &result, &error, error.count) != 0 else { throw EngineError.failed(String(cString: error)) }
        return try StarMeasurement(result)
    }
    func findStars(region: ImageSelection?, settings: StarSettings) throws -> [StarMeasurement] {
        guard let image else { throw EngineError.failed("尚未打开图像") }
        var info = SirilImageInfo(); _ = siril_image_info(image, &info)
        try settings.validate(channels: Int(info.channels))
        var area = region?.native ?? SirilRegion(), finder = settings.finder
        var results = [SirilStarMeasurement](repeating: SirilStarMeasurement(), count: settings.maximum)
        var error = [CChar](repeating: 0, count: 512)
        let n = region == nil ? siril_image_find_stars(image, nil, &finder, &results, results.count, &error, error.count) :
            siril_image_find_stars(image, &area, &finder, &results, results.count, &error, error.count)
        guard n >= 0 else { throw EngineError.failed(String(cString: error)) }
        return try results.prefix(Int(n)).map(StarMeasurement.init)
    }
    func saveStars(_ stars: [StarMeasurement], settings: StarSettings, to url: URL, fitsTable: Bool) throws {
        guard let image, !stars.isEmpty else { throw EngineError.failed("没有可导出的星点") }
        var info = SirilImageInfo(); _ = siril_image_info(image, &info)
        try settings.validate(channels: Int(info.channels))
        var finder = settings.finder, rows = stars.map(\.native), error = [CChar](repeating: 0, count: 512)
        let ok = url.path.withCString { siril_image_save_stars(image, $0, fitsTable ? 1 : 0, &finder, &rows, rows.count, &error, error.count) }
        guard ok != 0 else { throw EngineError.failed(String(cString: error)) }
    }
}
