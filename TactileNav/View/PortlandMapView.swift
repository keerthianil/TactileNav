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

// MARK: - Accessible map view (VoiceOver back gestures + direct touch)

final class PortlandAccessibleMapView: MKMapView {
    var onBackGesture: (() -> Void)?

    func applyAccessibility() {
        if UIAccessibility.isVoiceOverRunning {
            isAccessibilityElement = true
            accessibilityTraits = [.allowsDirectInteraction]
            accessibilityLabel = "Tactile map"
            accessibilityHint = "Drag to explore. Double tap an intersection for detail. Three finger swipe right, or two finger scrub, to go back."
            if #available(iOS 17.0, *) { accessibilityDirectTouchOptions = .silentOnTouch }
        } else {
            isAccessibilityElement = false
            accessibilityTraits = []
        }
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
        mapView.applyAccessibility()

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
        mapView.applyAccessibility()
        mapView.onBackGesture = { [weak c] in c?.triggerBack() }

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
                    let pl = cw.polyline
                    pl.portlandFeatureType = .crosswalk; pl.portlandLevel = cw.level
                    mapView.addOverlay(pl, level: .aboveLabels)
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
        for f in features {
            switch f {
            case let x as PortlandCorridor: x.getCoordinates().forEach(add)
            case let x as PortlandSidewalk: x.getCoordinates().forEach(add)
            case let x as PortlandCrosswalk: x.getCoordinates().forEach(add)
            case let x as PortlandIntersection: add(x.coordinate)
            case let x as PortlandLandmark: add(x.coordinate)
            default: break
            }
        }
        guard !r.isNull else { return }
        let pad = UIEdgeInsets(top: 48, left: 40, bottom: 96, right: 40)
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
        private var lastPoint: CGPoint?
        private var lastMoveTime: CFTimeInterval = 0
        private var backTriggered = false

        init(parent: PortlandMapView) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

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
            switch pl.portlandFeatureType {
            case .corridor:
                r.strokeColor = trafficColor(forCorridorId: pl.portlandFeatureId)
                r.lineWidth = PortlandPhysicalDimensions.mmToPoints(pl.portlandLevel == 2 ? 12 : 4)
            case .sidewalk:
                r.strokeColor = UIColor(red: 0x9E/255, green: 0x9E/255, blue: 0x9E/255, alpha: 1)
                r.lineWidth = PortlandPhysicalDimensions.mmToPoints(4)
            case .crosswalk:
                r.strokeColor = .white
                r.lineWidth = PortlandPhysicalDimensions.mmToPoints(2.8)
                r.lineDashPattern = [NSNumber(value: Float(PortlandPhysicalDimensions.mmToPoints(1.5))),
                                     NSNumber(value: Float(PortlandPhysicalDimensions.mmToPoints(1.0)))]
            default:
                r.strokeColor = .gray; r.lineWidth = 2
            }
            r.lineCap = .round; r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let x = annotation as? PortlandIntersection {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: PortlandIntersectionAnnotationView.reuseIdentifier)
                         as? PortlandIntersectionAnnotationView)
                        ?? PortlandIntersectionAnnotationView(annotation: x, reuseIdentifier: PortlandIntersectionAnnotationView.reuseIdentifier)
                v.annotation = x
                v.showSignal(x.signalized)
                return v
            }
            if let lm = annotation as? PortlandLandmark {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: PortlandLandmarkAnnotationView.reuseIdentifier)
                         as? PortlandLandmarkAnnotationView)
                        ?? PortlandLandmarkAnnotationView(annotation: lm, reuseIdentifier: PortlandLandmarkAnnotationView.reuseIdentifier)
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
                lastPoint = p; lastMoveTime = CACurrentMediaTime()
                exploreStart(at: p, in: mv, velocity: 0)
                touchIndicator?.show(at: p)
            case .changed:
                let now = CACurrentMediaTime()
                let v = velocity(to: p, now: now)
                lastPoint = p; lastMoveTime = now
                exploreUpdate(at: p, in: mv, velocity: v)
                touchIndicator?.show(at: p)
            case .ended, .cancelled, .failed:
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
