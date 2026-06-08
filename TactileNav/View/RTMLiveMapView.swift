//
//  RTMLiveMapView.swift
//  TactileNav  (RouxTactileMap)
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Commands the SwiftUI screen sends to the map

enum RTMMapCommand: Equatable {
    case none
    case fitFeatures
    case centerOnUser
    case zoomIn
    case zoomOut
    case moveTo(lat: Double, lon: Double)
    case pan(RTMPanDirection)
    case pageTurn(RTMEdgeDirection)
    case goBackPage
}

// MARK: - RTMLiveMapView

struct RTMLiveMapView: UIViewRepresentable {

    let streets: [RTMDiscoveredStreet]
    let intersections: [RTMDiscoveredIntersection]
    let pois: [RTMDiscoveredPOI]

    @Binding var command: RTMMapCommand
    @Binding var debugZoom: Double
    @Binding var currentZoomLevel: RTMFunctionalZoomLevel

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = RTMMapKitView()
        let coordinator = context.coordinator
        coordinator.mapView = mapView
        mapView.delegate = coordinator

        mapView.onFirstLayout = { [weak coordinator, weak mapView] in
            guard let coordinator, let mapView else { return }
            coordinator.performInitialSetupIfNeeded(mapView)
        }

        // All built-in gestures OFF — we handle everything ourselves so
        // nothing fights with VoiceOver Direct Touch (same as NavIndoor).
        mapView.showsUserLocation = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsBuildings = false
        mapView.showsScale = false
        mapView.backgroundColor = .systemBackground

        // Hide all Apple Maps content — belt-and-suspenders with the tile overlay.
        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        mapView.preferredConfiguration = config

        // VoiceOver: Direct Touch lets one-finger drags pass through.
        mapView.isAccessibilityElement = true
        mapView.accessibilityTraits = .allowsDirectInteraction
        mapView.accessibilityLabel = "Tactile map"
        mapView.accessibilityHint = "Drag one finger to explore. Triple tap to cycle zoom. At the edge, double tap to turn the page. Two-finger double tap to go back."
        mapView.accessibilityCoordinator = coordinator

        let blankOverlay = RTMWhiteTileOverlay()
        blankOverlay.canReplaceMapContent = true
        mapView.addOverlay(blankOverlay, level: .aboveLabels)

        coordinator.feedback = RTMMapFeedbackController(streets: streets, intersections: intersections, pois: pois)

        for street in streets where street.coordinates.count >= 2 {
            var coords = street.coordinates
            let polyline = RTMStreetPolyline(coordinates: &coords, count: coords.count)
            polyline.roadType = street.roadType
            polyline.title = street.name
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        let poiAnnotations = pois.map { poi -> RTMPOIAnnotation in
            let anchor = RTMMapFeedbackController.nearestPointOnPath(to: poi.coordinate, in: streets) ?? poi.coordinate
            return RTMPOIAnnotation(poi, at: anchor)
        }
        mapView.addAnnotations(poiAnnotations)
        mapView.addAnnotations(intersections.map(RTMIntersectionAnnotation.init))

        // Remember the data's center for the "center"/"fit" actions (no dot is drawn).
        coordinator.exploreCenter = featuresCenter() ?? mapView.centerCoordinate

        // One-finger triple tap cycles overview → streets → detail → overview.
        let zoomCycle = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleZoomCycle(_:)))
        zoomCycle.numberOfTapsRequired = 3
        zoomCycle.numberOfTouchesRequired = 1
        zoomCycle.delegate = coordinator
        zoomCycle.delaysTouchesBegan = false
        zoomCycle.cancelsTouchesInView = false
        mapView.addGestureRecognizer(zoomCycle)

        // One-finger double tap turns the page when an edge has been announced.
        let pageTurn = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePageTurn(_:)))
        pageTurn.numberOfTapsRequired = 2
        pageTurn.numberOfTouchesRequired = 1
        pageTurn.delegate = coordinator
        pageTurn.delaysTouchesBegan = false
        pageTurn.cancelsTouchesInView = false
        mapView.addGestureRecognizer(pageTurn)

        // Two-finger double tap undoes the last page turn.
        let goBack = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleGoBack(_:)))
        goBack.numberOfTapsRequired = 2
        goBack.numberOfTouchesRequired = 2
        goBack.delegate = coordinator
        mapView.addGestureRecognizer(goBack)

        // FINGER IS THE CURSOR (Nav-Indoor / Indoor_Route model): a long-press
        // recognizer with zero delay fires the instant a finger touches the map and
        // keeps firing as it moves, so the point under the finger is the trigger.
        // The map itself does NOT move while exploring.
        let explore = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleExplore(_:)))
        explore.minimumPressDuration = 0
        explore.delegate = coordinator
        mapView.addGestureRecognizer(explore)
        coordinator.exploreGesture = explore
        pageTurn.require(toFail: zoomCycle)
        explore.require(toFail: pageTurn)
        explore.require(toFail: zoomCycle)

        // The finger-cursor indicator (ring + arrow), shown only while touching.
        let indicator = RTMTouchIndicatorView()
        mapView.addSubview(indicator)
        coordinator.touchIndicator = indicator

        coordinator.panBoundary = Self.paddedFeaturesRect(from: featuresRect())

        let zoomBinding = $debugZoom
        coordinator.onZoomChanged = { distance in zoomBinding.wrappedValue = distance }
        let levelBinding = $currentZoomLevel
        coordinator.onZoomLevelChanged = { level in levelBinding.wrappedValue = level }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.performInitialSetupIfNeeded(mapView)

        switch command {
        case .none:
            break
        case .fitFeatures:
            context.coordinator.fitFeatures(in: mapView, animated: true)
            clearCommand()
        case .centerOnUser:
            context.coordinator.focusOnCenter(animated: true)
            clearCommand()
        case .zoomIn:
            context.coordinator.stepZoom(closer: true)
            clearCommand()
        case .zoomOut:
            context.coordinator.stepZoom(closer: false)
            clearCommand()
        case .moveTo(let lat, let lon):
            context.coordinator.jumpTo(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            clearCommand()
        case .pan(let direction):
            context.coordinator.panByDirection(direction)
            clearCommand()
        case .pageTurn(let direction):
            context.coordinator.performPageTurn(direction)
            clearCommand()
        case .goBackPage:
            context.coordinator.performGoBack()
            clearCommand()
        }
    }

    private func clearCommand() {
        DispatchQueue.main.async { command = .none }
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.feedback?.endLog()
    }

    // MARK: Geometry helpers

    private func featuresCenter() -> CLLocationCoordinate2D? {
        let coords = allCoordinates()
        guard !coords.isEmpty else { return nil }
        let lat = coords.reduce(0) { $0 + $1.latitude } / Double(coords.count)
        let lon = coords.reduce(0) { $0 + $1.longitude } / Double(coords.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func featuresRect() -> MKMapRect {
        var rect = MKMapRect.null
        for coordinate in allCoordinates() {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        return rect
    }

    private func allCoordinates() -> [CLLocationCoordinate2D] {
        streets.flatMap(\.coordinates) + intersections.map(\.coordinate) + pois.map(\.coordinate)
    }

    /// Features bounding box expanded by 15% on each side for pan clamping.
    private static func paddedFeaturesRect(from rect: MKMapRect) -> MKMapRect {
        guard !rect.isNull else { return rect }
        let padX = rect.size.width * 0.15
        let padY = rect.size.height * 0.15
        return rect.insetBy(dx: -padX, dy: -padY)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        weak var mapView: MKMapView?
        var feedback: RTMMapFeedbackController?
        var onZoomChanged: ((CLLocationDistance) -> Void)?
        var onZoomLevelChanged: ((RTMFunctionalZoomLevel) -> Void)?

        /// The middle of the data — where "center" / "fit" returns to. Not drawn;
        /// there is no location dot (the finger itself is the cursor).
        var exploreCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        /// The ring + arrow shown under the fingertip while exploring.
        weak var touchIndicator: RTMTouchIndicatorView?
        weak var exploreGesture: UILongPressGestureRecognizer?
        /// Pan clamp boundary (features + 15% padding).
        var panBoundary = MKMapRect.null

        // Page-turn panning state.
        private let edgeZone: CGFloat = 50
        private var pendingPageTurn: RTMEdgeDirection?
        private var lastAnnouncedEdge: RTMEdgeDirection?
        private var viewHistory: [CLLocationCoordinate2D] = []

        // Explore drag state.
        private var lastDragPoint: CGPoint?
        private var lastDotCoordinate: CLLocationCoordinate2D?
        private var travelHeading: CGFloat?

        // Street renderers + ground width (m), rescaled on every zoom change.
        private var streetRenderers: [(renderer: MKPolylineRenderer, groundMeters: CGFloat)] = []

        // MARK: Functional zoom

        private var currentZoomLevel: RTMFunctionalZoomLevel = .streets
        private var isSnappingZoom = false
        private var hasPerformedInitialSetup = false

        private var minCameraDistance: CLLocationDistance {
            RTMFunctionalZoomLevel.detail.cameraDistance
        }
        private var maxCameraDistance: CLLocationDistance {
            RTMFunctionalZoomLevel.overview.cameraDistance
        }

        // MARK: Initial setup

        func performInitialSetupIfNeeded(_ mapView: MKMapView) {
            guard !hasPerformedInitialSetup, mapView.bounds.width > 10 else { return }
            hasPerformedInitialSetup = true
            mapView.setCameraZoomRange(
                MKMapView.CameraZoomRange(
                    minCenterCoordinateDistance: minCameraDistance,
                    maxCenterCoordinateDistance: maxCameraDistance
                ),
                animated: false
            )
            let camera = MKMapCamera(
                lookingAtCenter: exploreCenter,
                fromDistance: RTMFunctionalZoomLevel.streets.cameraDistance,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: false)
            applyZoomLevel(.streets, animated: false, announce: false)
        }

        func fitFeatures(in mapView: MKMapView, animated: Bool) {
            var rect = MKMapRect.null
            for overlay in mapView.overlays where !(overlay is RTMWhiteTileOverlay) {
                rect = rect.union(overlay.boundingMapRect)
            }
            for annotation in mapView.annotations where !(annotation is MKUserLocation) {
                let point = MKMapPoint(annotation.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            let center = rect.isNull
                ? exploreCenter
                : MKMapPoint(x: rect.midX, y: rect.midY).coordinate
            guard CLLocationCoordinate2DIsValid(center) else { return }
            let camera = MKMapCamera(
                lookingAtCenter: clampPanCenter(center),
                fromDistance: RTMFunctionalZoomLevel.overview.cameraDistance,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: animated)
            applyZoomLevel(.overview, animated: animated, announce: true)
        }

        /// Recenters the camera on the middle of the data (the "center" action).
        func focusOnCenter(animated: Bool) {
            guard let mapView, CLLocationCoordinate2DIsValid(exploreCenter) else { return }
            let camera = MKMapCamera(
                lookingAtCenter: clampPanCenter(exploreCenter),
                fromDistance: currentZoomLevel.cameraDistance,
                pitch: 0,
                heading: mapView.camera.heading
            )
            mapView.setCamera(camera, animated: animated)
        }

        /// Moves the camera to a chosen place/intersection (the Options "jump to") and
        /// announces it once. No dot is moved — this just repositions the view.
        func jumpTo(_ coord: CLLocationCoordinate2D) {
            guard let mapView, CLLocationCoordinate2DIsValid(coord) else { return }
            let camera = MKMapCamera(
                lookingAtCenter: clampPanCenter(coord),
                fromDistance: currentZoomLevel.cameraDistance,
                pitch: 0,
                heading: mapView.camera.heading
            )
            mapView.setCamera(camera, animated: true)
            feedback?.update(at: coord, heading: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.feedback?.stop()
            }
        }

        // MARK: Functional zoom

        func applyZoomLevel(_ level: RTMFunctionalZoomLevel, animated: Bool, announce: Bool) {
            guard let mapView else { return }
            let levelChanged = level != currentZoomLevel
            currentZoomLevel = level
            feedback?.currentZoomLevel = level
            DispatchQueue.main.async { [weak self] in
                self?.onZoomLevelChanged?(level)
            }

            updateFeatureVisibility(in: mapView)

            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance = level.cameraDistance
            camera.centerCoordinate = clampPanCenter(camera.centerCoordinate)
            mapView.setCamera(camera, animated: animated)
            onZoomChanged?(level.cameraDistance)

            if announce, levelChanged {
                feedback?.announceZoomTransition(to: level)
            }

            refreshStreetRenderers(in: mapView)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let mapView = self.mapView else { return }
                self.nudgeCameraTowardFeaturesIfNeeded(in: mapView)
            }
        }

        private func updateFeatureVisibility(in mapView: MKMapView) {
            for entry in streetRenderers {
                guard let street = entry.renderer.overlay as? RTMStreetPolyline else { continue }
                entry.renderer.alpha = currentZoomLevel.isStreetVisible(street.roadType) ? 1 : 0
            }
            for annotation in mapView.annotations {
                if annotation is MKUserLocation { continue }
                let view = mapView.view(for: annotation)
                if annotation is RTMPOIAnnotation {
                    view?.isHidden = !currentZoomLevel.showPOIs
                } else if annotation is RTMIntersectionAnnotation {
                    view?.isHidden = !currentZoomLevel.showIntersections
                }
            }
        }

        func stepZoom(closer: Bool) {
            let levels = RTMFunctionalZoomLevel.allCases
            guard let index = levels.firstIndex(of: currentZoomLevel) else { return }
            if closer {
                guard index < levels.count - 1 else {
                    feedback?.announceAlreadyAtDetailLevel()
                    return
                }
                applyZoomLevel(levels[index + 1], animated: true, announce: true)
            } else {
                guard index > 0 else {
                    feedback?.announceAlreadyAtOverviewLevel()
                    return
                }
                applyZoomLevel(levels[index - 1], animated: true, announce: true)
            }
        }

        /// Triple-tap cycles overview → streets → detail → overview.
        func cycleZoomLevel() {
            let levels = RTMFunctionalZoomLevel.allCases
            guard let index = levels.firstIndex(of: currentZoomLevel) else { return }
            let next = levels[(index + 1) % levels.count]
            applyZoomLevel(next, animated: true, announce: true)
        }

        private func snapZoomIfNeeded(_ mapView: MKMapView) {
            let distance = mapView.camera.centerCoordinateDistance
            let nearest = RTMFunctionalZoomLevel.nearest(to: distance)
            if isSnappingZoom {
                if abs(distance - nearest.cameraDistance) / nearest.cameraDistance < 0.05 {
                    isSnappingZoom = false
                }
                return
            }
            if abs(distance - nearest.cameraDistance) / nearest.cameraDistance > 0.05 || nearest != currentZoomLevel {
                isSnappingZoom = true
                applyZoomLevel(nearest, animated: true, announce: nearest != currentZoomLevel)
            }
        }

        // MARK: Panning

        private func clampPanCenter(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            guard !panBoundary.isNull, let mapView else { return coordinate }

            let viewportWidth = mapView.visibleMapRect.size.width
            let viewportHeight = mapView.visibleMapRect.size.height

            let insetX = min(viewportWidth * 0.4, panBoundary.size.width * 0.4)
            let insetY = min(viewportHeight * 0.4, panBoundary.size.height * 0.4)
            let tightBounds = panBoundary.insetBy(dx: insetX, dy: insetY)

            guard tightBounds.size.width > 0, tightBounds.size.height > 0 else {
                return MKMapPoint(x: panBoundary.midX, y: panBoundary.midY).coordinate
            }

            let point = MKMapPoint(coordinate)
            let clampedX = min(max(point.x, tightBounds.minX), tightBounds.maxX)
            let clampedY = min(max(point.y, tightBounds.minY), tightBounds.maxY)
            return MKMapPoint(x: clampedX, y: clampedY).coordinate
        }

        private func nudgeCameraTowardFeaturesIfNeeded(in mapView: MKMapView) {
            let visibleRect = mapView.visibleMapRect
            var onScreenCount = 0

            for annotation in mapView.annotations {
                if annotation is MKUserLocation { continue }
                if annotation is RTMPOIAnnotation, !currentZoomLevel.showPOIs { continue }
                if annotation is RTMIntersectionAnnotation, !currentZoomLevel.showIntersections { continue }
                if visibleRect.contains(MKMapPoint(annotation.coordinate)) { onScreenCount += 1 }
            }

            for entry in streetRenderers {
                guard let street = entry.renderer.overlay as? RTMStreetPolyline else { continue }
                guard currentZoomLevel.isStreetVisible(street.roadType) else { continue }
                if visibleRect.intersects(street.boundingMapRect) { onScreenCount += 1 }
            }

            guard onScreenCount < 2 else { return }

            let center = mapView.camera.centerCoordinate
            var nearestCoord: CLLocationCoordinate2D?
            var nearestDist = Double.greatestFiniteMagnitude

            for annotation in mapView.annotations {
                if annotation is MKUserLocation { continue }
                if annotation is RTMPOIAnnotation, !currentZoomLevel.showPOIs { continue }
                if annotation is RTMIntersectionAnnotation, !currentZoomLevel.showIntersections { continue }
                let dist = distanceBetween(center, annotation.coordinate)
                if dist < nearestDist {
                    nearestDist = dist
                    nearestCoord = annotation.coordinate
                }
            }

            for entry in streetRenderers {
                guard let street = entry.renderer.overlay as? RTMStreetPolyline else { continue }
                guard currentZoomLevel.isStreetVisible(street.roadType) else { continue }
                let mid = MKMapPoint(x: street.boundingMapRect.midX, y: street.boundingMapRect.midY).coordinate
                let dist = distanceBetween(center, mid)
                if dist < nearestDist {
                    nearestDist = dist
                    nearestCoord = mid
                }
            }

            guard let target = nearestCoord else { return }

            let nudged = CLLocationCoordinate2D(
                latitude: center.latitude + (target.latitude - center.latitude) * 0.7,
                longitude: center.longitude + (target.longitude - center.longitude) * 0.7
            )

            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinate = clampPanCenter(nudged)
            mapView.setCamera(camera, animated: true)
        }

        private func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            let dx = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
            let dy = (b.latitude - a.latitude) * 111_320
            return (dx * dx + dy * dy).squareRoot()
        }

        func panByDirection(_ direction: RTMPanDirection) {
            performPageTurn(direction.asEdgeDirection)
        }

        func handleAccessibilityPan(_ direction: UIAccessibilityScrollDirection) {
            switch direction {
            case .left:  performPageTurn(.east)
            case .right: performPageTurn(.west)
            case .up:    performPageTurn(.north)
            case .down:  performPageTurn(.south)
            @unknown default: break
            }
        }

        // MARK: Page-turn panning

        func performPageTurn(_ direction: RTMEdgeDirection) {
            guard let mapView, let feedback else { return }

            let previousCenter = mapView.camera.centerCoordinate
            let region = mapView.region
            let latShift = region.span.latitudeDelta * 0.8
            let lonShift = region.span.longitudeDelta * 0.8

            var newCenter = previousCenter
            switch direction {
            case .north: newCenter.latitude += latShift
            case .south: newCenter.latitude -= latShift
            case .east:  newCenter.longitude += lonShift
            case .west:  newCenter.longitude -= lonShift
            }

            let clamped = clampPanCenter(newCenter)
            let moved = abs(clamped.latitude - previousCenter.latitude) > 1e-9
                || abs(clamped.longitude - previousCenter.longitude) > 1e-9
            guard moved else {
                feedback.announceNothingOffScreen(direction: direction)
                clearPageTurnState()
                return
            }

            viewHistory.append(previousCenter)

            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinate = clamped
            mapView.setCamera(camera, animated: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let mapView = self.mapView else { return }
                self.nudgeCameraTowardFeaturesIfNeeded(in: mapView)
            }

            let anchor = feedback.findOrientationAnchor(comingFrom: direction.opposite, visibleRect: mapView.visibleMapRect)
            feedback.announcePageTurn(direction: direction, anchor: anchor)
            clearPageTurnState()
        }

        func performGoBack() {
            guard let mapView, let previous = viewHistory.popLast() else { return }
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinate = clampPanCenter(previous)
            mapView.setCamera(camera, animated: true)
            feedback?.announceGoBack()
            clearPageTurnState()
        }

        private func clearPageTurnState() {
            pendingPageTurn = nil
            lastAnnouncedEdge = nil
        }

        private func edgeCandidates(for point: CGPoint, in bounds: CGRect) -> [RTMEdgeDirection] {
            var candidates: [RTMEdgeDirection] = []
            if point.x < edgeZone { candidates.append(.west) }
            if point.x > bounds.width - edgeZone { candidates.append(.east) }
            if point.y < edgeZone { candidates.append(.north) }
            if point.y > bounds.height - edgeZone { candidates.append(.south) }
            return candidates
        }

        private func resolveEdgeDirection(for point: CGPoint, in bounds: CGRect, screenHeading: CGFloat?) -> RTMEdgeDirection? {
            let candidates = edgeCandidates(for: point, in: bounds)
            guard !candidates.isEmpty else { return nil }
            guard candidates.count > 1, let heading = screenHeading else { return candidates[0] }

            let scores: [(RTMEdgeDirection, CGFloat)] = [
                (.north, cos(heading)),
                (.south, -cos(heading)),
                (.east, sin(heading)),
                (.west, -sin(heading))
            ]
            if let best = scores.filter({ candidates.contains($0.0) }).max(by: { $0.1 < $1.1 }), best.1 > 0.3 {
                return best.0
            }
            return candidates[0]
        }

        private func updateEdgePageTurnState(point: CGPoint, screenHeading: CGFloat?, in mapView: MKMapView) {
            guard let feedback else { return }

            if let direction = resolveEdgeDirection(for: point, in: mapView.bounds, screenHeading: screenHeading) {
                guard lastAnnouncedEdge != direction else { return }

                let summary = feedback.featuresOffScreen(direction: direction, visibleRect: mapView.visibleMapRect)
                lastAnnouncedEdge = direction

                if summary.hasContent {
                    feedback.announceEdgeEntry(direction: direction, summary: summary)
                    pendingPageTurn = direction
                } else {
                    feedback.announceNothingOffScreen(direction: direction)
                    pendingPageTurn = nil
                }
            } else {
                lastAnnouncedEdge = nil
            }
        }

        // MARK: Delegate — zoom-responsive sizing

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            rescale(in: mapView)
            onZoomChanged?(mapView.camera.centerCoordinateDistance)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            snapZoomIfNeeded(mapView)
            rescale(in: mapView)
        }

        func rescale(in mapView: MKMapView) {
            let ppm = pointsPerMeter(in: mapView)
            let maxDot: CGFloat = currentZoomLevel == .detail ? 34 : 20
            for entry in streetRenderers {
                entry.renderer.lineWidth = streetLineWidth(groundMeters: entry.groundMeters, pointsPerMeter: ppm)
                entry.renderer.setNeedsDisplay()
            }
            for annotation in mapView.annotations where annotation is RTMIntersectionAnnotation {
                (mapView.view(for: annotation) as? RTMIntersectionAnnotationView)?
                    .applyGroundScale(pointsPerMeter: ppm, maxDiameter: maxDot)
            }
        }

        private func refreshStreetRenderers(in mapView: MKMapView) {
            rescale(in: mapView)
            for entry in streetRenderers {
                entry.renderer.invalidatePath()
            }
        }

        private func streetLineWidth(groundMeters: CGFloat, pointsPerMeter ppm: CGFloat) -> CGFloat {
            clampWidth(groundMeters * currentZoomLevel.streetWidthScale * ppm)
        }

        private func pointsPerMeter(in mapView: MKMapView) -> CGFloat {
            let centerLat = mapView.region.center.latitude
            let metersAcross = mapView.visibleMapRect.size.width * MKMetersPerMapPointAtLatitude(centerLat)
            guard metersAcross > 0, mapView.bounds.width > 0 else { return 0.1 }
            return mapView.bounds.width / CGFloat(metersAcross)
        }

        private func clampWidth(_ width: CGFloat) -> CGFloat { min(max(width, 2.5), 60) }

        // MARK: Delegate — overlays & annotations

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return RTMWhiteTileRenderer(tileOverlay: tile)
            }
            guard let street = overlay as? RTMStreetPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let style = street.roadType.renderStyle
            let renderer = MKPolylineRenderer(polyline: street)
            renderer.strokeColor = style.color
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.lineDashPattern = style.dashPattern
            let ppm = pointsPerMeter(in: mapView)
            renderer.lineWidth = streetLineWidth(groundMeters: style.groundWidthMeters, pointsPerMeter: ppm)
            renderer.alpha = currentZoomLevel.isStreetVisible(street.roadType) ? 1 : 0
            streetRenderers.append((renderer, style.groundWidthMeters))
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let poi = annotation as? RTMPOIAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "poi") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: poi, reuseIdentifier: "poi")
                view.annotation = poi
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: poi.category.symbolName)
                view.canShowCallout = true
                view.titleVisibility = .adaptive
                view.displayPriority = .required
                view.isHidden = !currentZoomLevel.showPOIs
                view.accessibilityLabel = "\(poi.title ?? "Place"), \(poi.category.displayName)"
                return view
            }

            if let intersection = annotation as? RTMIntersectionAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "intersection") as? RTMIntersectionAnnotationView)
                    ?? RTMIntersectionAnnotationView(annotation: intersection, reuseIdentifier: "intersection")
                view.annotation = intersection
                view.displayPriority = .required
                view.isHidden = !currentZoomLevel.showIntersections
                let maxDot: CGFloat = currentZoomLevel == .detail ? 34 : 20
                view.applyGroundScale(pointsPerMeter: pointsPerMeter(in: mapView), maxDiameter: maxDot)
                view.accessibilityLabel = "Intersection: \(intersection.title ?? "unnamed")"
                return view
            }

            return nil
        }

        // MARK: Gestures

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handleZoomCycle(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            touchIndicator?.isHidden = true
            feedback?.stop()
            cycleZoomLevel()
        }

        @objc func handlePageTurn(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let direction = pendingPageTurn else { return }
            performPageTurn(direction)
        }

        @objc func handleGoBack(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            performGoBack()
        }

        // The finger is the cursor: raw finger position, no path snapping.
        @objc func handleExplore(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)

            switch gesture.state {
            case .began, .changed:
                let coordinate = mapView.convert(point, toCoordinateFrom: mapView)

                var screenHeading: CGFloat?
                if let last = lastDragPoint {
                    let dx = point.x - last.x, dy = point.y - last.y
                    if dx * dx + dy * dy > 4 { screenHeading = atan2(dx, -dy) }
                }
                lastDragPoint = point

                touchIndicator?.isHidden = false
                touchIndicator?.move(to: point, heading: screenHeading)

                if let lastCoord = lastDotCoordinate,
                   let bearing = Self.geographicBearing(from: lastCoord, to: coordinate) {
                    travelHeading = bearing
                }
                lastDotCoordinate = coordinate

                feedback?.update(at: coordinate, heading: travelHeading)
                updateEdgePageTurnState(point: point, screenHeading: screenHeading, in: mapView)

            case .ended, .cancelled, .failed:
                lastDragPoint = nil
                lastDotCoordinate = nil
                travelHeading = nil
                touchIndicator?.isHidden = true
                feedback?.stop()
                let directionAtLift = pendingPageTurn
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    if self?.pendingPageTurn == directionAtLift {
                        self?.pendingPageTurn = nil
                    }
                }

            default:
                break
            }
        }

        private static func geographicBearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CGFloat? {
            let metersPerDegLat = 111_320.0
            let metersPerDegLon = 111_320.0 * cos(a.latitude * .pi / 180)
            let east = (b.longitude - a.longitude) * metersPerDegLon
            let north = (b.latitude - a.latitude) * metersPerDegLat
            guard east * east + north * north > 1.0 else { return nil }
            return CGFloat(atan2(east, north))
        }
    }
}

// MARK: - MKMapView subclass that reports its first real layout

final class RTMMapKitView: MKMapView {
    var onFirstLayout: (() -> Void)?
    weak var accessibilityCoordinator: RTMLiveMapView.Coordinator?
    private var didFireFirstLayout = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if !didFireFirstLayout, bounds.width > 10, bounds.height > 10 {
            didFireFirstLayout = true
            onFirstLayout?()
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        accessibilityCoordinator?.handleAccessibilityPan(direction)
        return true
    }
}
