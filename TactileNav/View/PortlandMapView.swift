import SwiftUI
import MapKit
import CoreHaptics
import TactileMapCore

// MARK: - Touch Delegate Protocol

protocol PortlandMapTouchDelegate: AnyObject {
    func touchBegan(at point: CGPoint, in view: UIView)
    func touchMoved(to point: CGPoint, in view: UIView)
    func touchEnded(at point: CGPoint, in view: UIView)
}

// MARK: - Accessible Map View

final class PortlandAccessibleMapView: MKMapView {

    weak var touchDelegate: PortlandMapTouchDelegate?
    var onEscapeGesture: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupAccessibility()
    }

    private func setupAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityLabel = "Tactile map"
        accessibilityHint = "Drag to explore streets and intersections. Double tap an intersection for detail. Two finger scrub to go back."

        if #available(iOS 17.0, *) {
            accessibilityDirectTouchOptions = .silentOnTouch
        }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { nil }
        set { }
    }

    override func accessibilityPerformEscape() -> Bool {
        touchDelegate?.touchEnded(at: .zero, in: self)
        if let handler = onEscapeGesture {
            handler()
            return true
        }
        return false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if UIAccessibility.isVoiceOverRunning {
            if let touch = touches.first {
                touchDelegate?.touchBegan(at: touch.location(in: self), in: self)
            }
        } else {
            super.touchesBegan(touches, with: event)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if UIAccessibility.isVoiceOverRunning {
            if let touch = touches.first {
                touchDelegate?.touchMoved(to: touch.location(in: self), in: self)
            }
        } else {
            super.touchesMoved(touches, with: event)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if UIAccessibility.isVoiceOverRunning {
            if let touch = touches.first {
                touchDelegate?.touchEnded(at: touch.location(in: self), in: self)
            }
        } else {
            super.touchesEnded(touches, with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if UIAccessibility.isVoiceOverRunning {
            touchDelegate?.touchEnded(at: .zero, in: self)
        } else {
            super.touchesCancelled(touches, with: event)
        }
    }
}

// MARK: - Touch Indicator View

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
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerR: CGFloat = 16
        let innerR: CGFloat = 5

        ctx.setFillColor(UIColor(red: 1, green: 0.88, blue: 0, alpha: 0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))

        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))

        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))
    }

    func show(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        center = point
        isHidden = false
        CATransaction.commit()
    }

    func hide() {
        isHidden = true
    }
}

// MARK: - Blank Tile Overlay + Renderer

final class PortlandBlankTileOverlay: MKTileOverlay {
    override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
    }
}

final class PortlandWhiteTileRenderer: MKTileOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let rect = self.rect(for: mapRect)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
    }
}

// MARK: - Overlay Feature Tagging

private var overlayFeatureTypeKey: UInt8 = 0
private var overlayLevelKey: UInt8 = 0
private var overlayFeatureIdKey: UInt8 = 0

extension MKPolyline {
    var portlandFeatureType: PortlandFeatureType? {
        get { objc_getAssociatedObject(self, &overlayFeatureTypeKey) as? PortlandFeatureType }
        set { objc_setAssociatedObject(self, &overlayFeatureTypeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var portlandLevel: Int {
        get { (objc_getAssociatedObject(self, &overlayLevelKey) as? Int) ?? 1 }
        set { objc_setAssociatedObject(self, &overlayLevelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var portlandFeatureId: String? {
        get { objc_getAssociatedObject(self, &overlayFeatureIdKey) as? String }
        set { objc_setAssociatedObject(self, &overlayFeatureIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - PortlandMapView (UIViewRepresentable)

struct PortlandMapView: UIViewRepresentable {

    let features: [PortlandMapFeature]
    let isInteractionEnabled: Bool
    var onDoubleTapIntersection: ((PortlandIntersection) -> Void)?
    var onBackGesture: (() -> Void)?
    var trafficSegments: [PortlandTrafficSegment]
    var trafficIntersections: [PortlandTrafficIntersection]
    var apsLocations: [PortlandAPSLocation]
    var selectedTimeOfDay: TrafficTimeOfDay
    var level: Int = 1

    func makeUIView(context: Context) -> PortlandAccessibleMapView {
        let mapView = PortlandAccessibleMapView(frame: .zero)
        mapView.touchDelegate = context.coordinator

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

        let blankOverlay = PortlandBlankTileOverlay(urlTemplate: nil)
        mapView.addOverlay(blankOverlay, level: .aboveLabels)

        mapView.delegate = context.coordinator

        // Touch indicator
        let touchIndicator = PortlandTouchIndicatorView()
        mapView.addSubview(touchIndicator)
        context.coordinator.touchIndicator = touchIndicator

        // Gesture recognizers (non-VoiceOver mode only)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        doubleTap.delaysTouchesBegan = false
        doubleTap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(doubleTap)
        context.coordinator.doubleTapGesture = doubleTap

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = context.coordinator
        mapView.addGestureRecognizer(singleTap)
        context.coordinator.singleTapGesture = singleTap

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0
        longPress.require(toFail: doubleTap)
        longPress.delegate = context.coordinator
        longPress.delaysTouchesBegan = false
        longPress.cancelsTouchesInView = false
        mapView.addGestureRecognizer(longPress)
        context.coordinator.longPressGesture = longPress

        let threeFingerSwipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerSwipe(_:)))
        threeFingerSwipeRight.numberOfTouchesRequired = 3
        threeFingerSwipeRight.direction = .right
        mapView.addGestureRecognizer(threeFingerSwipeRight)

        let threeFingerSwipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerSwipe(_:)))
        threeFingerSwipeLeft.numberOfTouchesRequired = 3
        threeFingerSwipeLeft.direction = .left
        mapView.addGestureRecognizer(threeFingerSwipeLeft)

        // When VoiceOver is on, disable ALL custom gesture recognizers.
        // Touch delegate handles exploration and double-tap detection.
        // VoiceOver Z-gesture (two-finger scrub) triggers accessibilityPerformEscape.
        let isVO = UIAccessibility.isVoiceOverRunning
        singleTap.isEnabled = !isVO
        longPress.isEnabled = !isVO
        doubleTap.isEnabled = !isVO
        threeFingerSwipeRight.isEnabled = !isVO
        threeFingerSwipeLeft.isEnabled = !isVO

        context.coordinator.mapViewRef = mapView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )

        return mapView
    }

    func updateUIView(_ mapView: PortlandAccessibleMapView, context: Context) {
        let coordinator = context.coordinator
        let featuresChanged = coordinator.features.count != features.count ||
            coordinator.features.first?.featureId != features.first?.featureId

        let timeChanged = coordinator.lastRenderedTimeOfDay != selectedTimeOfDay

        coordinator.features = features
        coordinator.trafficSegments = trafficSegments
        coordinator.trafficIntersections = trafficIntersections
        coordinator.apsLocations = apsLocations
        coordinator.selectedTimeOfDay = selectedTimeOfDay
        coordinator.onDoubleTapIntersection = onDoubleTapIntersection
        coordinator.onBackGesture = onBackGesture
        coordinator.level = level

        if level == 2 {
            mapView.onEscapeGesture = { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.feedbackManager.stopAllFeedback()
                coordinator.onBackGesture?()
            }
        } else {
            mapView.onEscapeGesture = nil
        }

        if featuresChanged {
            let existingOverlays = mapView.overlays.filter { !($0 is PortlandBlankTileOverlay) }
            mapView.removeOverlays(existingOverlays)
            mapView.removeAnnotations(mapView.annotations)

            for feature in features {
                switch feature {
                case let corridor as PortlandCorridor:
                    let polyline = corridor.polyline
                    polyline.portlandFeatureType = .corridor
                    polyline.portlandLevel = corridor.level
                    polyline.portlandFeatureId = corridor.featureId
                    mapView.addOverlay(polyline, level: .aboveLabels)

                case let sidewalk as PortlandSidewalk:
                    let polyline = sidewalk.polyline
                    polyline.portlandFeatureType = .sidewalk
                    polyline.portlandLevel = sidewalk.level
                    mapView.addOverlay(polyline, level: .aboveLabels)

                case let crosswalk as PortlandCrosswalk:
                    let polyline = crosswalk.polyline
                    polyline.portlandFeatureType = .crosswalk
                    polyline.portlandLevel = crosswalk.level
                    mapView.addOverlay(polyline, level: .aboveLabels)

                case let intersection as PortlandIntersection:
                    mapView.addAnnotation(intersection)

                case let landmark as PortlandLandmark:
                    mapView.addAnnotation(landmark)

                default:
                    break
                }
            }

            coordinator.lastRenderedTimeOfDay = selectedTimeOfDay
            setFixedViewport(mapView)
        } else if timeChanged {
            coordinator.lastRenderedTimeOfDay = selectedTimeOfDay
            coordinator.updateTrafficColors(on: mapView)
        }
    }

    private func setFixedViewport(_ mapView: MKMapView) {
        guard !features.isEmpty else { return }

        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude

        for feature in features {
            let coords: [CLLocationCoordinate2D]
            if let corridor = feature as? PortlandCorridor {
                coords = corridor.getCoordinates()
            } else if let intersection = feature as? PortlandIntersection {
                coords = [intersection.coordinate]
            } else if let landmark = feature as? PortlandLandmark {
                coords = [landmark.coordinate]
            } else if let sidewalk = feature as? PortlandSidewalk {
                coords = sidewalk.getCoordinates()
            } else if let crosswalk = feature as? PortlandCrosswalk {
                coords = crosswalk.getCoordinates()
            } else {
                continue
            }
            for coord in coords {
                minLat = min(minLat, coord.latitude)
                maxLat = max(maxLat, coord.latitude)
                minLon = min(minLon, coord.longitude)
                maxLon = max(maxLon, coord.longitude)
            }
        }

        let padding = 0.0008
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) + padding,
            longitudeDelta: (maxLon - minLon) + padding
        )
        let region = MKCoordinateRegion(center: center, span: span)
        mapView.setRegion(region, animated: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, PortlandMapTouchDelegate, UIGestureRecognizerDelegate {

        var features: [PortlandMapFeature] = []
        var trafficSegments: [PortlandTrafficSegment] = []
        var trafficIntersections: [PortlandTrafficIntersection] = []
        var apsLocations: [PortlandAPSLocation] = []
        var selectedTimeOfDay: TrafficTimeOfDay = .midday
        var lastRenderedTimeOfDay: TrafficTimeOfDay?
        var onDoubleTapIntersection: ((PortlandIntersection) -> Void)?
        var onBackGesture: (() -> Void)?
        var level: Int = 1
        var touchIndicator: PortlandTouchIndicatorView?
        weak var mapViewRef: PortlandAccessibleMapView?

        // Gesture recognizer references
        weak var singleTapGesture: UITapGestureRecognizer?
        weak var longPressGesture: UILongPressGestureRecognizer?
        weak var doubleTapGesture: UITapGestureRecognizer?

        // VoiceOver manual double-tap detection
        private var voTouchStartPoint: CGPoint?
        private var voTouchStartTime: Date?
        private var voLastTapPoint: CGPoint?
        private var voLastTapTime: Date?
        private var voPendingSingleTap: DispatchWorkItem?
        private var voIsDragging = false

        let feedbackManager = PortlandFeedbackManager.shared
        private var currentFeature: PortlandMapFeature?
        private var lastAnnouncedFeatureId: String?

        init(parent: PortlandMapView) {
            self.features = parent.features
            self.trafficSegments = parent.trafficSegments
            self.trafficIntersections = parent.trafficIntersections
            self.apsLocations = parent.apsLocations
            self.selectedTimeOfDay = parent.selectedTimeOfDay
            self.onDoubleTapIntersection = parent.onDoubleTapIntersection
            self.onBackGesture = parent.onBackGesture
            self.level = parent.level
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: - VoiceOver State Change

        @objc func voiceOverStatusChanged() {
            let isVO = UIAccessibility.isVoiceOverRunning
            singleTapGesture?.isEnabled = !isVO
            longPressGesture?.isEnabled = !isVO
            doubleTapGesture?.isEnabled = !isVO
        }

        // MARK: - Traffic Colors

        func trafficColor(forCorridorId corridorId: String) -> UIColor {
            guard let segment = trafficSegments.first(where: { $0.id == corridorId }),
                  let profile = segment.hourlyProfile[selectedTimeOfDay.rawValue] else {
                return UIColor(red: 0x02/255.0, green: 0x3E/255.0, blue: 0x8A/255.0, alpha: 1.0)
            }

            switch profile.level {
            case "very_light":
                return UIColor(red: 0x4A/255.0, green: 0x9E/255.0, blue: 0x4A/255.0, alpha: 1.0)
            case "light":
                return UIColor(red: 0x21/255.0, green: 0x96/255.0, blue: 0xF3/255.0, alpha: 1.0)
            case "moderate":
                return UIColor(red: 0x02/255.0, green: 0x3E/255.0, blue: 0x8A/255.0, alpha: 1.0)
            case "heavy":
                return UIColor(red: 0xE6/255.0, green: 0x7E/255.0, blue: 0x22/255.0, alpha: 1.0)
            case "very_heavy":
                return UIColor(red: 0xC1/255.0, green: 0x12/255.0, blue: 0x1F/255.0, alpha: 1.0)
            default:
                return UIColor(red: 0x02/255.0, green: 0x3E/255.0, blue: 0x8A/255.0, alpha: 1.0)
            }
        }

        func updateTrafficColors(on mapView: MKMapView) {
            for overlay in mapView.overlays {
                guard let polyline = overlay as? MKPolyline,
                      polyline.portlandFeatureType == .corridor,
                      let featureId = polyline.portlandFeatureId else { continue }

                if let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer {
                    renderer.strokeColor = trafficColor(forCorridorId: featureId)
                    renderer.setNeedsDisplay()
                }
            }
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is PortlandBlankTileOverlay {
                return PortlandWhiteTileRenderer(tileOverlay: overlay as! MKTileOverlay)
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)

                switch polyline.portlandFeatureType {
                case .corridor:
                    if let featureId = polyline.portlandFeatureId {
                        renderer.strokeColor = trafficColor(forCorridorId: featureId)
                    } else {
                        renderer.strokeColor = UIColor(red: 0x02/255.0, green: 0x3E/255.0, blue: 0x8A/255.0, alpha: 1.0)
                    }
                    let roadWidth = polyline.portlandLevel == 2
                        ? PortlandPhysicalDimensions.mmToPoints(12.0)
                        : PortlandPhysicalDimensions.mmToPoints(4.0)
                    renderer.lineWidth = roadWidth

                case .sidewalk:
                    renderer.strokeColor = UIColor(red: 0x9E/255.0, green: 0x9E/255.0, blue: 0x9E/255.0, alpha: 1.0)
                    renderer.lineWidth = PortlandPhysicalDimensions.mmToPoints(4.0)

                case .crosswalk:
                    renderer.strokeColor = .white
                    renderer.lineWidth = PortlandPhysicalDimensions.mmToPoints(2.8)
                    renderer.lineDashPattern = [
                        NSNumber(value: Float(PortlandPhysicalDimensions.mmToPoints(1.5))),
                        NSNumber(value: Float(PortlandPhysicalDimensions.mmToPoints(1.0)))
                    ]

                default:
                    renderer.strokeColor = .gray
                    renderer.lineWidth = 2.0
                }

                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let intersection = annotation as? PortlandIntersection {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: PortlandIntersectionAnnotationView.reuseIdentifier)
                    ?? PortlandIntersectionAnnotationView(annotation: intersection, reuseIdentifier: PortlandIntersectionAnnotationView.reuseIdentifier)
                view.annotation = intersection
                let hasLight = trafficIntersections.contains { $0.id == intersection.featureId && ($0.hasTrafficLight ?? false) }
                (view as? PortlandIntersectionAnnotationView)?.showTrafficLight(hasLight)
                return view
            }

            if let landmark = annotation as? PortlandLandmark {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: PortlandLandmarkAnnotationView.reuseIdentifier)
                    ?? PortlandLandmarkAnnotationView(annotation: landmark, reuseIdentifier: PortlandLandmarkAnnotationView.reuseIdentifier)
                view.annotation = landmark
                return view
            }

            return nil
        }

        // MARK: - Gesture Handlers (non-VoiceOver)

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)

            if level == 2 {
                feedbackManager.stopAllFeedback()
                onBackGesture?()
                return
            }

            if let intersection = hitTestIntersection(at: point, in: mapView) {
                feedbackManager.stopAllFeedback()
                feedbackManager.playSingleTap()
                onDoubleTapIntersection?(intersection)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            announceFeatureAt(point: point, in: mapView)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)

            switch gesture.state {
            case .began:
                startExploration(at: point, in: mapView)
                touchIndicator?.show(at: point)
            case .changed:
                updateExploration(at: point, in: mapView)
                touchIndicator?.show(at: point)
            case .ended, .cancelled:
                stopExploration()
                touchIndicator?.hide()
            default:
                break
            }
        }

        @objc func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
            feedbackManager.stopAllFeedback()
            feedbackManager.playSingleTap()
            feedbackManager.speak("Going back")
            onBackGesture?()
        }

        // MARK: - Touch Delegate (VoiceOver direct touch)

        func touchBegan(at point: CGPoint, in view: UIView) {
            guard let mapView = view as? MKMapView else { return }

            voTouchStartPoint = point
            voTouchStartTime = Date()
            voIsDragging = false
            voPendingSingleTap?.cancel()

            startExploration(at: point, in: mapView)
            touchIndicator?.show(at: point)
        }

        func touchMoved(to point: CGPoint, in view: UIView) {
            guard let mapView = view as? MKMapView else { return }

            if let start = voTouchStartPoint {
                let displacement = hypot(point.x - start.x, point.y - start.y)
                if displacement > 8 {
                    voIsDragging = true
                    voPendingSingleTap?.cancel()
                }
            }

            updateExploration(at: point, in: mapView)
            touchIndicator?.show(at: point)
        }

        func touchEnded(at point: CGPoint, in view: UIView) {
            stopExploration()
            touchIndicator?.hide()

            guard let mapView = view as? MKMapView,
                  let startPoint = voTouchStartPoint,
                  let startTime = voTouchStartTime,
                  !voIsDragging else {
                voTouchStartPoint = nil
                voTouchStartTime = nil
                return
            }

            let displacement = hypot(point.x - startPoint.x, point.y - startPoint.y)
            let duration = Date().timeIntervalSince(startTime)

            voTouchStartPoint = nil
            voTouchStartTime = nil

            guard displacement < 28, duration < 0.45 else { return }

            if let lastTime = voLastTapTime, let lastPoint = voLastTapPoint,
               Date().timeIntervalSince(lastTime) < 0.45,
               hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 48 {
                // Double-tap detected
                voPendingSingleTap?.cancel()
                voLastTapTime = nil
                voLastTapPoint = nil

                if level == 2 {
                    feedbackManager.stopAllFeedback()
                    onBackGesture?()
                } else if let intersection = hitTestIntersection(at: point, in: mapView) {
                    feedbackManager.stopAllFeedback()
                    feedbackManager.playSingleTap()
                    onDoubleTapIntersection?(intersection)
                }
            } else {
                voLastTapTime = Date()
                voLastTapPoint = point

                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.announceFeatureAt(point: point, in: mapView)
                    self.voLastTapTime = nil
                    self.voLastTapPoint = nil
                }
                voPendingSingleTap = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
            }
        }

        // MARK: - Exploration Logic

        private func trafficLevel(for feature: PortlandMapFeature) -> String? {
            guard let corridor = feature as? PortlandCorridor,
                  let segment = trafficSegments.first(where: { $0.id == corridor.featureId }),
                  let profile = segment.hourlyProfile[selectedTimeOfDay.rawValue] else {
                return nil
            }
            return profile.level
        }

        private func startExploration(at point: CGPoint, in mapView: MKMapView) {
            let feature = hitTestFeature(at: point, in: mapView)
            currentFeature = feature
            lastAnnouncedFeatureId = nil

            if let feature = feature {
                let traffic = trafficLevel(for: feature)
                feedbackManager.startFeedback(for: feature, trafficLevel: traffic)
                announceFeature(feature)
                lastAnnouncedFeatureId = feature.featureId
            }
        }

        private func updateExploration(at point: CGPoint, in mapView: MKMapView) {
            let feature = hitTestFeature(at: point, in: mapView)

            if feature?.featureId != currentFeature?.featureId {
                if currentFeature != nil {
                    feedbackManager.stopAllFeedback()
                }
                currentFeature = feature

                if let feature = feature {
                    let traffic = trafficLevel(for: feature)
                    feedbackManager.startFeedback(for: feature, trafficLevel: traffic)
                    if feature.featureId != lastAnnouncedFeatureId {
                        announceFeature(feature)
                        lastAnnouncedFeatureId = feature.featureId
                    }
                }
            }
        }

        private func stopExploration() {
            feedbackManager.stopAllFeedback()
            currentFeature = nil
            lastAnnouncedFeatureId = nil
        }

        // MARK: - Hit Testing

        private func hitTestFeature(at point: CGPoint, in mapView: MKMapView) -> PortlandMapFeature? {
            let coord = mapView.convert(point, toCoordinateFrom: mapView)

            let landmarkThreshold = mapView.region.span.latitudeDelta * 0.05
            let intersectionThreshold = mapView.region.span.latitudeDelta * 0.04
            let lineThreshold = mapView.region.span.latitudeDelta * 0.025

            for feature in features {
                if let landmark = feature as? PortlandLandmark {
                    let dist = hypot(coord.latitude - landmark.coordinate.latitude,
                                     coord.longitude - landmark.coordinate.longitude)
                    if dist < landmarkThreshold { return landmark }
                }
            }

            for feature in features {
                if let intersection = feature as? PortlandIntersection {
                    let dist = hypot(coord.latitude - intersection.coordinate.latitude,
                                     coord.longitude - intersection.coordinate.longitude)
                    if dist < intersectionThreshold { return intersection }
                }
            }

            for feature in features {
                if let crosswalk = feature as? PortlandCrosswalk {
                    if distanceToPolyline(coord: coord, coords: crosswalk.getCoordinates()) < lineThreshold {
                        return crosswalk
                    }
                }
            }

            for feature in features {
                if let sidewalk = feature as? PortlandSidewalk {
                    if distanceToPolyline(coord: coord, coords: sidewalk.getCoordinates()) < lineThreshold {
                        return sidewalk
                    }
                }
            }

            for feature in features {
                if let corridor = feature as? PortlandCorridor {
                    if distanceToPolyline(coord: coord, coords: corridor.getCoordinates()) < lineThreshold {
                        return corridor
                    }
                }
            }

            return nil
        }

        private func hitTestIntersection(at point: CGPoint, in mapView: MKMapView) -> PortlandIntersection? {
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            let threshold = mapView.region.span.latitudeDelta * 0.06

            for feature in features {
                if let intersection = feature as? PortlandIntersection {
                    let dist = hypot(coord.latitude - intersection.coordinate.latitude,
                                     coord.longitude - intersection.coordinate.longitude)
                    if dist < threshold { return intersection }
                }
            }
            return nil
        }

        private func distanceToPolyline(coord: CLLocationCoordinate2D, coords: [CLLocationCoordinate2D]) -> Double {
            guard coords.count >= 2 else {
                if let first = coords.first {
                    return hypot(coord.latitude - first.latitude, coord.longitude - first.longitude)
                }
                return Double.greatestFiniteMagnitude
            }

            var minDist = Double.greatestFiniteMagnitude
            for i in 0..<(coords.count - 1) {
                let d = distanceToSegment(point: coord, segStart: coords[i], segEnd: coords[i + 1])
                minDist = min(minDist, d)
            }
            return minDist
        }

        private func distanceToSegment(point: CLLocationCoordinate2D,
                                       segStart: CLLocationCoordinate2D,
                                       segEnd: CLLocationCoordinate2D) -> Double {
            let px = point.longitude, py = point.latitude
            let ax = segStart.longitude, ay = segStart.latitude
            let bx = segEnd.longitude, by = segEnd.latitude

            let dx = bx - ax, dy = by - ay
            let lenSq = dx * dx + dy * dy
            guard lenSq > 0 else { return hypot(px - ax, py - ay) }

            var t = ((px - ax) * dx + (py - ay) * dy) / lenSq
            t = max(0, min(1, t))

            let projX = ax + t * dx
            let projY = ay + t * dy
            return hypot(px - projX, py - projY)
        }

        // MARK: - Announcements

        private func announceFeature(_ feature: PortlandMapFeature) {
            var text = feature.announcement()

            if let intersection = feature as? PortlandIntersection {
                let hasAPS = apsLocations.contains { $0.intersectionId == intersection.featureId }
                let hasLight = trafficIntersections.contains { $0.id == intersection.featureId && ($0.hasTrafficLight ?? false) }
                if hasLight {
                    text = "Signalized intersection with traffic light. " + text
                }
                if hasAPS {
                    text += ". Accessible pedestrian signal present"
                }
                if level == 1 {
                    text += ". Double tap to explore intersection detail"
                }
            }

            if let corridor = feature as? PortlandCorridor {
                if let segment = trafficSegments.first(where: { $0.id == corridor.featureId }) {
                    let profile = segment.hourlyProfile[selectedTimeOfDay.rawValue]
                    let levelDesc = profile?.level.replacingOccurrences(of: "_", with: " ") ?? "moderate"
                    text += ". \(segment.lanes) lanes, \(levelDesc) traffic"
                }
            }

            if let landmark = feature as? PortlandLandmark, !landmark.tag.isEmpty {
                text = "\(landmark.tag) stands for \(landmark.featureName). " + text
            }

            feedbackManager.speak(text)
        }

        private func announceFeatureAt(point: CGPoint, in mapView: MKMapView) {
            if let feature = hitTestFeature(at: point, in: mapView) {
                feedbackManager.playSingleTap()
                announceFeature(feature)
            }
        }
    }
}
