import SwiftUI
import TactileMapCore
import TactileMapFeedback

struct MapCanvasView: View {
    let document: TactileMapDocument
    let policy: any FeedbackPolicy

    @State private var activeID: String? = nil

    // MARK: - Colors
    private let bgColor        = Color.white
    private let corridorColor  = Color(red: 0.224, green: 0.490, blue: 0.259)  // #397D42 dark forest green
    private let landmarkFill   = Color(red: 0.78,  green: 0.52,  blue: 0.22)   // #C78538 warm brown-orange
    private let landmarkBorder = Color(red: 0.65,  green: 0.43,  blue: 0.18)   // #A66E2E darker border
    private let nodeColor      = Color(red: 0.29,  green: 0.56,  blue: 0.85)   // #4A90D9 blue

    // MARK: - Sizes in JSON coordinate space
    private let corridorJSONWidth:   CGFloat = 65   // fork polygon + vertical stroke
    private let horizontalJSONWidth: CGFloat = 72   // dominant crossbar (slightly thicker)
    private let landmarkJSONSize:    CGFloat = 100  // ~1.5× corridor width
    private let majorJSONRadius:     CGFloat = 14   // intersection circles
    private let minorJSONRadius:     CGFloat = 7    // anchor dots
    private let mapPadding:          CGFloat = 15

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let t = makeTransform(size: geo.size)
            bgColor
                .overlay(
                    Canvas { ctx, _ in
                        drawCorridors(ctx: ctx, t: t)
                        drawLandmarks(ctx: ctx, t: t)
                        drawNodes(ctx: ctx, t: t)
                        drawCenterIcon(ctx: ctx, t: t)
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let pt = v.location
                            Task { @MainActor in touch(at: pt, t: t) }
                        }
                        .onEnded { _ in
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

    // MARK: - Corridor helpers

    private func corridorFeature(_ id: String) -> MapElement? {
        document.features.first { $0.id == id && $0.elementType == .corridor }
    }

    private func corridorPath(_ f: MapElement, t: MapTransform) -> Path {
        guard case .lineString(let pts) = f.geometry, pts.count >= 2 else { return Path() }
        var path = Path()
        path.move(to: t.apply(pts[0]))
        for pt in pts.dropFirst() { path.addLine(to: t.apply(pt)) }
        return path
    }

    // MARK: - Drawing

    private func drawCorridors(ctx: GraphicsContext, t: MapTransform) {
        let vertW   = t.scaled(corridorJSONWidth)
        let horizW  = t.scaled(horizontalJSONWidth)
        let style   = { (w: CGFloat) in StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }

        // Layer 1 (BACK): SW + SE fork drawn as one solid filled polygon.
        // This makes the split look like a single road forking, not two separate lines.
        drawForkPolygon(ctx: ctx, t: t)

        // Layer 2: North corridor — vertical arm, covers the top of the junction.
        if let north = corridorFeature("c-north") {
            ctx.stroke(corridorPath(north, t: t), with: .color(corridorColor), style: style(vertW))
        }

        // Layer 3 (FRONT): Horizontal crossbar drawn last — paints cleanly over the junction.
        for id in ["c-west", "c-east"] {
            if let f = corridorFeature(id) {
                ctx.stroke(corridorPath(f, t: t), with: .color(corridorColor), style: style(horizW))
            }
        }
    }

    // Renders the SW + SE fork arms and shared stem as ONE filled polygon.
    // Tracing the outline clockwise: stem top cap → right stem → SE outer edge → SE end cap
    // → SE inner edge back to fork → bridge → SW inner edge → SW end cap → SW outer edge → left stem.
    private func drawForkPolygon(ctx: GraphicsContext, t: MapTransform) {
        let halfW = t.scaled(corridorJSONWidth) / 2

        // Screen-space key points
        let stemTop = t.apply(TactileCoordinate(x: 500, y: 720))
        let forkPt  = t.apply(TactileCoordinate(x: 500, y: 870))  // stem end / fork start
        let swEnd   = t.apply(TactileCoordinate(x: 120, y: 1560))
        let seEnd   = t.apply(TactileCoordinate(x: 880, y: 1560))

        // Perpendicular normal for SW arm (forkPt → swEnd), scaled to halfW
        let swDx = swEnd.x - forkPt.x
        let swDy = swEnd.y - forkPt.y
        let swLen = hypot(swDx, swDy)
        let swNx = (-swDy / swLen) * halfW
        let swNy = ( swDx / swLen) * halfW

        // Perpendicular normal for SE arm (forkPt → seEnd), scaled to halfW
        let seDx = seEnd.x - forkPt.x
        let seDy = seEnd.y - forkPt.y
        let seLen = hypot(seDx, seDy)
        let seNx = (-seDy / seLen) * halfW
        let seNy = ( seDx / seLen) * halfW

        var path = Path()

        // Start at top-left of stem
        path.move(to: CGPoint(x: stemTop.x - halfW, y: stemTop.y))

        // Round cap at top of stem (180° → 0°, CCW)
        path.addArc(center: stemTop, radius: halfW,
                    startAngle: .degrees(180), endAngle: .degrees(0),
                    clockwise: false)

        // Right side of stem down to fork point, then outer edge of SE arm to SE end
        path.addLine(to: CGPoint(x: forkPt.x + halfW, y: forkPt.y))
        path.addLine(to: CGPoint(x: seEnd.x + seNx,   y: seEnd.y + seNy))

        // Round cap at SE end
        let seAngle = Double(atan2(seNy, seNx))
        path.addArc(center: seEnd, radius: halfW,
                    startAngle: Angle(radians: seAngle),
                    endAngle:   Angle(radians: seAngle + .pi),
                    clockwise: false)

        // Inner (left) edge of SE arm back toward fork, bridge to inner edge of SW arm
        path.addLine(to: CGPoint(x: forkPt.x - seNx, y: forkPt.y - seNy))
        path.addLine(to: CGPoint(x: forkPt.x + swNx, y: forkPt.y + swNy))

        // Inner edge of SW arm to SW end
        path.addLine(to: CGPoint(x: swEnd.x + swNx, y: swEnd.y + swNy))

        // Round cap at SW end
        let swAngle = Double(atan2(swNy, swNx))
        path.addArc(center: swEnd, radius: halfW,
                    startAngle: Angle(radians: swAngle),
                    endAngle:   Angle(radians: swAngle + .pi),
                    clockwise: false)

        // Outer (left) edge of SW arm back to fork, then left side of stem back to start
        path.addLine(to: CGPoint(x: forkPt.x - swNx, y: forkPt.y - swNy))
        path.addLine(to: CGPoint(x: stemTop.x - halfW, y: stemTop.y))

        path.closeSubpath()
        ctx.fill(path, with: .color(corridorColor))
    }

    private func drawLandmarks(ctx: GraphicsContext, t: MapTransform) {
        let sideLen = t.scaled(landmarkJSONSize)
        let corner  = t.scaled(4)
        let borderW = t.scaled(3)
        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            let half   = sideLen / 2
            let rect   = CGRect(x: center.x - half, y: center.y - half,
                                width: sideLen, height: sideLen)
            let shape = Path(roundedRect: rect, cornerRadius: corner)
            ctx.fill(shape, with: .color(landmarkFill))
            ctx.stroke(shape, with: .color(landmarkBorder), lineWidth: borderW)
        }
    }

    private func drawNodes(ctx: GraphicsContext, t: MapTransform) {
        let majorR  = t.scaled(majorJSONRadius)
        let minorR  = t.scaled(minorJSONRadius)
        let borderW = max(1, t.scaled(2.5))

        // Intersection nodes — blue fill + white border
        for f in document.features where f.elementType == .intersection {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            let rect   = circleRect(center: center, radius: majorR)
            ctx.fill(Path(ellipseIn: rect), with: .color(nodeColor))
            ctx.stroke(Path(ellipseIn: rect), with: .color(Color(white: 0.25)), lineWidth: borderW)
        }

        // Anchor dots — solid blue, no border, adjacent to each landmark
        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let anchor = anchorCenter(for: f, screenPt: t.apply(c), t: t)
            let rect   = circleRect(center: anchor, radius: minorR)
            ctx.fill(Path(ellipseIn: rect), with: .color(nodeColor))
        }
    }

    // Crosshatch icon at the main junction (only when the circle is large enough to show detail)
    private func drawCenterIcon(ctx: GraphicsContext, t: MapTransform) {
        let iconR = t.scaled(majorJSONRadius) * 0.65
        guard iconR >= 4,
              let cf = document.features.first(where: {
                  $0.elementType == .intersection &&
                  ($0.properties.connectedCorridors?.count ?? 0) > 1
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

    // MARK: - Helpers

    private func circleRect(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius,
               width: radius * 2, height: radius * 2)
    }

    // Anchor dot positioned just outside the landmark square on the corridor side.
    // "left" side = landmark is left of corridor → dot offset rightward (+x) toward corridor.
    private func anchorCenter(for feature: MapElement, screenPt: CGPoint, t: MapTransform) -> CGPoint {
        let side    = feature.properties.side ?? "right"
        let jsonOff = landmarkJSONSize / 2 + 10 + minorJSONRadius  // clears the square edge
        let scrOff  = t.scaled(jsonOff)
        let xOff: CGFloat = (side == "left") ? scrOff : -scrOff
        return CGPoint(x: screenPt.x + xOff, y: screenPt.y)
    }

    // MARK: - Hit testing (unchanged — still uses original JSON line segments)

    private func hitElement(at point: CGPoint, t: MapTransform) -> (MapElement, TouchType)? {
        let minorR  = t.scaled(minorJSONRadius)
        let majorR  = t.scaled(majorJSONRadius)
        let halfLen = t.scaled(landmarkJSONSize) / 2
        let corrHW  = t.scaled(corridorJSONWidth) / 2

        // Anchor dots first (highest priority — smallest visual target)
        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let anchor = anchorCenter(for: f, screenPt: t.apply(c), t: t)
            if dist(point, anchor) <= minorR + 6 { return (f, .anchor) }
        }
        // Intersection nodes
        for f in document.features where f.elementType == .intersection {
            guard case .point(let c) = f.geometry else { continue }
            if dist(point, t.apply(c)) <= majorR + 8 { return (f, .direct) }
        }
        // Landmark squares
        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            if abs(point.x - center.x) <= halfLen + 8 && abs(point.y - center.y) <= halfLen + 8 {
                return (f, .direct)
            }
        }
        // Corridors (uses original JSON segments — works for all corridors including SW/SE)
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

    // MARK: - Touch handling

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
