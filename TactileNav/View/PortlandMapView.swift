//
//  PortlandMapView.swift
//  TactileNav
//
//  The tactile Congress Square map. A blank (white-tiled) MKMapView renders the real
//  OSM geometry; the user explores by dragging a finger. The interaction model is the
//  proven drag-to-explore approach: UIKit gesture recognizers stay active in BOTH modes
//  and, when VoiceOver is on, `.allowsDirectInteraction` passes raw touches straight to
//  them (so there is no separate/fragile manual touch path to race with VoiceOver).
//
//  Gesture contract (identical with VoiceOver on or off):
//    • long-press + drag  → explore (haptics + rumble + spoken feature)
//    • single tap         → speak the feature under the finger
//    • double tap         → drill into an intersection (Level 1) / go back (Level 2)
//    • 3-finger swipe/pan, VoiceOver 3-finger scroll, VoiceOver Z-scrub → go back
//

import SwiftUI
import MapKit
import TactileMapCore
import TactileMapLogging

// MARK: - UIKit helpers

extension UIView {
    /// Walk the responder chain to the enclosing navigation controller (used to disable
    /// the interactive edge-swipe pop so one-finger dragging can't accidentally go back).
    var enclosingNavigationController: UINavigationController? {
        var r: UIResponder? = self.next
        while let cur = r {
            if let nc = cur as? UINavigationController { return nc }
            if let vc = cur as? UIViewController, let nc = vc.navigationController { return nc }
            r = cur.next
        }
        return nil
    }
}

// MARK: - Map sizing (scale to this map, not fixed pixels)
//
// Feature sizes are a fraction of the smaller on-screen viewport dimension, so they stay
// proportional to whatever the map is showing, then clamped to a tactile minimum (a red
// square must stay ~finger-tip sized) and a maximum (so it can't dominate). Line widths
// derive from that: roads < intersection, sidewalks < roads, crosswalk stripes thinnest.
enum PortlandMapSizing {
    static func ref(_ mv: MKMapView) -> CGFloat {
        let s = min(mv.bounds.width, mv.bounds.height)
        return s > 0 ? s : UIScreen.main.bounds.width
    }
    static func intersectionSide(_ mv: MKMapView) -> CGFloat { min(max(ref(mv) * 0.055, 20), 40) }
    static func landmarkSize(_ mv: MKMapView) -> (CGFloat, CGFloat) {
        let s = intersectionSide(mv); return (s * 1.5, s)
    }
    static func roadWidth(_ mv: MKMapView, level: Int) -> CGFloat {
        level == 2 ? min(max(ref(mv) * 0.05, 16), 34) : min(max(ref(mv) * 0.016, 7), 14)
    }
    static func sidewalkWidth(_ mv: MKMapView, level: Int) -> CGFloat { roadWidth(mv, level: level) * 0.5 }
    static func crosswalkStripeWidth(_ mv: MKMapView, level: Int) -> CGFloat {
        // Thin bars so the ~1.4 m-pitch stripes read as discrete zebra marks, not a band.
        max(2.5, roadWidth(mv, level: level) * 0.11)
    }
}

// MARK: - Accessible map view (VoiceOver back gestures + direct touch + context actions)

final class PortlandAccessibleMapView: MKMapView {
    var onBackGesture: (() -> Void)?
    /// Context actions surfaced via the VoiceOver Actions rotor (swipe up/down on the map).
    var trafficActions: [(String, () -> Void)] = []
    /// Two-finger double-tap (magic tap) shortcut to cycle the traffic time of day.
    var onMagicTap: (() -> Void)?

    func applyAccessibility(level: Int) {
        if UIAccessibility.isVoiceOverRunning {
            isAccessibilityElement = true
            accessibilityTraits = [.allowsDirectInteraction]
            accessibilityLabel = "Tactile map"
            var hint = "Drag to explore. Double tap an intersection for detail. "
            if level == 1 {
                hint += "Swipe up or down to change the traffic time of day, or two finger double tap to cycle it. "
            }
            hint += "Three finger swipe right, or two finger scrub, to go back."
            accessibilityHint = hint
            if #available(iOS 17.0, *) { accessibilityDirectTouchOptions = .silentOnTouch }
        } else {
            isAccessibilityElement = false
            accessibilityTraits = []
        }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            trafficActions.map { label, handler in
                UIAccessibilityCustomAction(name: label) { _ in handler(); return true }
            }
        }
        set {}
    }

    override func accessibilityPerformMagicTap() -> Bool {
        guard let onMagicTap else { return false }
        onMagicTap()
        return true
    }

    // VoiceOver 3-finger swipe right → back.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if direction == .right {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
            UIAccessibility.post(notification: .announcement, argument: "Going back")
            onBackGesture?()
            return true
        }
        return super.accessibilityScroll(direction)
    }

    // VoiceOver 2-finger Z-scrub escape → back.
    override func accessibilityPerformEscape() -> Bool {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
        onBackGesture?()
        return true
    }
}

// MARK: - Touch indicator (yellow follow dot)

final class PortlandTouchIndicatorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer: CGFloat = 16, inner: CGFloat = 5
        ctx.setFillColor(UIColor(red: 1, green: 0.88, blue: 0, alpha: 0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer*2, height: outer*2))
        ctx.setStrokeColor(UIColor.white.cgColor); ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer*2, height: outer*2))
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner*2, height: inner*2))
    }

    func show(at p: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        center = p; isHidden = false
        CATransaction.commit()
    }
    func hide() { isHidden = true }
}

// MARK: - Blank white base tiles

final class PortlandBlankTileOverlay: MKTileOverlay {
    override init(urlTemplate: String?) { super.init(urlTemplate: nil); canReplaceMapContent = true }
}
final class PortlandWhiteTileRenderer: MKTileOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect(for: mapRect))
    }
}

// MARK: - Overlay tagging (feature type / id on the polyline)

private var kTypeKey: UInt8 = 0, kIdKey: UInt8 = 0, kLevelKey: UInt8 = 0
extension MKPolyline {
    var portlandFeatureType: PortlandFeatureType? {
        get { objc_getAssociatedObject(self, &kTypeKey) as? PortlandFeatureType }
        set { objc_setAssociatedObject(self, &kTypeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var portlandFeatureId: String? {
        get { objc_getAssociatedObject(self, &kIdKey) as? String }
        set { objc_setAssociatedObject(self, &kIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var portlandLevel: Int {
        get { (objc_getAssociatedObject(self, &kLevelKey) as? Int) ?? 1 }
        set { objc_setAssociatedObject(self, &kLevelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - PortlandMapView

struct PortlandMapView: UIViewRepresentable {

    let features: [PortlandMapFeature]
    var onDoubleTapIntersection: ((PortlandIntersection) -> Void)?
    var onBackGesture: (() -> Void)?
    var trafficSegments: [PortlandTrafficSegment] = []
    var trafficIntersections: [PortlandTrafficIntersection] = []
    var apsLocations: [PortlandAPS] = []
    var trafficState: TrafficState = .normal
    var onTrafficStateChange: ((TrafficState) -> Void)?
    var level: Int = 1

    func makeUIView(context: Context) -> PortlandAccessibleMapView {
        let mapView = PortlandAccessibleMapView(frame: .zero)
        mapView.mapType = .mutedStandard
        mapView.backgroundColor = .white
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsBuildings = false
        mapView.showsTraffic = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.delegate = context.coordinator
        mapView.applyAccessibility(level: level)

        mapView.addOverlay(PortlandBlankTileOverlay(urlTemplate: nil), level: .aboveLabels)

        let indicator = PortlandTouchIndicatorView()
        mapView.addSubview(indicator)
        context.coordinator.touchIndicator = indicator

        // --- Gesture recognizers: active in BOTH VoiceOver and non-VoiceOver modes.
        let c = context.coordinator

        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = c
        doubleTap.cancelsTouchesInView = true
        doubleTap.delaysTouchesBegan = false
        doubleTap.delaysTouchesEnded = false
        mapView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.delegate = c
        singleTap.cancelsTouchesInView = false
        singleTap.require(toFail: doubleTap)
        mapView.addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.1     // not 0 — a quick tap must not trigger drag
        longPress.allowableMovement = 10_000     // never cancels while dragging
        longPress.numberOfTouchesRequired = 1    // don't swallow the 3-finger back gesture
        longPress.delegate = c
        longPress.cancelsTouchesInView = false
        longPress.require(toFail: doubleTap)
        mapView.addGestureRecognizer(longPress)

        let swipe = UISwipeGestureRecognizer(target: c, action: #selector(Coordinator.handleBackGesture))
        swipe.numberOfTouchesRequired = 3
        swipe.direction = .right
        swipe.delegate = c
        mapView.addGestureRecognizer(swipe)

        // Pan backup — 3-finger swipe recognizers are finicky; a slow drag is more reliable.
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleThreeFingerPan(_:)))
        pan.minimumNumberOfTouches = 3
        pan.maximumNumberOfTouches = 3
        pan.delegate = c
        mapView.addGestureRecognizer(pan)

        mapView.onBackGesture = { [weak c] in c?.triggerBack() }

        NotificationCenter.default.addObserver(
            c, selector: #selector(Coordinator.voiceOverChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)

        return mapView
    }

    func updateUIView(_ mapView: PortlandAccessibleMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        mapView.applyAccessibility(level: level)
        mapView.onBackGesture = { [weak c] in c?.triggerBack() }

        // Traffic time-of-day as VoiceOver context actions (Actions rotor) + magic-tap cycle.
        if level == 1, let cb = onTrafficStateChange {
            mapView.trafficActions = TrafficState.allCases.map { st in
                ("Traffic time: \(st.label)", {
                    cb(st)
                    PortlandFeedbackManager.shared.speak("Traffic set to \(st.label). \(st.description)")
                })
            }
            let states = TrafficState.allCases
            let next = states[((states.firstIndex(of: trafficState) ?? 0) + 1) % states.count]
            mapView.onMagicTap = {
                cb(next)
                PortlandFeedbackManager.shared.speak("Traffic set to \(next.label). \(next.description)")
            }
        } else {
            mapView.trafficActions = []
            mapView.onMagicTap = nil
        }

        // Disable the one-finger interactive edge-swipe pop so dragging to explore near the
        // left edge can't accidentally navigate back (Level 1 is a pushed screen).
        if level == 1, let nav = mapView.enclosingNavigationController {
            nav.interactivePopGestureRecognizer?.isEnabled = false
            c.disabledPopNav = nav
        }
        c.startLogIfNeeded()

        let featuresChanged = c.renderedFeatureKey != Self.featureKey(features)
        let timeChanged = c.renderedState != trafficState

        if featuresChanged {
            let old = mapView.overlays.filter { !($0 is PortlandBlankTileOverlay) }
            mapView.removeOverlays(old)
            mapView.removeAnnotations(mapView.annotations)

            for f in features {
                switch f {
                case let road as PortlandCorridor:
                    let pl = road.polyline
                    pl.portlandFeatureType = .corridor; pl.portlandFeatureId = road.featureId; pl.portlandLevel = road.level
                    mapView.addOverlay(pl, level: .aboveLabels)
                case let sw as PortlandSidewalk:
                    let pl = sw.polyline
                    pl.portlandFeatureType = .sidewalk; pl.portlandLevel = sw.level
                    mapView.addOverlay(pl, level: .aboveLabels)
                case let cw as PortlandCrosswalk:
                    // Render discrete zebra stripes; the centerline stays in `features`
                    // only for hit-testing / announcement (never drawn).
                    for stripe in cw.stripePolylines() {
                        stripe.portlandFeatureType = .crosswalk; stripe.portlandLevel = cw.level
                        mapView.addOverlay(stripe, level: .aboveLabels)
                    }
                case let x as PortlandIntersection:
                    mapView.addAnnotation(x)
                case let lm as PortlandLandmark:
                    mapView.addAnnotation(lm)
                default: break
                }
            }
            c.renderedFeatureKey = Self.featureKey(features)
            c.renderedState = trafficState
            setFixedViewport(mapView)
        } else if timeChanged {
            c.renderedState = trafficState
            c.refreshTrafficColors(on: mapView)
        }
    }

    static func dismantleUIView(_ mapView: PortlandAccessibleMapView, coordinator: Coordinator) {
        coordinator.feedback.stopAllFeedback()
        coordinator.endLog()
        coordinator.disabledPopNav?.interactivePopGestureRecognizer?.isEnabled = true
    }

    private static func featureKey(_ features: [PortlandMapFeature]) -> String {
        "\(features.count)-\(features.first?.featureId ?? "")-\(features.first?.level ?? 0)"
    }

    private func setFixedViewport(_ mapView: MKMapView) {
        guard !features.isEmpty else { return }
        var r = MKMapRect.null
        func add(_ coord: CLLocationCoordinate2D) {
            let p = MKMapPoint(coord)
            r = r.union(MKMapRect(x: p.x, y: p.y, width: 0.01, height: 0.01))
        }
        if level == 1 {
            // Frame the 5-crossing cluster (+ landmarks) so it fills the screen and the
            // fixed-minimum markers don't overlap; the Congress St spine runs off-screen.
            for f in features {
                if let x = f as? PortlandIntersection { add(x.coordinate) }
                if let x = f as? PortlandLandmark { add(x.coordinate) }
            }
        } else {
            for f in features {
                switch f {
                case let x as PortlandCorridor: x.getCoordinates().forEach(add)
                case let x as PortlandSidewalk: x.getCoordinates().forEach(add)
                case let x as PortlandCrosswalk: x.getCoordinates().forEach(add)
                case let x as PortlandIntersection: add(x.coordinate)
                default: break
                }
            }
        }
        guard !r.isNull else { return }
        // Generous padding at L1 gives the cluster breathing room around the edges.
        let pad: UIEdgeInsets = level == 1
            ? UIEdgeInsets(top: 90, left: 80, bottom: 120, right: 80)
            : UIEdgeInsets(top: 48, left: 40, bottom: 96, right: 40)
        mapView.setVisibleMapRect(r, edgePadding: pad, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        var parent: PortlandMapView
        let feedback = PortlandFeedbackManager.shared
        var touchIndicator: PortlandTouchIndicatorView?

        var renderedFeatureKey = ""
        var renderedState: TrafficState?

        private var currentFeatureId: String?
        private var currentFeature: PortlandMapFeature?
        private var lastPoint: CGPoint?
        private var lastMoveTime: CFTimeInterval = 0
        private var backTriggered = false

        // CSV touch logging (same logger type the Roux map + Data Files screen use).
        let logger = CSVTouchLogger(fileNameGenerator: { meta in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd_HHmmss"
            return "CongressSquare_L\(meta["level"] ?? "1")_\(df.string(from: Date()))"
        })
        private var sessionStarted = false
        private var sessionStart = Date()
        weak var disabledPopNav: UINavigationController?

        init(parent: PortlandMapView) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        func startLogIfNeeded() {
            guard !sessionStarted else { return }
            sessionStarted = true
            sessionStart = Date()
            logger.startSession(metadata: ["map": "CongressSquare", "level": "\(parent.level)"])
        }

        func endLog() {
            guard sessionStarted else { return }
            sessionStarted = false
            logger.endSession()
        }

        private func log(_ type: TouchEventType, at p: CGPoint, feature: PortlandMapFeature?) {
            guard sessionStarted else { return }
            logger.logEvent(TouchEvent(
                timestamp: Date(),
                sessionElapsed: Date().timeIntervalSince(sessionStart),
                eventType: type,
                elementName: feature?.featureName ?? "Background",
                elementType: feature.map { Self.tactileType($0.featureType) },
                touchPoint: p))
        }

        private static func tactileType(_ t: PortlandFeatureType) -> TactileElementType {
            switch t {
            case .corridor: return .corridor
            case .intersection: return .intersection
            case .landmark: return .landmark
            case .sidewalk: return TactileElementType(rawValue: "sidewalk")
            case .crosswalk: return TactileElementType(rawValue: "crosswalk")
            }
        }

        @objc func voiceOverChanged() { /* accessibility re-applied in updateUIView */ }

        // Allow the exploration recognizers to coexist; never block the back gestures.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: Rendering

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is PortlandBlankTileOverlay {
                return PortlandWhiteTileRenderer(tileOverlay: overlay as! MKTileOverlay)
            }
            guard let pl = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: pl)
            let level = pl.portlandLevel
            switch pl.portlandFeatureType {
            case .corridor:
                r.strokeColor = trafficColor(forCorridorId: pl.portlandFeatureId)
                r.lineWidth = PortlandMapSizing.roadWidth(mapView, level: level)
                r.lineCap = .round; r.lineJoin = .round
            case .sidewalk:
                r.strokeColor = UIColor(red: 0x9E/255, green: 0x9E/255, blue: 0x9E/255, alpha: 1)
                r.lineWidth = PortlandMapSizing.sidewalkWidth(mapView, level: level)
                r.lineCap = .round; r.lineJoin = .round
            case .crosswalk:
                // Each overlay is one zebra bar → solid, butt caps (clean rectangle).
                r.strokeColor = .white
                r.lineWidth = PortlandMapSizing.crosswalkStripeWidth(mapView, level: level)
                r.lineCap = .butt; r.lineJoin = .miter
            default:
                r.strokeColor = .gray; r.lineWidth = 2
                r.lineCap = .round; r.lineJoin = .round
            }
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let x = annotation as? PortlandIntersection {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: PortlandIntersectionAnnotationView.reuseIdentifier)
                         as? PortlandIntersectionAnnotationView)
                        ?? PortlandIntersectionAnnotationView(annotation: x, reuseIdentifier: PortlandIntersectionAnnotationView.reuseIdentifier)
                v.configure(side: PortlandMapSizing.intersectionSide(mapView))
                v.annotation = x
                v.showSignal(x.signalized)
                return v
            }
            if let lm = annotation as? PortlandLandmark {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: PortlandLandmarkAnnotationView.reuseIdentifier)
                         as? PortlandLandmarkAnnotationView)
                        ?? PortlandLandmarkAnnotationView(annotation: lm, reuseIdentifier: PortlandLandmarkAnnotationView.reuseIdentifier)
                let sz = PortlandMapSizing.landmarkSize(mapView)
                v.configure(width: sz.0, height: sz.1)
                v.annotation = lm
                return v
            }
            return nil
        }

        // MARK: Traffic colour (secondary, for low-vision users)

        private func segment(forCorridorId id: String?) -> PortlandTrafficSegment? {
            guard let id else { return nil }
            return parent.trafficSegments.first { $0.corridorIds.contains(id) || $0.id == id }
        }

        private func trafficColor(forCorridorId id: String?) -> UIColor {
            guard let seg = segment(forCorridorId: id) else {
                return UIColor(red: 0x02/255, green: 0x3E/255, blue: 0x8A/255, alpha: 1)
            }
            return seg.level(for: parent.trafficState).color
        }

        func refreshTrafficColors(on mapView: MKMapView) {
            for o in mapView.overlays {
                guard let pl = o as? MKPolyline, pl.portlandFeatureType == .corridor,
                      let r = mapView.renderer(for: o) as? MKPolylineRenderer else { continue }
                r.strokeColor = trafficColor(forCorridorId: pl.portlandFeatureId)
                r.setNeedsDisplay()
            }
        }

        // MARK: Gestures

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let mv = g.view as? MKMapView else { return }
            if parent.level == 2 { triggerBack(); return }
            if let x = hitIntersection(at: g.location(in: mv), in: mv, radiusPts: 34) {
                feedback.stopAllFeedback()
                feedback.playSingleTap()
                parent.onDoubleTapIntersection?(x)
            }
        }

        @objc func handleSingleTap(_ g: UITapGestureRecognizer) {
            guard let mv = g.view as? MKMapView else { return }
            if let f = hitFeature(at: g.location(in: mv), in: mv, velocity: 0) {
                feedback.playSingleTap()
                announce(f)
            }
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard let mv = g.view as? MKMapView else { return }
            let p = g.location(in: mv)
            switch g.state {
            case .began:
                startLogIfNeeded()
                lastPoint = p; lastMoveTime = CACurrentMediaTime()
                exploreStart(at: p, in: mv, velocity: 0)
                log(.touchDown, at: p, feature: currentFeature)
                touchIndicator?.show(at: p)
            case .changed:
                let now = CACurrentMediaTime()
                let v = velocity(to: p, now: now)
                lastPoint = p; lastMoveTime = now
                exploreUpdate(at: p, in: mv, velocity: v)
                log(.touchMove, at: p, feature: currentFeature)   // logger throttles moves
                touchIndicator?.show(at: p)
            case .ended, .cancelled, .failed:
                log(.touchUp, at: p, feature: currentFeature)
                exploreStop()
                touchIndicator?.hide()
                lastPoint = nil
            default: break
            }
        }

        @objc func handleBackGesture() { triggerBack() }

        @objc func handleThreeFingerPan(_ g: UIPanGestureRecognizer) {
            guard let mv = g.view else { return }
            if g.state == .changed, g.translation(in: mv).x > 100 { triggerBack() }
            if g.state == .ended || g.state == .cancelled { backTriggered = false }
        }

        func triggerBack() {
            guard !backTriggered else { return }
            backTriggered = true
            feedback.stopAllFeedback()
            feedback.playSingleTap()
            parent.onBackGesture?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.backTriggered = false }
        }

        private func velocity(to p: CGPoint, now: CFTimeInterval) -> CGFloat {
            guard let lp = lastPoint else { return 0 }
            let dt = max(0.001, now - lastMoveTime)
            return hypot(p.x - lp.x, p.y - lp.y) / CGFloat(dt)
        }

        // MARK: Exploration

        private func exploreStart(at p: CGPoint, in mv: MKMapView, velocity v: CGFloat) {
            currentFeatureId = nil
            exploreUpdate(at: p, in: mv, velocity: v)
        }

        private func exploreUpdate(at p: CGPoint, in mv: MKMapView, velocity v: CGFloat) {
            let f = hitFeature(at: p, in: mv, velocity: v)
            currentFeature = f
            if f?.featureId != currentFeatureId {
                currentFeatureId = f?.featureId
                feedback.stopAllFeedback()
                if let f {
                    feedback.startFeedback(for: f, trafficLevel: trafficLevel(for: f))
                    announce(f)
                }
            }
        }

        private func exploreStop() {
            feedback.stopAllFeedback()
            currentFeatureId = nil
            currentFeature = nil
        }

        private func trafficLevel(for f: PortlandMapFeature) -> TrafficLevel? {
            guard let road = f as? PortlandCorridor,
                  let seg = segment(forCorridorId: road.featureId) else { return nil }
            return seg.level(for: parent.trafficState)
        }

        // MARK: Hit testing (point-space, velocity-adaptive)

        private func point(_ coord: CLLocationCoordinate2D, in mv: MKMapView) -> CGPoint {
            mv.convert(coord, toPointTo: mv)
        }

        private func hitFeature(at p: CGPoint, in mv: MKMapView, velocity v: CGFloat) -> PortlandMapFeature? {
            let lineBonus = min(v / 40, 22)   // grow line radius when tracing fast
            for f in parent.features {
                if let lm = f as? PortlandLandmark,
                   hypot2(point(lm.coordinate, in: mv), p) < 30 { return lm }
            }
            for f in parent.features {
                if let x = f as? PortlandIntersection,
                   hypot2(point(x.coordinate, in: mv), p) < 26 { return x }
            }
            for f in parent.features {
                if let cw = f as? PortlandCrosswalk,
                   distToPolyline(p, cw.getCoordinates(), in: mv) < 20 + lineBonus { return cw }
            }
            for f in parent.features {
                if let sw = f as? PortlandSidewalk,
                   distToPolyline(p, sw.getCoordinates(), in: mv) < 20 + lineBonus { return sw }
            }
            for f in parent.features {
                if let road = f as? PortlandCorridor,
                   distToPolyline(p, road.getCoordinates(), in: mv) < 22 + lineBonus { return road }
            }
            return nil
        }

        private func hitIntersection(at p: CGPoint, in mv: MKMapView, radiusPts: CGFloat) -> PortlandIntersection? {
            var best: (PortlandIntersection, CGFloat)?
            for f in parent.features {
                if let x = f as? PortlandIntersection {
                    let d = hypot2(point(x.coordinate, in: mv), p)
                    if d < radiusPts, best == nil || d < best!.1 { best = (x, d) }
                }
            }
            return best?.0
        }

        private func hypot2(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        private func distToPolyline(_ p: CGPoint, _ coords: [CLLocationCoordinate2D], in mv: MKMapView) -> CGFloat {
            guard coords.count >= 2 else { return .greatestFiniteMagnitude }
            var minD = CGFloat.greatestFiniteMagnitude
            var prev = point(coords[0], in: mv)
            for i in 1..<coords.count {
                let cur = point(coords[i], in: mv)
                minD = min(minD, distToSegment(p, prev, cur))
                prev = cur
            }
            return minD
        }

        private func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx*dx + dy*dy
            guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            var t = ((p.x - a.x)*dx + (p.y - a.y)*dy) / len2
            t = max(0, min(1, t))
            return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
        }

        // MARK: Announcements

        private func announce(_ f: PortlandMapFeature) {
            var text = f.announcement()

            if let x = f as? PortlandIntersection {
                let hasAPS = parent.apsLocations.contains { $0.intersectionId == x.featureId }
                if x.signalized { text = "Signalized. " + text }
                if hasAPS { text += ", accessible pedestrian signal" }
                if parent.level == 1 { text += ". Double tap for crossing detail" }
            }
            if let road = f as? PortlandCorridor {
                if let seg = segment(forCorridorId: road.featureId) {
                    text += ". \(seg.lanes) lanes, \(seg.level(for: parent.trafficState).spoken) traffic"
                } else {
                    text += ". \(road.lanes) lanes"
                }
            }
            if let lm = f as? PortlandLandmark, !lm.tag.isEmpty {
                text = "\(lm.tag), \(lm.featureName)"
            }
            feedback.speak(text)
        }
    }
}
