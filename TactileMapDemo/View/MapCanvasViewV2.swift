import SwiftUI
import TactileMapCore
import TactileMapFeedback

struct MapCanvasViewV2: View {
    let document: TactileMapDocument
    let policy: any FeedbackPolicy

    @State private var activeID: String? = nil

    // MARK: - Colors
    private let bgColor        = Color.white
    private let corridorColor  = Color(red: 0.224, green: 0.490, blue: 0.259)  // #397D42
    private let landmarkFill   = Color(red: 0.78,  green: 0.52,  blue: 0.22)   // #C78538
    private let landmarkBorder = Color(red: 0.65,  green: 0.43,  blue: 0.18)   // #A66E2E
    private let nodeColor      = Color(red: 0.29,  green: 0.56,  blue: 0.85)   // #4A90D9

    // MARK: - Sizes in JSON coordinate space
    private let corridorJSONWidth:   CGFloat = 65
    private let horizontalJSONWidth: CGFloat = 72
    private let landmarkJSONSize:    CGFloat = 100
    private let majorJSONRadius:     CGFloat = 14
    private let minorJSONRadius:     CGFloat = 7
    private let mapPadding:          CGFloat = 15

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

    // MARK: - Corridor Rendering (Layered Lines Approach)

    private func drawCorridors(_ ctx: GraphicsContext, t: MapTransform) {
        let green        = corridorColor
        let armWidth     = t.scaled(corridorJSONWidth)
        let crossbarWidth = t.scaled(horizontalJSONWidth)

        func strokeLine(from c1: TactileCoordinate, to c2: TactileCoordinate, width: CGFloat) {
            var path = Path()
            path.move(to: t.apply(c1))
            path.addLine(to: t.apply(c2))
            ctx.stroke(path, with: .color(green), style: StrokeStyle(
                lineWidth: width,
                lineCap: .round,
                lineJoin: .round
            ))
        }

        // =============================================
        // 6 LINES, drawn back-to-front. Order matters.
        // =============================================

        // LAYER 1 (BACK): SW diagonal — center junction to SW end
        strokeLine(
            from: TactileCoordinate(x: 500, y: 720),
            to:   TactileCoordinate(x: 120, y: 1560),
            width: armWidth
        )

        // LAYER 2: SE diagonal — center junction to SE end
        strokeLine(
            from: TactileCoordinate(x: 500, y: 720),
            to:   TactileCoordinate(x: 880, y: 1560),
            width: armWidth
        )

        // LAYER 3: STEM PATCH — short vertical covering the messy overlap
        // zone where SW and SE diagonals meet near the junction.
        // The diagonals only become visible below this stem, where they've
        // already diverged — creating a clean fork appearance.
        strokeLine(
            from: TactileCoordinate(x: 500, y: 700),
            to:   TactileCoordinate(x: 500, y: 950),
            width: armWidth
        )

        // LAYER 4: North corridor — top of map down to junction
        strokeLine(
            from: TactileCoordinate(x: 500, y: 60),
            to:   TactileCoordinate(x: 500, y: 720),
            width: armWidth
        )

        // LAYER 5: West horizontal crossbar
        strokeLine(
            from: TactileCoordinate(x: 30, y: 720),
            to:   TactileCoordinate(x: 500, y: 720),
            width: crossbarWidth
        )

        // LAYER 6 (FRONT): East horizontal crossbar
        strokeLine(
            from: TactileCoordinate(x: 500, y: 720),
            to:   TactileCoordinate(x: 970, y: 720),
            width: crossbarWidth
        )
    }

    // MARK: - Drawing (unchanged from MapCanvasView)

    private func drawLandmarks(_ ctx: GraphicsContext, t: MapTransform) {
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

    private func drawNodes(_ ctx: GraphicsContext, t: MapTransform) {
        let majorR  = t.scaled(majorJSONRadius)
        let minorR  = t.scaled(minorJSONRadius)
        let borderW = max(1, t.scaled(2.5))

        for f in document.features where f.elementType == .intersection {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            let rect   = circleRect(center: center, radius: majorR)
            ctx.fill(Path(ellipseIn: rect), with: .color(nodeColor))
            ctx.stroke(Path(ellipseIn: rect), with: .color(Color(white: 0.25)), lineWidth: borderW)
        }

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

    private func anchorCenter(for feature: MapElement, screenPt: CGPoint, t: MapTransform) -> CGPoint {
        let side    = feature.properties.side ?? "right"
        let jsonOff = landmarkJSONSize / 2 + 10 + minorJSONRadius
        let scrOff  = t.scaled(jsonOff)
        let xOff: CGFloat = (side == "left") ? scrOff : -scrOff
        return CGPoint(x: screenPt.x + xOff, y: screenPt.y)
    }

    // MARK: - Hit Testing (uses original JSON corridor segments — stem patch is visual only)

    private func hitElement(at point: CGPoint, t: MapTransform) -> (MapElement, TouchType)? {
        let minorR  = t.scaled(minorJSONRadius)
        let majorR  = t.scaled(majorJSONRadius)
        let halfLen = t.scaled(landmarkJSONSize) / 2
        let corrHW  = t.scaled(corridorJSONWidth) / 2

        // Anchor dots first (highest priority)
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
        // Corridors (original JSON segments — distToSegment handles all 5 corridors)
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
