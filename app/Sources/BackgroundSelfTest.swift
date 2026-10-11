// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@MainActor func backgroundEditSelfTest(file: FITSRecord) async throws {
    func check(_ ok: Bool, _ reason: String) throws {
        guard ok else { throw EngineError.failed(reason) }
    }
    let sourceBytes = try Data(contentsOf: file.url)
    let engine = BackgroundEngine()
    try await engine.open(file.url)
    var settings = BackgroundSettings(); settings.perLine = 8
    try await engine.generate(settings)
    let original = try await engine.samples()
    try check(original.count > 6, "Background edit fixture needs original samples")
    var history = BackgroundEditHistory(file: file)
    history.record(BackgroundEdit(settings: settings, points: original.map(BackgroundPoint.init)))
    try await engine.compute(settings)
    let before = try await engine.preview(view: 1, channel: -1, automatic: false)
    try await engine.move(index: 0, x: 50, y: 50)
    let moved = try await engine.samples()
    try check(moved.count == original.count && moved[0].x == 50 && moved[0].y == 50,
              "Background move changed count/order")
    history.record(BackgroundEdit(settings: settings, points: moved.map(BackgroundPoint.init)))
    var modelInvalid = false
    do { _ = try await engine.preview(view: 1, channel: -1, automatic: false) }
    catch { modelInvalid = true }
    try check(modelInvalid, "Moving sample retained a stale computed model")
    var rejected = false
    do { try await engine.move(index: 0, x: 0, y: 0) } catch { rejected = true }
    let afterRejected = try await engine.samples()
    try check(rejected && afterRejected.map(BackgroundPoint.init) == history.current.points,
              "Rejected background move changed samples")
    settings.correction = 1; settings.smoothing = 0.7
    history.record(BackgroundEdit(settings: settings, points: history.current.points))
    try history.save(for: file)
    let saved = try BackgroundEditHistory.load(for: file)
    try check(saved == history, "Background edit history did not persist")
    history.undo() // parameter edit
    try check(history.current.settings.correction == 0 && history.current.settings.smoothing == 0.5,
              "Background undo failed to restore all parameters")
    history.undo() // move
    try await engine.restore(history.current.points)
    try await engine.compute(history.current.settings)
    let restored = try await engine.preview(view: 1, channel: -1, automatic: false)
    try check(restored.data == before.data, "Background undo changed original corrected preview pixels")
    try history.save(for: file)
    var reopened = try BackgroundEditHistory.load(for: file)
    let secondSession = BackgroundEngine(); try await secondSession.open(file.url)
    try await secondSession.restore(reopened.current.points)
    let reopenedSamples = try await secondSession.samples()
    try check(reopenedSamples.map { $0.median } == original.map { $0.median },
              "Background reopen did not reread original sample medians")
    reopened.redo(); try await secondSession.restore(reopened.current.points)
    reopened.redo(); try await secondSession.compute(reopened.current.settings)
    try check(reopened.current == saved.current, "Background redo failed across reopen")
    reopened.undo()
    var branch = reopened.current; branch.settings.degree = 2
    reopened.record(branch)
    try check(reopened.future.isEmpty, "New background edit retained redo branch")
    try await secondSession.clear()
    reopened.record(BackgroundEdit(settings: reopened.current.settings, points: []))
    reopened.undo(); try await secondSession.restore(reopened.current.points)
    let uncleared = try await secondSession.samples()
    try check(uncleared.count == original.count, "Undo clear did not restore samples")
    // Exercise the same coordinator used by the real canvas, including its
    // zoomed coordinate conversion, cancellation and one commit per drag.
    let image = try await secondSession.preview(view: 0, channel: -1, automatic: true).uiImage!
    var commits: [(Int, Double, Double)] = []
    let canvas = ZoomableImageCanvas(image: image, samples: uncleared,
        imageWidth: Double(file.width), imageHeight: Double(file.height),
        movingSamples: true, onSampleMove: { commits.append(($0, $1, $2)) }, onTap: nil)
    let coordinator = canvas.makeCoordinator()
    let scroll = CanvasScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 420))
    coordinator.install(on: scroll); scroll.layoutIfNeeded()
    scroll.setZoomScale(2, animated: false); scroll.contentOffset = CGPoint(x: 30, y: 40)
    scroll.layoutIfNeeded()
    func at(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x / Double(file.width) * scroll.canvas.bounds.width,
                y: y / Double(file.height) * scroll.canvas.bounds.height)
    }
    let point = uncleared[0]
    try check(coordinator.beginSampleMove(at: at(point.x, point.y)), "Canvas failed to pick sample after zoom/pan")
    coordinator.updateSampleMove(at: at(60, 70))
    coordinator.finishSampleMove(cancelled: true)
    try check(commits.isEmpty && scroll.markers[0].x == point.x, "Cancelled drag committed an edit")
    try check(coordinator.beginSampleMove(at: at(point.x, point.y)), "Canvas sample drag did not restart")
    for x in 52...60 { coordinator.updateSampleMove(at: at(Double(x), 70)) }
    coordinator.finishSampleMove(cancelled: false)
    try check(commits.count == 1 && commits[0].0 == 0 && commits[0].1 == 60 && commits[0].2 == 70,
              "Canvas drag did not commit exact full-resolution coordinates once")
    try await secondSession.move(index: commits[0].0, x: commits[0].1, y: commits[0].2)
    let dragged = try await secondSession.samples()
    try check(dragged[0].x == 60 && dragged[0].y == 70 && scroll.panGestureRecognizer.minimumNumberOfTouches == 2,
              "Canvas drag failed to apply original samples or conflicted with single-finger pan")
    try check(coordinator.beginSampleMove(at: at(point.x, point.y)), "Canvas edge test failed to pick sample")
    coordinator.updateSampleMove(at: at(-50, 400))
    coordinator.finishSampleMove(cancelled: false)
    try check(commits.last?.1 == 12 && commits.last?.2 == Double(file.height - 13), "Canvas failed to keep sample boxes inside image")
    try check(!coordinator.beginSampleMove(at: CGPoint(x: -100, y: -100)), "Canvas picked a sample outside image")
    try check(try Data(contentsOf: file.url) == sourceBytes, "Background edits changed source FITS")
    // Persist both enabled undo and redo buttons for the actual UI capture.
    var demo = saved; demo.undo(); try demo.save(for: file)
}
