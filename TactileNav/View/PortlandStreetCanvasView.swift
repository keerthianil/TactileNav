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
//  frame is small: the spatial index narrows ~2,000 polylines down to the few dozen whose ink
//  can land in the viewport, and everything drawn is precomputed — points, stroke widths,
//  colours and text runs all come ready-made from `StreetMap`.
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

        let visible = map.features(in: window)

        // Painting order matters: sidewalks sit under the roadway so a road's full width
        // stays readable where the two overlap, and crossings sit on top of the road they
        // span, the way a painted marking does.
        stroke(visible.filter { $0.surface == .sidewalk },
               color: StreetMapSizing.sidewalkColor, in: ctx)
        stroke(visible.filter { $0.surface == .road },
               color: StreetMapSizing.roadColor, in: ctx)
        drawCrosswalks(visible.filter { $0.surface == .crosswalk }, in: ctx)
        drawLabels(map.labels(in: window), in: ctx)

        ctx.restoreGState()
    }

    private func stroke(_ features: [StreetFeature], color: CGColor, in ctx: CGContext) {
        guard !features.isEmpty else { return }
        ctx.setStrokeColor(color)
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

    /// Three evenly spaced stripes along the crossing, with a gap at each end so the pattern
    /// is centred on the span rather than running edge to edge.
    private func drawCrosswalks(_ features: [StreetFeature], in ctx: CGContext) {
        guard !features.isEmpty else { return }
        ctx.setStrokeColor(StreetMapSizing.crosswalkColor)
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)

        let stripeCount = StreetMapSizing.crosswalkStripeCount

        for feature in features {
            let length = polylineLength(feature.points)
            guard length > 1 else { continue }
            ctx.setLineWidth(feature.strokeWidth)

            let stripeLength = StreetMapSizing.crosswalkStripeLength(span: length)
            let gap = max((length - stripeLength * CGFloat(stripeCount)) / CGFloat(stripeCount + 1), 0)
            var offset = gap
            for _ in 0..<stripeCount {
                if let start = pointAlongPolyline(feature.points, distance: offset),
                   let end = pointAlongPolyline(feature.points, distance: offset + stripeLength) {
                    ctx.beginPath()
                    ctx.move(to: start)
                    ctx.addLine(to: end)
                    ctx.strokePath()
                }
                offset += stripeLength + gap
            }
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
