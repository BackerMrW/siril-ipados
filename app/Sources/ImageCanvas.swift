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
    var selecting = false
    var onSelection: ((ImageSelection) -> Void)? = nil
    let onTap: ((Double, Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 12
        scroll.backgroundColor = .black
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        scroll.canvas.addGestureRecognizer(tap)
        let select = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectRegion(_:)))
        select.maximumNumberOfTouches = 1
        select.isEnabled = selecting
        scroll.canvas.addGestureRecognizer(select)
        context.coordinator.selectGesture = select
        scroll.accessibilityLabel = "图像，可双指缩放和拖动；背景采样模式下轻点选点"
        context.coordinator.scroll = scroll
        return scroll
    }
    func updateUIView(_ scroll: CanvasScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.picture.image = image
        scroll.markers = samples
        scroll.sourceSize = CGSize(width: imageWidth, height: imageHeight)
        scroll.selected = selected
        scroll.region = region
        context.coordinator.selectGesture?.isEnabled = selecting
        scroll.panGestureRecognizer.minimumNumberOfTouches = selecting ? 2 : 1
        scroll.setNeedsLayout()
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageCanvas
        weak var scroll: CanvasScrollView?
        weak var selectGesture: UIPanGestureRecognizer?
        private var selectionStart: CGPoint?
        init(_ parent: ZoomableImageCanvas) { self.parent = parent }
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
    var markers: [SampleMarker] = []
    var sourceSize = CGSize(width: 1, height: 1)
    var selected: Int?
    var region: ImageSelection?
    private var lastBounds = CGSize.zero
    private var lastImageSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(canvas)
        canvas.addSubview(picture)
        picture.contentMode = .scaleToFill
        for layer in [boxes, highlight, selectionBox] {
            layer.fillColor = UIColor.clear.cgColor
            canvas.layer.addSublayer(layer)
        }
        boxes.strokeColor = UIColor.systemGreen.cgColor
        highlight.strokeColor = UIColor.systemYellow.cgColor
        selectionBox.strokeColor = UIColor.systemCyan.cgColor
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
        CATransaction.commit()
    }
}
