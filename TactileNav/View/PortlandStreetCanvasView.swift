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
        drawCrosswalks(visible.filter { $0.surface == .crosswalk }, metrics: map.metrics, in: ctx)
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

    /// A crossing: a small patch of roadway with zebra bars painted along it.
    ///
    /// Sized to the map's line weights rather than to the real street. A crossing way in the
    /// data spans the whole roadway, which on a four-lane street is several times the width of
    /// the 4 mm line that street is drawn as — at true length the crossing sprawls well past
    /// the road on both sides and stops looking like part of the same drawing.
    ///
    /// The darker patch under the bars is what makes a crossing findable at all: white paint on
    /// a white background is invisible, and drawn straight onto the road it just punches a hole
    /// through it. Real crossings are white on asphalt for the same reason.
    private func drawCrosswalks(_ features: [StreetFeature], metrics: StreetMapSizing.Metrics,
                                in ctx: CGContext) {
        guard !features.isEmpty else { return }

        let length = metrics.roadWidth * StreetMapSizing.crosswalkLengthInRoadWidths
        let width = metrics.roadWidth * StreetMapSizing.crosswalkWidthInRoadWidths
        let count = StreetMapSizing.crosswalkBarCount
        let barWidth = max(width / CGFloat(count * 2 + 1), 1.5)
        let pitch = width / CGFloat(count)

        for feature in features where feature.points.count >= 2 {
            // Centre the mark on the crossing and align it with the way's local direction.
            let centre = polylineMidpoint(feature.points)
            let along = direction(of: feature.points)

            ctx.saveGState()
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.rotate(by: atan2(along.y, along.x))

            ctx.setFillColor(StreetMapSizing.crosswalkSurfaceColor)
            ctx.fill(CGRect(x: -length / 2, y: -width / 2, width: length, height: width))

            ctx.setFillColor(StreetMapSizing.crosswalkColor)
            for bar in 0..<count {
                // Bars run the length of the crossing — you walk along a bar to get across —
                // and repeat sideways over its width.
                let offset = (CGFloat(bar) - CGFloat(count - 1) / 2) * pitch
                ctx.fill(CGRect(x: -length / 2, y: offset - barWidth / 2,
                                width: length, height: barWidth))
            }
            ctx.restoreGState()
        }
    }

    /// Unit vector along the middle of a polyline.
    private func direction(of points: [CGPoint]) -> CGPoint {
        let midIndex = max(points.count / 2, 1)
        let a = points[midIndex - 1], b = points[midIndex]
        let magnitude = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
        return CGPoint(x: (b.x - a.x) / magnitude, y: (b.y - a.y) / magnitude)
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
