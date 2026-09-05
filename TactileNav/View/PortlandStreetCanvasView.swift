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
import TactileMapCore
import UIKit

final class PortlandStreetCanvasView: UIView {

    var map: StreetMap? {
        didSet { setNeedsDisplay() }
    }

    /// The study route, if this screen is showing one. `nil` draws the plain map.
    var route: RouteScene? {
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
        // The route, if there is one, sits above the road it runs on — same order as the
        // reference app's overlay — and under the junction markers, which stay the one thing
        // that always wins the top of the stack.
        strokeRoute(route, in: ctx)
        // Junction markers sit on top of the road network, the way a painted marking does, and
        // under the labels so a street name is never hidden behind a box.
        drawIntersections(map.intersections(in: window), in: ctx)
        // The route's own landmarks outrank even a junction — same as the close-up, and for
        // the same reason: they are the things on this map more specific than "you have
        // arrived." Turns under the ends, so a turn that happens to be the destination reads
        // as the destination.
        drawRouteTurns(route, in: ctx)
        drawRouteEndpoints(route, in: ctx)
        drawLabels(map.labels(in: window), in: ctx)

        ctx.restoreGState()
    }

    /// A red square at each junction, with a thin white outline.
    ///
    /// The outline is what keeps the box from reading as a hole cut in the road where it sits
    /// on the dark blue — the same reason a real painted marking is edged against its asphalt.
    private func drawIntersections(_ items: [Intersection], in ctx: CGContext) {
        guard !items.isEmpty else { return }
        let border = max(PhysicalDimensions.mmToPoints(StreetMapSizing.intersectionBorderMM), 1)
        for junction in items {
            let box = CGRect(x: junction.position.x - junction.boxWidth / 2,
                             y: junction.position.y - junction.boxWidth / 2,
                             width: junction.boxWidth, height: junction.boxWidth)
            ctx.setFillColor(StreetMapSizing.intersectionColor)
            ctx.fill(box)
            ctx.setStrokeColor(StreetMapSizing.intersectionBorderColor)
            ctx.setLineWidth(border)
            // Stroke inside the fill so the white ring does not eat into the neighbouring road.
            ctx.stroke(box.insetBy(dx: border / 2, dy: border / 2))
        }
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

    /// The study route: a thin cyan line over every leg's real road geometry. Never culled to
    /// the viewport — a route is a handful of legs, not the whole network, so there is nothing
    /// worth skipping.
    private func strokeRoute(_ route: RouteScene?, in ctx: CGContext) {
        guard let route, !route.legs.isEmpty else { return }
        ctx.setStrokeColor(StreetMapSizing.routeColor)
        ctx.setLineWidth(PhysicalDimensions.mmToPoints(StreetMapSizing.routeWidthMM))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        for leg in route.legs where leg.points.count >= 2 {
            ctx.move(to: leg.points[0])
            for point in leg.points.dropFirst() { ctx.addLine(to: point) }
        }
        ctx.strokePath()
    }

    /// The route's own start and end, marked once each — same yellow dot as the close-up's,
    /// only ever two of them regardless of how long the route is.
    private func drawRouteEndpoints(_ route: RouteScene?, in ctx: CGContext) {
        guard let route else { return }
        let points = [route.departurePosition, route.destinationPosition].compactMap { $0 }
        drawRouteDots(points, fill: StreetMapSizing.routeEndpointColor,
                      stroke: StreetMapSizing.routeEndpointBorderColor, in: ctx)
    }

    /// Every place the route turns, in orange — the same landmark, and the same colour, as the
    /// close-up draws, so a turn found on the overview is recognisably the same thing when the
    /// junction it belongs to is opened.
    private func drawRouteTurns(_ route: RouteScene?, in ctx: CGContext) {
        guard let route else { return }
        drawRouteDots(route.turns, fill: StreetMapSizing.routeTurnColor,
                      stroke: StreetMapSizing.routeTurnBorderColor, in: ctx)
    }

    private func drawRouteDots(_ points: [CGPoint], fill: CGColor, stroke: CGColor, in ctx: CGContext) {
        guard !points.isEmpty else { return }
        let radius = StreetMapSizing.routeEndpointDiameter / 2
        let border = max(PhysicalDimensions.mmToPoints(StreetMapSizing.routeEndpointBorderMM), 1)
        ctx.setFillColor(fill)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(border)
        for point in points {
            let box = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box.insetBy(dx: border / 2, dy: border / 2))
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
