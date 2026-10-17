// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SirilCore

extension SirilEngine {
    func multipointWarpSelfTest() throws {
        let fm = FileManager.default, baseline = loadLibrary()
        let folder = documents.appendingPathComponent("multipoint-warp-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var inputs: [FITSRecord] = []
        defer {
            for input in inputs { try? fm.removeItem(at: input.url) }
            try? saveLibrary(baseline); try? fm.removeItem(at: folder)
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw EngineError.failed("Multipoint local warp: " + message) }
        }
        func pixel(_ x: Int, _ y: Int) -> UInt16 {
            let dx = Double(x) - 127.5, dy = Double(y) - 127.5
            let disc = max(0, min(1, (104 - hypot(dx, dy)) / 8))
            let texture = 24000 + 6000 * sin(Double(x) / 6) * cos(Double(y) / 7) + 4000 * sin(Double(x + y) / 4)
            return UInt16(max(0, min(65535, disc * texture)))
        }
        for frame in 0..<2 {
            let cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
                "NAXIS1  =                  256", "NAXIS2  =                  256", "BZERO   =                32768",
                "BSCALE  =                    1", "ROWORDER= 'BOTTOM-UP'", "END"]
            var bytes = Data(cards.map { $0.padding(toLength: 80, withPad: " ", startingAt: 0) }.joined()
                .padding(toLength: 2880, withPad: " ", startingAt: 0).utf8)
            for row in 0..<256 { for x in 0..<256 {
                let y = 255 - row
                // Opposite horizontal translations in the upper/lower halves.
                // Frame 1 relative to frame 0 needs +4 px above, -4 below.
                let shift = (y < 128 ? 1 : -1) * (frame == 0 ? 2 : -2)
                var encoded = (pixel(x - shift, y) ^ 0x8000).bigEndian
                withUnsafeBytes(of: &encoded) { bytes.append(contentsOf: $0) }
            } }
            bytes.append(contentsOf: repeatElement(UInt8(0), count: (2880 - bytes.count % 2880) % 2880))
            let path = folder.appendingPathComponent("warp-\(frame).fits")
            try bytes.write(to: path); inputs.append(try importFile(path))
        }
        let job = try createSequence(files: inputs)
        defer { try? fm.removeItem(at: job.folder) }
        guard let source = sequenceLocations(job: job.folder.lastPathComponent).first else {
            throw EngineError.failed("Missing local-warp sequence")
        }
        let process = try sequenceFolder(source)
        let metadata = try Data(contentsOf: process.appendingPathComponent(source.name))
        let originalBytes = try inputs.map { try Data(contentsOf: $0.url) }
        var settings = SequenceMultipointSettings()
        settings.halfBox = 16; settings.search = 8; settings.structure = 0
        settings.normalize = false; settings.refine = false; settings.smoothRadius = 0
        settings.dewarp = true; settings.floatOutput = true
        let analysis = try stackMultipoint(source, settings: settings, phase: 1)
        var edited = try editMultipoint(source, runID: analysis.deletingLastPathComponent().lastPathComponent, edit: .clear)
        edited = try editMultipoint(source, runID: edited, edit: .add(x: 128, y: 64, halfBox: 16))
        edited = try editMultipoint(source, runID: edited, edit: .add(x: 128, y: 192, halfBox: 16))
        let beforeEdge = try multipointAnalysis(source, runID: edited, display: NativeDisplaySettings())
        edited = try editMultipoint(source, runID: edited,
            edit: .move(index: 0, x: beforeEdge.width - 1, y: beforeEdge.height - 1))
        let edge = try multipointAnalysis(source, runID: edited, display: NativeDisplaySettings())
        try require(edge.points[0].box.x + edge.points[0].box.width <= edge.width &&
            edge.points[0].box.y + edge.points[0].box.height <= edge.height &&
            edge.points[0].patch.x + edge.points[0].patch.width <= edge.width &&
            edge.points[0].patch.y + edge.points[0].patch.height <= edge.height,
            "edge AP bounds used source dimensions instead of cropped reference")
        edited = try editMultipoint(source, runID: edited, edit: .undo)
        let restored = try multipointAnalysis(source, runID: edited, display: NativeDisplaySettings())
        try require(restored.points == beforeEdge.points, "edge move undo changed original point bounds")
        let registration = try resumeMultipoint(source, runID: edited, phase: 2)
        let id = registration.deletingLastPathComponent().lastPathComponent
        let first = try multipointAnalysis(source, runID: id, display: NativeDisplaySettings(), frame: 0)
        let second = try multipointAnalysis(source, runID: id, display: NativeDisplaySettings(), frame: 1)
        try require(first.shifts.count == 2 && second.shifts.count == 2, "edited APs were not registered")
        for index in 0..<2 {
            let a = first.shifts[index], b = second.shifts[index]
            let dx = (b.dx + b.globalDX) - (a.dx + a.globalDX)
            let dy = (b.dy + b.globalDY) - (a.dy + a.globalDY)
            let expectedDX = index == 0 ? 4.0 : -4.0
            try require(a.success && b.success && abs(dx - expectedDX) < 0.5 && abs(dy) < 0.5,
                "known differential displacement AP \(index): expected X \(expectedDX), Y 0; got X \(dx), Y \(dy), ok \(a.success)/\(b.success)")
        }
        let output = try resumeMultipoint(source, runID: id, phase: 3)
        try require(fm.fileExists(atPath: output.path), "registered warp did not stack")
        try require(try Data(contentsOf: process.appendingPathComponent(source.name)) == metadata, "changed source metadata")
        for (index, input) in inputs.enumerated() {
            try require(try Data(contentsOf: input.url) == originalBytes[index], "changed source pixels")
        }
        try Data(contentsOf: registration).write(to: documents.appendingPathComponent("native-multipoint-warp-analysis.mpp"), options: .atomic)
        let magnitude0 = first.shifts.reduce(0) { $0 + hypot($1.dx, $1.dy) }
        let magnitude1 = second.shifts.reduce(0) { $0 + hypot($1.dx, $1.dy) }
        try JSONEncoder().encode(magnitude1 > magnitude0 ? 1 : 0)
            .write(to: documents.appendingPathComponent("native-multipoint-warp-frame.json"), options: .atomic)
    }
}
