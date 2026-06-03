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
}

// MARK: - RTMLiveMapView

struct RTMLiveMapView: UIViewRepresentable {

    let streets: [RTMDiscoveredStreet]
    let intersections: [RTMDiscoveredIntersection]
    let pois: [RTMDiscoveredPOI]

    @Binding var command: RTMMapCommand
    @Binding var debugZoom: Double

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

        // Blank, navigable, rotatable map. ONE finger drags the dot,
        // TWO fingers pan the map (the map's pan is forced to two-finger below),
        // pinch zooms (snapped to 4 levels), twist rotates.
        mapView.showsUserLocation = false
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false

        for recognizer in mapView.gestureRecognizers ?? [] {
            (recognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches = 2
        }
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true

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

        if let center = featuresCenter() {
            coordinator.simulated.coordinate = center
            mapView.addAnnotation(coordinator.simulated)
        }

        let dotPan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDotPan(_:)))
        dotPan.delegate = coordinator
        dotPan.minimumNumberOfTouches = 1
        dotPan.maximumNumberOfTouches = 1
        coordinator.dotPanRecognizer = dotPan
        mapView.addGestureRecognizer(dotPan)

        let zoomPinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        zoomPinch.delegate = coordinator
        mapView.addGestureRecognizer(zoomPinch)

        let rect = featuresRect()
        if !rect.isNull {
            let padded = rect.insetBy(dx: -rect.size.width * 0.02, dy: -rect.size.height * 0.02)
            mapView.cameraBoundary = MKMapView.CameraBoundary(mapRect: padded)
        }

        let zoomBinding = $debugZoom
        coordinator.onZoomChanged = { distance in zoomBinding.wrappedValue = distance }

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
            context.coordinator.focusOnSimulated(animated: true)
            clearCommand()
        case .zoomIn:
            context.coordinator.stepZoom(closer: true)
            clearCommand()
        case .zoomOut:
            context.coordinator.stepZoom(closer: false)
            clearCommand()
        case .moveTo(let lat, let lon):
            context.coordinator.moveDot(to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
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

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        weak var mapView: MKMapView?
        weak var dotPanRecognizer: UIPanGestureRecognizer?
        var feedback: RTMMapFeedbackController?
        var onZoomChanged: ((CLLocationDistance) -> Void)?

        let simulated = RTMSimulatedUserAnnotation()
        weak var simulatedView: RTMSimulatedUserAnnotationView?

        // Drag state.
        private var lastDragPoint: CGPoint?
        private var lastDotCoordinate: CLLocationCoordinate2D?
        private var travelHeading: CGFloat?
        private var isPinching = false

        // Street renderers + ground width (m), rescaled on every zoom change.
        private var streetRenderers: [(renderer: MKPolylineRenderer, groundMeters: CGFloat)] = []

        // MARK: Locked zoom levels

        private let zoomLevels: [CLLocationDistance] = [120, 300, 650, 1000]
        private let focusDistance: CLLocationDistance = 300
        private var isSnappingZoom = false
        private var hasPerformedInitialSetup = false

        // MARK: Initial setup

        func performInitialSetupIfNeeded(_ mapView: MKMapView) {
            guard !hasPerformedInitialSetup, mapView.bounds.width > 10 else { return }
            hasPerformedInitialSetup = true
            mapView.setCameraZoomRange(
                MKMapView.CameraZoomRange(
                    minCenterCoordinateDistance: zoomLevels.min() ?? 120,
                    maxCenterCoordinateDistance: zoomLevels.max() ?? 1000
                ),
                animated: false
            )
            focusOnSimulated(animated: false)
            rescale(in: mapView)
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
                ? simulated.coordinate
                : MKMapPoint(x: rect.midX, y: rect.midY).coordinate
            guard CLLocationCoordinate2DIsValid(center) else { return }
            let widest = zoomLevels.max() ?? 1000
            let camera = MKMapCamera(lookingAtCenter: center, fromDistance: widest, pitch: 0, heading: 0)
            mapView.setCamera(camera, animated: animated)
        }

        func focusOnSimulated(animated: Bool) {
            guard let mapView, CLLocationCoordinate2DIsValid(simulated.coordinate) else { return }
            let camera = MKMapCamera(lookingAtCenter: simulated.coordinate, fromDistance: focusDistance, pitch: 0, heading: 0)
            mapView.setCamera(camera, animated: animated)
        }

        func moveDot(to coord: CLLocationCoordinate2D) {
            guard let mapView, CLLocationCoordinate2DIsValid(coord) else { return }
            simulated.coordinate = coord
            simulatedView?.center = mapView.convert(coord, toPointTo: mapView)
            let camera = MKMapCamera(lookingAtCenter: coord, fromDistance: focusDistance, pitch: 0, heading: mapView.camera.heading)
            mapView.setCamera(camera, animated: true)
            feedback?.update(at: coord, heading: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.feedback?.stop()
            }
        }

        func stepZoom(closer: Bool) {
            guard let mapView else { return }
            let levels = zoomLevels.sorted()
            let current = mapView.camera.centerCoordinateDistance
            let nearestIndex = levels.indices.min(by: { abs(levels[$0] - current) < abs(levels[$1] - current) }) ?? 0
            let nextIndex = closer ? max(0, nearestIndex - 1) : min(levels.count - 1, nearestIndex + 1)
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance = levels[nextIndex]
            mapView.setCamera(camera, animated: true)
        }

        private func snapZoomIfNeeded(_ mapView: MKMapView) {
            let distance = mapView.camera.centerCoordinateDistance
            guard let nearest = zoomLevels.min(by: { abs($0 - distance) < abs($1 - distance) }) else { return }
            if isSnappingZoom {
                if abs(distance - nearest) / nearest < 0.05 { isSnappingZoom = false }
                return
            }
            if abs(distance - nearest) / nearest > 0.05 {
                isSnappingZoom = true
                let camera = mapView.camera.copy() as! MKMapCamera
                camera.centerCoordinateDistance = nearest
                mapView.setCamera(camera, animated: true)
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
            for entry in streetRenderers {
                entry.renderer.lineWidth = clampWidth(entry.groundMeters * ppm)
                entry.renderer.setNeedsDisplay()
            }
            for annotation in mapView.annotations where annotation is RTMIntersectionAnnotation {
                (mapView.view(for: annotation) as? RTMIntersectionAnnotationView)?.applyGroundScale(pointsPerMeter: ppm)
            }
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
            renderer.lineWidth = clampWidth(style.groundWidthMeters * pointsPerMeter(in: mapView))
            streetRenderers.append((renderer, style.groundWidthMeters))
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let simulated = annotation as? RTMSimulatedUserAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "simulated") as? RTMSimulatedUserAnnotationView)
                    ?? RTMSimulatedUserAnnotationView(annotation: simulated, reuseIdentifier: "simulated")
                view.annotation = simulated
                simulatedView = view
                view.accessibilityLabel = "Your location"
                return view
            }

            if let poi = annotation as? RTMPOIAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "poi") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: poi, reuseIdentifier: "poi")
                view.annotation = poi
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: poi.category.symbolName)
                view.canShowCallout = true
                view.titleVisibility = .adaptive
                view.displayPriority = .required
                view.accessibilityLabel = "\(poi.title ?? "Place"), \(poi.category.displayName)"
                return view
            }

            if let intersection = annotation as? RTMIntersectionAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "intersection") as? RTMIntersectionAnnotationView)
                    ?? RTMIntersectionAnnotationView(annotation: intersection, reuseIdentifier: "intersection")
                view.annotation = intersection
                view.displayPriority = .required
                view.applyGroundScale(pointsPerMeter: pointsPerMeter(in: mapView))
                view.accessibilityLabel = "Intersection: \(intersection.title ?? "unnamed")"
                return view
            }

            return nil
        }

        // MARK: Dot dragging

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                isPinching = true
            case .ended, .cancelled, .failed:
                isPinching = false
                if let mapView { snapZoomIfNeeded(mapView) }
            default:
                break
            }
        }

        @objc func handleDotPan(_ gesture: UIPanGestureRecognizer) {
            guard let mapView, !isPinching else { return }
            let point = gesture.location(in: mapView)

            switch gesture.state {
            case .began, .changed:
                let fingerCoordinate = mapView.convert(point, toCoordinateFrom: mapView)
                let coordinate = feedback?.snappedToPath(near: fingerCoordinate) ?? fingerCoordinate
                simulated.coordinate = coordinate
                simulatedView?.center = mapView.convert(coordinate, toPointTo: mapView)

                if let last = lastDragPoint {
                    let dx = point.x - last.x, dy = point.y - last.y
                    if dx * dx + dy * dy > 4 { simulatedView?.setHeading(atan2(dx, -dy)) }
                }
                lastDragPoint = point

                if let lastCoord = lastDotCoordinate,
                   let bearing = Self.geographicBearing(from: lastCoord, to: coordinate) {
                    travelHeading = bearing
                }
                lastDotCoordinate = coordinate

                feedback?.update(at: coordinate, heading: travelHeading)
                keepDotInView(mapView)

            case .ended, .cancelled, .failed:
                lastDragPoint = nil
                lastDotCoordinate = nil
                travelHeading = nil
                feedback?.stop()

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

        private func keepDotInView(_ mapView: MKMapView) {
            let inset: CGFloat = 90
            let bounds = mapView.bounds
            let dotPoint = mapView.convert(simulated.coordinate, toPointTo: mapView)
            var dx: CGFloat = 0, dy: CGFloat = 0
            if dotPoint.x < bounds.minX + inset { dx = dotPoint.x - (bounds.minX + inset) }
            else if dotPoint.x > bounds.maxX - inset { dx = dotPoint.x - (bounds.maxX - inset) }
            if dotPoint.y < bounds.minY + inset { dy = dotPoint.y - (bounds.minY + inset) }
            else if dotPoint.y > bounds.maxY - inset { dy = dotPoint.y - (bounds.maxY - inset) }
            guard dx != 0 || dy != 0 else { return }
            let shifted = CGPoint(x: bounds.midX + dx, y: bounds.midY + dy)
            mapView.setCenter(mapView.convert(shifted, toCoordinateFrom: mapView), animated: false)
        }
    }
}

// MARK: - MKMapView subclass that reports its first real layout

final class RTMMapKitView: MKMapView {
    var onFirstLayout: (() -> Void)?
    private var didFireFirstLayout = false

    override func layoutSubviews() {
        super.layoutSubviews()
        if !didFireFirstLayout, bounds.width > 10, bounds.height > 10 {
            didFireFirstLayout = true
            onFirstLayout?()
        }
    }
}
