//
//  PortlandStreetCanvasView.swift
//  TactileNav
//
//  Draws the visible window of the street map.
//
//  At true tactile scale the map is roughly 27,000 x 17,500 points — about 81,000 px wide on
//  a 3x screen, far past the ~16,384 px a CALayer will back. So the canvas is *not* the size
//  of the map. It stays the size of the screen, sits above the scroll view, and redraws the
//  window the scroll view is currently showing, translated by the content offset.
//
//  That keeps every draw on the main thread with no shared mutable state, and the work per
//  frame is small: the spatial index narrows the road network down to the few dozen polylines
//  whose ink can land in the viewport, and everything drawn is precomputed — points, stroke
//  widths and text runs all come ready-made from `StreetMap`.
//

import CoreText
import UIKit

final class PortlandStreetCanvasView: UIView {

    var map: StreetMap? {
        didSet { setNeedsDisplay() }
    }

    /// Scroll position of the window to draw. Setting it repaints.
    var contentOffset: CGPoint = .zero {
        didSet {
            guard contentOffset != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = UIColor(cgColor: StreetMapSizing.backgroundColor)
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let map, let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(StreetMapSizing.backgroundColor)
        ctx.fill(rect)

        // The window of the map this view is showing, in content coordinates.
        let window = CGRect(origin: contentOffset, size: bounds.size).insetBy(dx: -64, dy: -64)

        ctx.saveGState()
        ctx.translateBy(x: -contentOffset.x, y: -contentOffset.y)

        strokeRoads(map.features(in: window), in: ctx)
        drawLabels(map.labels(in: window), in: ctx)

        ctx.restoreGState()
    }

    /// Round caps and joins, so a road ends in a semicircle and turns without a notch. On a
    /// map this dense the joins matter more than the caps: a mitred corner at a bend leaves a
    /// spike of ink pointing away from the street.
    private func strokeRoads(_ features: [StreetFeature], in ctx: CGContext) {
        guard !features.isEmpty else { return }
        ctx.setStrokeColor(StreetMapSizing.roadColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for feature in features where feature.points.count >= 2 {
            ctx.setLineWidth(feature.strokeWidth)
            ctx.beginPath()
            ctx.move(to: feature.points[0])
            for point in feature.points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
    }

    private func drawLabels(_ labels: [StreetLabel], in ctx: CGContext) {
        guard !labels.isEmpty else { return }
        ctx.setFillColor(StreetMapSizing.labelColor)

        for label in labels {
            let textBounds = CTLineGetBoundsWithOptions(label.line, .useOpticalBounds)
            ctx.saveGState()
            ctx.translateBy(x: label.position.x, y: label.position.y)
            ctx.rotate(by: label.rotation)
            // Core Text draws with y up; flip so glyphs aren't mirrored in UIKit's space.
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = CGPoint(x: -textBounds.width / 2, y: -textBounds.height / 4)
            CTLineDraw(label.line, ctx)
            ctx.restoreGState()
        }
    }
}
