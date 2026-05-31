import SwiftUI
import TactileMapCore
import TactileMapFeedback

/// Generic map canvas that renders any TactileMapDocument.
/// Corridors are drawn from JSON features; filled discs at multi-corridor
/// junctions cover the star artifact that appears when thick lines meet at a point.
struct GenericMapCanvasView: View {
    let document: TactileMapDocument
    let policy: any FeedbackPolicy

    @State private var activeID:    String?  = nil
    @State private var touchPoint:  CGPoint? = nil
    @State private var touchAngle:  CGFloat  = -.pi / 2  // default: pointing up

    // MARK: - Colors
    private let bgColor        = Color.black
    private let corridorColor  = Color(red: 0.224, green: 0.490, blue: 0.259)  // #397D42
    private let landmarkFill   = Color(red: 0.78,  green: 0.52,  blue: 0.22)   // #C78538
    private let landmarkBorder = Color(red: 0.65,  green: 0.43,  blue: 0.18)   // #A66E2E
    private let nodeColor      = Color(red: 0.29,  green: 0.56,  blue: 0.85)   // #4A90D9

    // MARK: - Sizes in JSON coordinate space
    private let corridorJSONWidth: CGFloat = 65
    private let landmarkJSONSize:  CGFloat = 110
    private let majorJSONRadius:   CGFloat = 14
    private let minorJSONRadius:   CGFloat = 7
    private let mapPadding:        CGFloat = 8

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let t = makeTransform(size: geo.size)
            bgColor
                .overlay(
                    Canvas { ctx, _ in
                        drawCorridors(ctx, t: t)
                        drawLandmarks(ctx, t: t)
                        drawNodes(ctx, t: t)
                        drawCenterIcon(ctx, t: t)
                        if let pt = touchPoint {
                            drawTouchIndicator(ctx, at: pt, angle: touchAngle)
                        }
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let pt = v.location
                            if let prev = touchPoint {
                                let dx = pt.x - prev.x
                                let dy = pt.y - prev.y
                                if dx * dx + dy * dy > 4 {
                                    touchAngle = atan2(dy, dx)
                                }
                            }
                            touchPoint = pt
                            Task { @MainActor in touch(at: pt, t: t) }
                        }
                        .onEnded { _ in
                            touchPoint = nil
                            Task { @MainActor in lift() }
                        }
                )
        }
    }

    // MARK: - Transform

    private struct MapTransform: @unchecked Sendable {
        let scale: CGFloat
        let ox: CGFloat
        let oy: CGFloat

        func apply(_ c: TactileCoordinate) -> CGPoint {
            CGPoint(x: CGFloat(c.x) * scale + ox,
                    y: CGFloat(c.y) * scale + oy)
        }

        func scaled(_ jsonUnits: CGFloat) -> CGFloat { jsonUnits * scale }
    }

    private func makeTransform(size: CGSize) -> MapTransform {
        let availW = size.width  - mapPadding * 2
        let availH = size.height - mapPadding * 2
        let scale  = min(availW / CGFloat(document.bounds.width),
                         availH / CGFloat(document.bounds.height))
        let ox = (size.width  - CGFloat(document.bounds.width)  * scale) / 2
        let oy = (size.height - CGFloat(document.bounds.height) * scale) / 2
        return MapTransform(scale: scale, ox: ox, oy: oy)
    }

    // MARK: - Corridor Rendering (Generic — reads from document.features)

    private func drawCorridors(_ ctx: GraphicsContext, t: MapTransform) {
        let normalW   = t.scaled(corridorJSONWidth)
        let mainRoadW = t.scaled(corridorJSONWidth + 20)

        for f in document.features where f.elementType == .corridor {
            guard case .lineString(let pts) = f.geometry, pts.count >= 2 else { continue }
            let isMainRoad = f.id == "c-h-left" || f.id == "c-h-right"
            let strokeW = isMainRoad ? mainRoadW : normalW
            var path = Path()
            path.move(to: t.apply(pts[0]))
            for pt in pts.dropFirst() { path.addLine(to: t.apply(pt)) }
            ctx.stroke(path, with: .color(corridorColor),
                       style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
        }

        // Junction discs — use the larger width at crossbar junctions so the
        // disc fully covers the gap between the wide crossbar and thinner arms.
        for f in document.features where f.elementType == .intersection {
            guard (f.properties.connectedCorridors?.count ?? 0) >= 2,
                  case .point(let c) = f.geometry else { continue }
            let connectedToMain = f.properties.connectedCorridors?.contains(where: {
                $0 == "c-h-left" || $0 == "c-h-right"
            }) ?? false
            let discR = (connectedToMain ? mainRoadW : normalW) / 2
            let center = t.apply(c)
            let rect = CGRect(x: center.x - discR, y: center.y - discR,
                              width: discR * 2, height: discR * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(corridorColor))
        }
    }

    // MARK: - Drawing (landmarks, nodes, center icon — identical to MapCanvasViewV2)

    private func drawLandmarks(_ ctx: GraphicsContext, t: MapTransform) {
        let sideLen = t.scaled(landmarkJSONSize)
        let corner  = t.scaled(4)
        let borderW = t.scaled(3)
        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            let category = f.properties.category ?? ""
            if category == "entrance" || category == "traffic_signal" {
                drawTrafficSignalIcon(ctx, at: center, t: t)
                continue
            }
            let half = sideLen / 2
            let rect = CGRect(x: center.x - half, y: center.y - half,
                              width: sideLen, height: sideLen)
            let shape = Path(roundedRect: rect, cornerRadius: corner)
            ctx.fill(shape, with: .color(landmarkFill))
            ctx.stroke(shape, with: .color(landmarkBorder), lineWidth: borderW)
        }
    }

    private func drawTrafficSignalIcon(_ ctx: GraphicsContext, at center: CGPoint, t: MapTransform) {
        let scale  = t.scaled(1)
        let bodyW  = 30 * scale
        let bodyH  = 55 * scale
        let lightR = 7  * scale
        let spacing = 16 * scale

        // Dark rounded body
        let bodyRect  = CGRect(x: center.x - bodyW / 2, y: center.y - bodyH / 2,
                               width: bodyW, height: bodyH)
        let bodyShape = Path(roundedRect: bodyRect, cornerRadius: 4 * scale)
        ctx.fill(bodyShape,   with: .color(Color(white: 0.15)))
        ctx.stroke(bodyShape, with: .color(.white), lineWidth: max(1, 2 * scale))

        // Three lights — red (top), yellow (middle), green (bottom)
        let lights: [(Color, CGFloat)] = [
            (Color(red: 0.9,  green: 0.2, blue: 0.2), -spacing),
            (Color(red: 0.95, green: 0.8, blue: 0.2),  0),
            (Color(red: 0.2,  green: 0.8, blue: 0.3),  spacing)
        ]
        for (color, dy) in lights {
            let lc   = CGPoint(x: center.x, y: center.y + dy)
            let rect = CGRect(x: lc.x - lightR, y: lc.y - lightR,
                              width: lightR * 2, height: lightR * 2)
            ctx.fill(Path(ellipseIn: rect),   with: .color(color))
            ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.5)),
                       lineWidth: max(0.5, 1.5 * scale))
        }

        // Pole below body
        let poleW = 4 * scale
        let poleH = 15 * scale
        var pole  = Path()
        pole.addRect(CGRect(x: center.x - poleW / 2, y: center.y + bodyH / 2,
                            width: poleW, height: poleH))
        ctx.fill(pole, with: .color(Color(white: 0.3)))
    }

    private func drawNodes(_ ctx: GraphicsContext, t: MapTransform) {
        let minorR = t.scaled(minorJSONRadius)

        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let anchor = anchorCenter(for: f, screenPt: t.apply(c), t: t)
            let rect   = circleRect(center: anchor, radius: minorR)
            ctx.fill(Path(ellipseIn: rect), with: .color(nodeColor))
        }
    }

    private func drawCenterIcon(_ ctx: GraphicsContext, t: MapTransform) {
        let iconR = t.scaled(majorJSONRadius) * 0.65
        guard iconR >= 4,
              let cf = document.features
                  .filter({ $0.elementType == .intersection })
                  .max(by: {
                      ($0.properties.connectedCorridors?.count ?? 0) <
                      ($1.properties.connectedCorridors?.count ?? 0)
                  }),
              case .point(let c) = cf.geometry else { return }

        let center    = t.apply(c)
        let lineW     = max(1, t.scaled(2.5))
        let darkGreen = Color(red: 0.08, green: 0.22, blue: 0.08)
        let gap       = iconR * 0.4

        for dy in [-gap, gap] {
            var p = Path()
            p.move(to: CGPoint(x: center.x - iconR, y: center.y + dy))
            p.addLine(to: CGPoint(x: center.x + iconR, y: center.y + dy))
            ctx.stroke(p, with: .color(darkGreen), lineWidth: lineW)
        }
        for dx in [-gap, gap] {
            var p = Path()
            p.move(to: CGPoint(x: center.x + dx, y: center.y - iconR))
            p.addLine(to: CGPoint(x: center.x + dx, y: center.y + iconR))
            ctx.stroke(p, with: .color(darkGreen), lineWidth: lineW)
        }
    }

    // MARK: - Touch Indicator

    private func drawTouchIndicator(_ ctx: GraphicsContext, at pt: CGPoint, angle: CGFloat) {
        let ringR:      CGFloat = 20
        let centerR:    CGFloat = 5
        let tipDist:    CGFloat = 36   // center → arrow tip
        let baseDist:   CGFloat = 22   // center → arrow base (at ring edge)
        let halfWidth:  CGFloat = 7    // half-width of arrow triangle base

        // Semi-transparent yellow disc + white ring
        let ringRect = circleRect(center: pt, radius: ringR)
        ctx.fill(Path(ellipseIn: ringRect),
                 with: .color(Color(red: 1.0, green: 0.88, blue: 0.0).opacity(0.28)))
        ctx.stroke(Path(ellipseIn: ringRect),
                   with: .color(.white.opacity(0.88)), lineWidth: 2.5)

        // White center dot
        ctx.fill(Path(ellipseIn: circleRect(center: pt, radius: centerR)),
                 with: .color(.white))

        // Direction arrow (triangle pointing in angle direction)
        let cosA = cos(angle), sinA = sin(angle)
        let cosP = cos(angle + .pi / 2), sinP = sin(angle + .pi / 2)

        let tip = CGPoint(x: pt.x + cosA * tipDist,  y: pt.y + sinA * tipDist)
        let bx  = pt.x + cosA * baseDist
        let by  = pt.y + sinA * baseDist
        let bl  = CGPoint(x: bx + cosP * halfWidth,  y: by + sinP * halfWidth)
        let br  = CGPoint(x: bx - cosP * halfWidth,  y: by - sinP * halfWidth)

        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: bl)
        arrow.addLine(to: br)
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(.white))
    }

    // MARK: - Helpers

    private func circleRect(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius,
               width: radius * 2, height: radius * 2)
    }

    private func anchorCenter(for feature: MapElement, screenPt: CGPoint, t: MapTransform) -> CGPoint {
        let side    = feature.properties.side ?? "right"
        let jsonOff = landmarkJSONSize / 2 + 10 + minorJSONRadius
        let scrOff  = t.scaled(jsonOff)
        let xOff: CGFloat = (side == "left") ? scrOff : -scrOff
        return CGPoint(x: screenPt.x + xOff, y: screenPt.y)
    }

    // MARK: - Hit Testing

    private func hitElement(at point: CGPoint, t: MapTransform) -> (MapElement, TouchType)? {
        let minorR  = t.scaled(minorJSONRadius)
        let majorR  = t.scaled(majorJSONRadius)
        let halfLen = t.scaled(landmarkJSONSize) / 2
        let corrHW  = t.scaled(corridorJSONWidth) / 2

        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let anchor = anchorCenter(for: f, screenPt: t.apply(c), t: t)
            if dist(point, anchor) <= minorR + 6 { return (f, .anchor) }
        }
        for f in document.features where f.elementType == .intersection {
            guard case .point(let c) = f.geometry else { continue }
            if dist(point, t.apply(c)) <= majorR + 8 { return (f, .direct) }
        }
        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            if abs(point.x - center.x) <= halfLen + 8 && abs(point.y - center.y) <= halfLen + 8 {
                return (f, .direct)
            }
        }
        for f in document.features where f.elementType == .corridor {
            guard case .lineString(let pts) = f.geometry, pts.count >= 2 else { continue }
            for i in 0..<pts.count - 1 {
                if distToSegment(point, t.apply(pts[i]), t.apply(pts[i + 1])) <= corrHW + 8 {
                    return (f, .direct)
                }
            }
        }
        return nil
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return dist(p, a) }
        let u = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return dist(p, CGPoint(x: a.x + u * dx, y: a.y + u * dy))
    }

    // MARK: - Touch Handling

    @MainActor
    private func touch(at point: CGPoint, t: MapTransform) {
        guard let (hit, touchType) = hitElement(at: point, t: t) else {
            if let cur = activeElement() { policy.onExit(element: cur) }
            activeID = nil
            return
        }
        if hit.id == activeID {
            if let cur = activeElement() { policy.onContinue(element: cur, touchType: touchType) }
        } else {
            if let cur = activeElement() { policy.onExit(element: cur) }
            policy.onEnter(element: hit, touchType: touchType)
            activeID = hit.id
        }
    }

    @MainActor
    private func lift() {
        if let cur = activeElement() { policy.onExit(element: cur) }
        activeID = nil
        policy.stopAll()
    }

    private func activeElement() -> MapElement? {
        guard let id = activeID else { return nil }
        return document.features.first { $0.id == id }
    }
}
