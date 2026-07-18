import SwiftUI
import UIKit
import TactileMapCore
import TactileMapFeedback

// MARK: - Canvas Coordinate Transform

/// Maps document JSON coordinates to screen points using a simple
/// scale + offset transform. No geographic projection needed.
struct CanvasMapTransform: @unchecked Sendable {
    let scale: CGFloat
    let ox: CGFloat
    let oy: CGFloat

    /// Convert a document coordinate to a screen point.
    func apply(_ c: TactileCoordinate) -> CGPoint {
        CGPoint(x: CGFloat(c.x) * scale + ox,
                y: CGFloat(c.y) * scale + oy)
    }

    /// Scale a value from JSON coordinate space to screen space.
    func scaled(_ jsonUnits: CGFloat) -> CGFloat { jsonUnits * scale }
}

// MARK: - Canvas Map View (UIViewRepresentable wrapper)

/// A Canvas-based tactile map renderer wrapped in a UIViewRepresentable
/// so that VoiceOver gestures (three-finger swipe, Z-scrub) work correctly.
///
/// The actual Canvas drawing is done by ``CanvasContentView`` (SwiftUI),
/// hosted inside ``AccessibleCanvasHost`` (UIKit) which provides the
/// VoiceOver accessibility overrides.
struct CanvasMapView: UIViewRepresentable {
    let document: TactileMapDocument
    let configuration: TactileMapViewConfiguration
    let hitDetection: HitDetectionConfig
    let policy: any FeedbackPolicy
    var onBackGesture: (() -> Void)?
    var onDoubleTap: ((any TactileMapElement) -> Void)?

    func makeUIView(context: Context) -> AccessibleCanvasHost {
        let host = AccessibleCanvasHost(frame: .zero)
        host.onBackGesture = onBackGesture
        host.isBackGestureEnabled = configuration.isVoiceOverBackGestureEnabled

        // Embed the SwiftUI Canvas content inside the UIKit host view.
        let contentView = CanvasContentView(
            document: document,
            configuration: configuration,
            hitDetection: hitDetection,
            policy: policy
        )
        let hostingController = UIHostingController(rootView: contentView)
        if #available(iOS 16.4, *) {
            hostingController.safeAreaRegions = []
        }
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: host.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        // Store the hosting controller so it isn't deallocated.
        context.coordinator.hostingController = hostingController

        // Install three-finger gesture recognizers for non-VoiceOver back gestures.
        installGestures(on: host, coordinator: context.coordinator)

        return host
    }

    func updateUIView(_ host: AccessibleCanvasHost, context: Context) {
        host.onBackGesture = onBackGesture
        host.isBackGestureEnabled = configuration.isVoiceOverBackGestureEnabled

        context.coordinator.hostingController?.rootView = CanvasContentView(
            document: document,
            configuration: configuration,
            hitDetection: hitDetection,
            policy: policy
        )
    }

    func makeCoordinator() -> CanvasCoordinator {
        CanvasCoordinator(parent: self)
    }

    // MARK: - Gesture installation

    private func installGestures(on view: UIView, coordinator: CanvasCoordinator) {
        let threeFingerSwipe = UISwipeGestureRecognizer(
            target: coordinator,
            action: #selector(CanvasCoordinator.handleThreeFingerSwipe(_:))
        )
        threeFingerSwipe.numberOfTouchesRequired = 3
        threeFingerSwipe.direction = .right
        threeFingerSwipe.delegate = coordinator
        view.addGestureRecognizer(threeFingerSwipe)

        let threeFingerPan = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(CanvasCoordinator.handleThreeFingerPan(_:))
        )
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.delegate = coordinator
        view.addGestureRecognizer(threeFingerPan)

        let doubleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(CanvasCoordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator
        view.addGestureRecognizer(doubleTap)
    }
}

// MARK: - Canvas Coordinator

/// Handles three-finger gesture recognizers for the Canvas map view.
@MainActor
class CanvasCoordinator: NSObject, UIGestureRecognizerDelegate {
    let parent: CanvasMapView
    var hostingController: UIHostingController<CanvasContentView>?

    init(parent: CanvasMapView) {
        self.parent = parent
        super.init()
    }

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let contentView = hostingController?.view else { return }
        let point = gesture.location(in: contentView)

        let config = parent.configuration
        let doc = parent.document
        let pad = config.canvasPadding
        let size = contentView.bounds.size
        let availW = size.width - pad * 2
        let availH = size.height - pad * 2
        let scale = min(availW / CGFloat(doc.bounds.width),
                        availH / CGFloat(doc.bounds.height))
        let ox = (size.width - CGFloat(doc.bounds.width) * scale) / 2
        let oy = (size.height - CGFloat(doc.bounds.height) * scale) / 2
        let t = CanvasMapTransform(scale: scale, ox: ox, oy: oy)

        let detector = CanvasHitDetector(config: parent.hitDetection)
        let anchorR = PhysicalDimensions.mmToPoints(config.anchorPointDiameterMM) / 2

        let hit = detector.findElement(
            at: point,
            elements: doc.features,
            transform: t,
            velocity: 0,
            anchorCenter: { feature, screenPt in
                let style = config.resolvedStyle(for: feature.elementType, geometry: feature.geometry)
                guard style.showAnchorDot else { return nil }
                let side = feature.properties.side ?? "right"
                let elementSize = PhysicalDimensions.mmToPoints(style.sizeMM)
                let offset = elementSize / 2 + 4 + anchorR
                let xOff: CGFloat = (side == "left") ? -offset : offset
                return CGPoint(x: screenPt.x + xOff, y: screenPt.y)
            }
        )

        if let (element, touchType) = hit {
            parent.policy.onTap(element: element, touchType: touchType)
            parent.onDoubleTap?(element)
        }
    }

    @objc func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard parent.configuration.isVoiceOverBackGestureEnabled else { return }
        parent.onBackGesture?()
    }

    @objc func handleThreeFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard parent.configuration.isVoiceOverBackGestureEnabled else { return }

        if gesture.state == .ended {
            guard let view = gesture.view else { return }
            let velocity = gesture.velocity(in: view)
            if velocity.x > 500 && abs(velocity.y) < abs(velocity.x) {
                parent.onBackGesture?()
            }
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - Canvas Content View (pure SwiftUI drawing)

/// The SwiftUI Canvas that draws all map elements and handles touch
/// interaction via DragGesture.
struct CanvasContentView: View {
    let document: TactileMapDocument
    let configuration: TactileMapViewConfiguration
    let hitDetection: HitDetectionConfig
    let policy: any FeedbackPolicy

    // MARK: - Touch state

    @State private var activeID:    String?  = nil
    @State private var touchPoint:  CGPoint? = nil
    @State private var touchAngle:  CGFloat  = -.pi / 2

    // Velocity tracking
    @State private var lastMovePoint: CGPoint? = nil
    @State private var lastMoveTime:  TimeInterval = 0
    @State private var currentVelocity: CGFloat = 0

    // MARK: - Derived sizes

    private var corridorWidthPts: CGFloat {
        PhysicalDimensions.mmToPoints(configuration.corridorLineWidthMM)
    }
    private var landmarkSidePts: CGFloat {
        PhysicalDimensions.mmToPoints(configuration.landmarkWidthMM)
    }
    private var intersectionRadiusPts: CGFloat {
        PhysicalDimensions.mmToPoints(configuration.intersectionDiameterMM) / 2
    }
    private var anchorRadiusPts: CGFloat {
        PhysicalDimensions.mmToPoints(configuration.anchorPointDiameterMM) / 2
    }

    // MARK: - Colors

    private var bgColor: Color          { Color(configuration.backgroundColor) }
    private var corridorColor: Color     { Color(configuration.corridorColor) }
    private var landmarkColor: Color     { Color(configuration.landmarkColor) }
    private var intersectionColor: Color { Color(configuration.intersectionColor) }
    private var anchorColor: Color       { Color(configuration.anchorPointColor) }
    private var landmarkBorder: Color    {
        Color(configuration.landmarkColor.withAlphaComponent(0.7))
    }

    private static let builtInTypes: Set<TactileElementType> = [.corridor, .intersection, .landmark]

    private func isCustomType(_ type: TactileElementType) -> Bool {
        !Self.builtInTypes.contains(type)
    }

    private var hitDetector: CanvasHitDetector {
        CanvasHitDetector(config: hitDetection)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let t = makeTransform(size: geo.size)
            bgColor
                .overlay(
                    Canvas { ctx, _ in
                        drawCorridors(ctx, t: t)
                        drawCustomLines(ctx, t: t)
                        drawJunctionDiscs(ctx, t: t)
                        drawCustomPolygons(ctx, t: t)
                        drawLandmarks(ctx, t: t)
                        drawIntersections(ctx, t: t)
                        drawCustomPoints(ctx, t: t)
                        drawAnchorDots(ctx, t: t)
                        if configuration.showTouchIndicator, let pt = touchPoint {
                            drawTouchIndicator(ctx, at: pt, angle: touchAngle)
                        }
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let pt = v.location
                            let now = ProcessInfo.processInfo.systemUptime

                            if let prev = lastMovePoint {
                                let dt = now - lastMoveTime
                                if dt > 0 {
                                    let dx = pt.x - prev.x
                                    let dy = pt.y - prev.y
                                    currentVelocity = CGFloat(hypot(dx, dy) / dt)
                                }
                                let dx = pt.x - prev.x
                                let dy = pt.y - prev.y
                                if dx * dx + dy * dy > 4 {
                                    touchAngle = atan2(dy, dx)
                                }
                            }
                            lastMovePoint = pt
                            lastMoveTime = now
                            touchPoint = pt

                            Task { @MainActor in touch(at: pt, t: t) }
                        }
                        .onEnded { _ in
                            touchPoint = nil
                            lastMovePoint = nil
                            currentVelocity = 0
                            Task { @MainActor in lift() }
                        }
                )
        }
    }

    // MARK: - Transform

    private func makeTransform(size: CGSize) -> CanvasMapTransform {
        let pad    = configuration.canvasPadding
        let availW = size.width  - pad * 2
        let availH = size.height - pad * 2
        let scale  = min(availW / CGFloat(document.bounds.width),
                         availH / CGFloat(document.bounds.height))
        let ox = (size.width  - CGFloat(document.bounds.width)  * scale) / 2
        let oy = (size.height - CGFloat(document.bounds.height) * scale) / 2
        return CanvasMapTransform(scale: scale, ox: ox, oy: oy)
    }

    // MARK: - Drawing: Corridors

    private func drawCorridors(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        let strokeW = corridorWidthPts
        for f in document.features where f.elementType == .corridor {
            guard case .lineString(let pts) = f.geometry, pts.count >= 2 else { continue }
            var path = Path()
            path.move(to: t.apply(pts[0]))
            for pt in pts.dropFirst() { path.addLine(to: t.apply(pt)) }
            ctx.stroke(path, with: .color(corridorColor),
                       style: StrokeStyle(lineWidth: strokeW,
                                          lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Drawing: Junction Discs

    private func drawJunctionDiscs(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        guard configuration.junctionDiscEnabled else { return }
        let discR = corridorWidthPts / 2
        for f in document.features where f.elementType == .intersection {
            guard (f.properties.connectedCorridors?.count ?? 0) >= 2,
                  case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            let rect = CGRect(x: center.x - discR, y: center.y - discR,
                              width: discR * 2, height: discR * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(corridorColor))
        }
    }

    // MARK: - Drawing: Landmarks

    private func drawLandmarks(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        let sideLen = landmarkSidePts
        let corner:  CGFloat = 4
        let borderW: CGFloat = max(1, 2)
        for f in document.features where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            let half = sideLen / 2
            let rect = CGRect(x: center.x - half, y: center.y - half,
                              width: sideLen, height: sideLen)
            let shape = Path(roundedRect: rect, cornerRadius: corner)
            ctx.fill(shape, with: .color(landmarkColor))
            ctx.stroke(shape, with: .color(landmarkBorder), lineWidth: borderW)
        }
    }

    // MARK: - Drawing: Intersections

    private func drawIntersections(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        let r = intersectionRadiusPts
        let borderW = max(1, r * 0.15)
        for f in document.features where f.elementType == .intersection {
            guard case .point(let c) = f.geometry else { continue }
            let center = t.apply(c)
            let rect = circleRect(center: center, radius: r)
            ctx.fill(Path(ellipseIn: rect), with: .color(intersectionColor))
            ctx.stroke(Path(ellipseIn: rect),
                       with: .color(Color(white: 0.25)), lineWidth: borderW)
        }
    }

    // MARK: - Drawing: Custom LineString Elements

    private func drawCustomLines(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        for f in document.features where isCustomType(f.elementType) {
            guard case .lineString(let pts) = f.geometry, pts.count >= 2 else { continue }
            let style = configuration.resolvedStyle(for: f.elementType, geometry: f.geometry)
            let strokeW = PhysicalDimensions.mmToPoints(style.sizeMM)
            var path = Path()
            path.move(to: t.apply(pts[0]))
            for pt in pts.dropFirst() { path.addLine(to: t.apply(pt)) }
            ctx.stroke(path, with: .color(Color(style.color)),
                       style: StrokeStyle(lineWidth: strokeW,
                                          lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Drawing: Custom Polygon Elements

    private func drawCustomPolygons(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        for f in document.features where isCustomType(f.elementType) {
            guard case .polygon(let pts) = f.geometry, pts.count >= 3 else { continue }
            let style = configuration.resolvedStyle(for: f.elementType, geometry: f.geometry)
            let color = Color(style.color)
            var path = Path()
            path.move(to: t.apply(pts[0]))
            for pt in pts.dropFirst() { path.addLine(to: t.apply(pt)) }
            path.closeSubpath()
            ctx.fill(path, with: .color(color.opacity(0.5)))
            ctx.stroke(path, with: .color(color),
                       lineWidth: PhysicalDimensions.mmToPoints(style.sizeMM))
        }
    }

    // MARK: - Drawing: Custom Point Elements

    private func drawCustomPoints(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        for f in document.features where isCustomType(f.elementType) {
            guard case .point(let c) = f.geometry else { continue }
            let style = configuration.resolvedStyle(for: f.elementType, geometry: f.geometry)
            let color = Color(style.color)
            let center = t.apply(c)

            switch style.pointShape {
            case .circle:
                let r = PhysicalDimensions.mmToPoints(style.sizeMM) / 2
                let rect = circleRect(center: center, radius: r)
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(Color(white: 0.25)),
                           lineWidth: max(1, r * 0.15))
            case .roundedRect(let cornerRadius):
                let w = PhysicalDimensions.mmToPoints(style.sizeMM)
                let h = PhysicalDimensions.mmToPoints(style.heightMM ?? style.sizeMM)
                let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2,
                                  width: w, height: h)
                let shape = Path(roundedRect: rect, cornerRadius: cornerRadius)
                ctx.fill(shape, with: .color(color))
                ctx.stroke(shape, with: .color(color.opacity(0.7)), lineWidth: 2)
            }
        }
    }

    // MARK: - Drawing: Anchor Dots

    private func drawAnchorDots(_ ctx: GraphicsContext, t: CanvasMapTransform) {
        let r = anchorRadiusPts
        for f in document.features {
            guard case .point(let c) = f.geometry else { continue }
            guard let anchor = anchorCenter(for: f, screenPt: t.apply(c)) else { continue }
            let rect = circleRect(center: anchor, radius: r)
            ctx.fill(Path(ellipseIn: rect), with: .color(anchorColor))
        }
    }

    // MARK: - Drawing: Touch Indicator

    private func drawTouchIndicator(_ ctx: GraphicsContext, at pt: CGPoint, angle: CGFloat) {
        let ringR:     CGFloat = 20
        let centerR:   CGFloat = 5
        let tipDist:   CGFloat = 36
        let baseDist:  CGFloat = 22
        let halfWidth: CGFloat = 7

        let ringRect = circleRect(center: pt, radius: ringR)
        ctx.fill(Path(ellipseIn: ringRect),
                 with: .color(Color(red: 1.0, green: 0.88, blue: 0.0).opacity(0.28)))
        ctx.stroke(Path(ellipseIn: ringRect),
                   with: .color(.white.opacity(0.88)), lineWidth: 2.5)

        ctx.fill(Path(ellipseIn: circleRect(center: pt, radius: centerR)),
                 with: .color(.white))

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

    func anchorCenter(for feature: MapElement, screenPt: CGPoint) -> CGPoint? {
        let style = configuration.resolvedStyle(for: feature.elementType, geometry: feature.geometry)
        guard style.showAnchorDot else { return nil }
        let side = feature.properties.side ?? "right"
        let elementSize = PhysicalDimensions.mmToPoints(style.sizeMM)
        let offset = elementSize / 2 + 4 + anchorRadiusPts
        let xOff: CGFloat = (side == "left") ? -offset : offset
        return CGPoint(x: screenPt.x + xOff, y: screenPt.y)
    }

    // MARK: - Touch Handling

    @MainActor
    private func touch(at point: CGPoint, t: CanvasMapTransform) {
        let hit = hitDetector.findElement(
            at: point,
            elements: document.features,
            transform: t,
            velocity: currentVelocity,
            anchorCenter: { feature, screenPt in
                self.anchorCenter(for: feature, screenPt: screenPt)
            }
        )

        guard let (element, touchType) = hit else {
            if let cur = activeElement() { policy.onExit(element: cur) }
            activeID = nil
            return
        }

        if element.id == activeID {
            if let cur = activeElement() {
                policy.onContinue(element: cur, touchType: touchType)
            }
        } else {
            if let cur = activeElement() { policy.onExit(element: cur) }
            policy.onEnter(element: element, touchType: touchType)
            activeID = element.id
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
