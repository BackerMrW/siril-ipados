// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct SampleMarker: Identifiable, Sendable {
    let id: Int
    let x: Double
    let y: Double
    let size: Double
    let median: [Double]
}
struct DisplacementMarker: Sendable {
    let x: Double
    let y: Double
    let dx: Double
    let dy: Double
    let success: Bool
}

struct ImageSelection: Equatable, Sendable, Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    static func between(_ a: CGPoint, _ b: CGPoint, width: Int, height: Int) -> Self {
        let x = max(0, min(width - 1, Int(floor(min(a.x, b.x)))))
        let y = max(0, min(height - 1, Int(floor(min(a.y, b.y)))))
        let right = max(x + 1, min(width, Int(floor(max(a.x, b.x))) + 1))
        let bottom = max(y + 1, min(height, Int(floor(max(a.y, b.y))) + 1))
        return Self(x: x, y: y, width: right - x, height: bottom - y)
    }
    var description: String { "(\(x), \(y)) · \(width) × \(height) 像素" }
}

// Sample coordinates stay in the full FITS image; zoom changes display only.
struct ZoomableImageCanvas: UIViewRepresentable {
    let image: UIImage
    let samples: [SampleMarker]
    var imageWidth: Double = 1
    var imageHeight: Double = 1
    var selected: Int? = nil
    var region: ImageSelection? = nil
    var displacements: [DisplacementMarker] = []
    var selecting = false
    var movingSamples = false
    var onSampleMove: ((Int, Double, Double) -> Void)? = nil
    var onSelection: ((ImageSelection) -> Void)? = nil
    let onTap: ((Double, Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        context.coordinator.install(on: scroll)
        return scroll
    }
    func updateUIView(_ scroll: CanvasScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(scroll)
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImageCanvas
        weak var scroll: CanvasScrollView?
        weak var selectGesture: UIPanGestureRecognizer?
        weak var moveGesture: UIPanGestureRecognizer?
        private var moving: (marker: SampleMarker, offset: CGPoint)?
        private var selectionStart: CGPoint?
        init(_ parent: ZoomableImageCanvas) { self.parent = parent }
        func install(on scroll: CanvasScrollView) {
            self.scroll = scroll
            scroll.delegate = self
            scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 12
            scroll.backgroundColor = .black
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            scroll.canvas.addGestureRecognizer(tap)
            let select = UIPanGestureRecognizer(target: self, action: #selector(selectRegion(_:)))
            select.maximumNumberOfTouches = 1
            scroll.canvas.addGestureRecognizer(select); selectGesture = select
            let move = UIPanGestureRecognizer(target: self, action: #selector(moveSample(_:)))
            move.maximumNumberOfTouches = 1; move.delegate = self
            scroll.canvas.addGestureRecognizer(move); moveGesture = move
            tap.require(toFail: move)
            scroll.accessibilityLabel = "图像，可双指缩放和拖动；选择移动模式可单指拖动背景采样点"
            update(scroll)
        }
        func update(_ scroll: CanvasScrollView) {
            scroll.picture.image = parent.image
            scroll.markers = parent.samples
            scroll.sourceSize = CGSize(width: parent.imageWidth, height: parent.imageHeight)
            scroll.selected = parent.selected; scroll.region = parent.region
            scroll.displacements = parent.displacements
            selectGesture?.isEnabled = parent.selecting
            moveGesture?.isEnabled = parent.movingSamples && !parent.selecting
            scroll.panGestureRecognizer.minimumNumberOfTouches = parent.selecting || parent.movingSamples ? 2 : 1
            scroll.setNeedsLayout()
        }
        private func sample(at p: CGPoint) -> SampleMarker? {
            guard let scroll, scroll.canvas.bounds.width > 0, scroll.canvas.bounds.height > 0,
                  scroll.canvas.bounds.contains(p) else { return nil }
            let sx = scroll.canvas.bounds.width / parent.imageWidth
            let sy = scroll.canvas.bounds.height / parent.imageHeight
            return parent.samples.filter {
                abs(p.x - $0.x * sx) <= max($0.size * sx / 2, 12 / scroll.zoomScale) &&
                abs(p.y - $0.y * sy) <= max($0.size * sy / 2, 12 / scroll.zoomScale)
            }.min { hypot(p.x - $0.x * sx, p.y - $0.y * sy) < hypot(p.x - $1.x * sx, p.y - $1.y * sy) }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === moveGesture, let scroll else { return true }
            return parent.movingSamples && sample(at: gestureRecognizer.location(in: scroll.canvas)) != nil
        }
        func beginSampleMove(at p: CGPoint) -> Bool {
            guard parent.movingSamples, let scroll, let marker = sample(at: p) else { return false }
            moving = (marker, CGPoint(x: marker.x - p.x / scroll.canvas.bounds.width * parent.imageWidth,
                                      y: marker.y - p.y / scroll.canvas.bounds.height * parent.imageHeight))
            scroll.selected = marker.id
            return true
        }
        func updateSampleMove(at p: CGPoint) {
            guard let scroll, let moving else { return }
            let x = min(parent.imageWidth - 13, max(12, round(p.x / scroll.canvas.bounds.width * parent.imageWidth + moving.offset.x)))
            let y = min(parent.imageHeight - 13, max(12, round(p.y / scroll.canvas.bounds.height * parent.imageHeight + moving.offset.y)))
            scroll.markers = parent.samples.map {
                $0.id == moving.marker.id ? SampleMarker(id: $0.id, x: x, y: y, size: $0.size, median: $0.median) : $0
            }
            scroll.setNeedsLayout()
        }
        func finishSampleMove(cancelled: Bool) {
            guard let scroll, let moving else { return }
            let moved = scroll.markers.first { $0.id == moving.marker.id }
            self.moving = nil
            scroll.markers = parent.samples; scroll.selected = parent.selected; scroll.setNeedsLayout()
            if !cancelled, let moved, moved.x != moving.marker.x || moved.y != moving.marker.y {
                parent.onSampleMove?(moved.id, moved.x, moved.y)
            }
        }
        @objc func moveSample(_ gesture: UIPanGestureRecognizer) {
            guard let scroll else { return }
            let p = gesture.location(in: scroll.canvas)
            switch gesture.state {
            case .began: _ = beginSampleMove(at: p); updateSampleMove(at: p)
            case .changed: updateSampleMove(at: p)
            case .ended: updateSampleMove(at: p); finishSampleMove(cancelled: false)
            case .cancelled, .failed: finishSampleMove(cancelled: true)
            default: break
            }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.canvas }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll, let onTap = parent.onTap else { return }
            let p = gesture.location(in: scroll.canvas)
            guard scroll.canvas.bounds.contains(p), scroll.canvas.bounds.width > 0 else { return }
            onTap(p.x / scroll.canvas.bounds.width * parent.imageWidth,
                  p.y / scroll.canvas.bounds.height * parent.imageHeight)
        }
        @objc func selectRegion(_ gesture: UIPanGestureRecognizer) {
            guard let scroll, scroll.canvas.bounds.width > 0, scroll.canvas.bounds.height > 0 else { return }
            let p = gesture.location(in: scroll.canvas)
            let point = CGPoint(x: p.x / scroll.canvas.bounds.width * parent.imageWidth,
                                y: p.y / scroll.canvas.bounds.height * parent.imageHeight)
            if gesture.state == .began { selectionStart = point }
            guard let start = selectionStart else { return }
            let selection = ImageSelection.between(start, point, width: Int(parent.imageWidth), height: Int(parent.imageHeight))
            if gesture.state == .began || gesture.state == .changed {
                scroll.region = selection
                scroll.setNeedsLayout()
            } else if gesture.state == .ended {
                selectionStart = nil
                parent.onSelection?(selection)
            } else if gesture.state == .cancelled || gesture.state == .failed {
                selectionStart = nil
                scroll.region = parent.region
                scroll.setNeedsLayout()
            }
        }
    }
}

final class CanvasScrollView: UIScrollView {
    let canvas = UIView()
    let picture = UIImageView()
    private let boxes = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private let selectionBox = CAShapeLayer()
    private let converged = CAShapeLayer()
    private let failed = CAShapeLayer()
    var markers: [SampleMarker] = []
    var sourceSize = CGSize(width: 1, height: 1)
    var selected: Int?
    var region: ImageSelection?
    var displacements: [DisplacementMarker] = []
    private var lastBounds = CGSize.zero
    private var lastImageSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(canvas)
        canvas.addSubview(picture)
        picture.contentMode = .scaleToFill
        for layer in [boxes, highlight, selectionBox, converged, failed] {
            layer.fillColor = UIColor.clear.cgColor
            canvas.layer.addSublayer(layer)
        }
        boxes.strokeColor = UIColor.systemGreen.cgColor
        highlight.strokeColor = UIColor.systemYellow.cgColor
        selectionBox.strokeColor = UIColor.systemCyan.cgColor
        converged.strokeColor = UIColor.systemGreen.cgColor
        failed.strokeColor = UIColor.systemRed.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = picture.image, bounds.width > 0, bounds.height > 0 else { return }
        if lastBounds != bounds.size || lastImageSize != image.size {
            lastBounds = bounds.size; lastImageSize = image.size
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            canvas.frame = CGRect(origin: .zero, size: size)
            picture.frame = canvas.bounds
            contentSize = size
        }
        let insetX = max(0, (bounds.width - contentSize.width) / 2)
        let insetY = max(0, (bounds.height - contentSize.height) / 2)
        let desiredInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if contentInset != desiredInset { contentInset = desiredInset }
        let normal = UIBezierPath(), active = UIBezierPath()
        for marker in markers {
            let sx = canvas.bounds.width / max(1, sourceSize.width)
            let sy = canvas.bounds.height / max(1, sourceSize.height)
            let w = max(marker.size * sx, 5 / zoomScale)
            let h = max(marker.size * sy, 5 / zoomScale)
            let rect = CGRect(x: marker.x * sx - w / 2, y: marker.y * sy - h / 2, width: w, height: h)
            (marker.id == selected ? active : normal).append(UIBezierPath(rect: rect))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        boxes.path = normal.cgPath; highlight.path = active.cgPath
        boxes.lineWidth = 1.5 / zoomScale; highlight.lineWidth = 2.5 / zoomScale
        if let region {
            let sx = canvas.bounds.width / max(1, sourceSize.width)
            let sy = canvas.bounds.height / max(1, sourceSize.height)
            selectionBox.path = UIBezierPath(rect: CGRect(x: Double(region.x) * sx, y: Double(region.y) * sy,
                width: Double(region.width) * sx, height: Double(region.height) * sy)).cgPath
        } else { selectionBox.path = nil }
        selectionBox.lineWidth = 1.5 / zoomScale
        let goodPath = UIBezierPath(), failedPath = UIBezierPath()
        let sx = canvas.bounds.width / max(1, sourceSize.width), sy = canvas.bounds.height / max(1, sourceSize.height)
        for vector in displacements {
            let path = vector.success ? goodPath : failedPath
            let start = CGPoint(x: vector.x * sx, y: vector.y * sy)
            let end = CGPoint(x: (vector.x + vector.dx) * sx, y: (vector.y + vector.dy) * sy)
            path.move(to: start); path.addLine(to: end)
            let radius = 2.5 / zoomScale
            path.append(UIBezierPath(ovalIn: CGRect(x: start.x - radius, y: start.y - radius, width: 2 * radius, height: 2 * radius)))
            let length = hypot(end.x - start.x, end.y - start.y)
            if length > 1.5 / zoomScale {
                let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length, head = 7 / zoomScale
                path.move(to: CGPoint(x: end.x - head * ux - head * uy / 2, y: end.y - head * uy + head * ux / 2))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: end.x - head * ux + head * uy / 2, y: end.y - head * uy - head * ux / 2))
            }
        }
        converged.path = goodPath.cgPath; failed.path = failedPath.cgPath
        converged.lineWidth = 1.2 / zoomScale; failed.lineWidth = 1.2 / zoomScale
        CATransaction.commit()
    }
}
