//
//  RTMLiveMapView.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  This is the actual map you see on screen. SwiftUI can't show an MKMapView
//  directly, so we wrap one in a `UIViewRepresentable` (that's the standard way to
//  use a UIKit view inside SwiftUI). We hand it three lists — streets, intersections,
//  and places (POIs) — and it draws them on a plain white background (Apple's normal
//  map is hidden, see RTMMapOverlays.swift).
//
//  HOW THE USER INTERACTS
//   • One finger  -> drags the purple "you are here" dot. As it moves, we tell
//                    RTMMapFeedbackController what it's touching so the phone buzzes
//                    and speaks (e.g. "Howie's Pub, on your right").
//   • Two fingers -> pans the map around.
//   • Pinch       -> zooms; we snap to one of four fixed zoom levels.
//   • Twist       -> rotates the map. The +/- and location buttons (in
//                    RTMRouxMapView) are the easy, VoiceOver-friendly way to zoom and
//                    re-center for blind users who can't pinch.
//
//  The heavy lifting (delegate callbacks, gestures) lives in the `Coordinator`
//  class near the bottom — UIViewRepresentable uses a coordinator as its "helper".
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Commands the SwiftUI screen sends to the map

/// The buttons in RTMRouxMapView can't poke the MKMapView directly, so instead they
/// set one of these values; `updateUIView` reads it, performs the action once, then
/// resets it back to `.none`. Think of it as a little "to-do note" for the map.
enum RTMMapCommand: Equatable {
    case none
    case fitFeatures   // show the whole area
    case centerOnUser  // jump back to the purple dot
    case zoomIn        // one zoom level closer
    case zoomOut       // one zoom level farther
    case moveTo(lat: Double, lon: Double)  // jump the dot to a place / intersection
}

// MARK: - RTMLiveMapView

struct RTMLiveMapView: UIViewRepresentable {

    let streets: [RTMDiscoveredStreet]
    let intersections: [RTMDiscoveredIntersection]
    let pois: [RTMDiscoveredPOI]

    /// A one-shot camera command (e.g. from a toolbar button).
    @Binding var command: RTMMapCommand

    /// Live camera distance (meters), surfaced to the UI as a zoom readout.
    @Binding var debugZoom: Double

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = RTMMapKitView()
        let coordinator = context.coordinator
        coordinator.mapView = mapView
        mapView.delegate = coordinator

        // Run the camera/zoom/focus setup once the map actually has a size — driven
        // by layoutSubviews, which is reliable (updateUIView may not fire after layout).
        mapView.onFirstLayout = { [weak coordinator, weak mapView] in
            guard let coordinator, let mapView else { return }
            coordinator.performInitialSetupIfNeeded(mapView)
        }

        // Pan is ON (drag moves the map); zoom and rotate are OFF (zoom is the
        // on-screen buttons; rotate off so a stray rotor twist can't spin the
        // map). The map is also a VoiceOver Direct Touch area, so under VoiceOver
        // a one-finger drag passes through to pan and a tap places the dot.
        mapView.showsUserLocation = false
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false

        mapView.isAccessibilityElement = true
        mapView.accessibilityTraits = .allowsDirectInteraction
        mapView.accessibilityLabel = "Tactile map"
        mapView.accessibilityHint = "Drag to move the map. Tap a lane to place your location dot there. "
            + "Use the zoom and Options buttons to change the view."

        // White tile overlay blanks Apple's map (incl. labels). Added at .aboveLabels
        // with the streets right after at the same level so streets stay on top.
        let blankOverlay = RTMWhiteTileOverlay()
        blankOverlay.canReplaceMapContent = true
        mapView.addOverlay(blankOverlay, level: .aboveLabels)

        // Feedback brain (haptics + speech) for the dragged cursor.
        coordinator.feedback = RTMMapFeedbackController(streets: streets, intersections: intersections, pois: pois)

        // Street polylines.
        for street in streets where street.coordinates.count >= 2 {
            var coords = street.coordinates
            let polyline = RTMStreetPolyline(coordinates: &coords, count: coords.count)
            polyline.roadType = street.roadType
            polyline.title = street.name
            mapView.addOverlay(polyline, level: .aboveLabels)
        }

        // POI markers snapped onto the nearest path, using
        // the same snapping as the feedback controller so marker and feedback align.
        let poiAnnotations = pois.map { poi -> RTMPOIAnnotation in
            let anchor = RTMMapFeedbackController.nearestPointOnPath(to: poi.coordinate, in: streets) ?? poi.coordinate
            return RTMPOIAnnotation(poi, at: anchor)
        }
        mapView.addAnnotations(poiAnnotations)
        mapView.addAnnotations(intersections.map(RTMIntersectionAnnotation.init))

        // Simulated location dot, dropped at the center of the data.
        if let center = featuresCenter() {
            coordinator.simulated.coordinate = center
            mapView.addAnnotation(coordinator.simulated)
        }

        // A single TAP places the dot on the nearest lane. A DRAG is left to the
        // map's own pan (scroll), so dragging moves the map. The tap recognizer
        // only fires on a tap (no movement), so it never competes with panning.
        let placeTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePlaceTap(_:)))
        placeTap.delegate = coordinator
        mapView.addGestureRecognizer(placeTap)

        // A pinch recognizer (alongside the map's own) so we can snap to one of the 4
        // zoom levels the moment the pinch ends — more reliable than waiting on the
        // region-did-change delegate, and it also flags "pinching" so the dot doesn't
        // jump while zooming.
        let zoomPinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        zoomPinch.delegate = coordinator
        mapView.addGestureRecognizer(zoomPinch)

        // Keep panning roughly in the area, but with a GENEROUS margin (100% on
        // each side). The old 2% margin clamped the camera so that following the
        // dot to an edge lane left the dot stuck at the screen edge with no way
        // to recenter. The wide margin lets the camera center on edge lanes;
        // "Center on me" / "Fit whole area" always return to the start view.
        let rect = featuresRect()
        if !rect.isNull {
            let padded = rect.insetBy(dx: -rect.size.width, dy: -rect.size.height)
            mapView.cameraBoundary = MKMapView.CameraBoundary(mapRect: padded)
        }

        // Surface the live zoom value to the UI.
        let zoomBinding = $debugZoom
        coordinator.onZoomChanged = { distance in zoomBinding.wrappedValue = distance }

        // Camera/zoom/focus setup is deferred to updateUIView, once the view has a
        // real size (in makeUIView the bounds are still .zero → bogus camera math).
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.performInitialSetupIfNeeded(mapView)

        // A button set a command — do it once, then clear the note.
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

    /// Ends the CSV logging session when the map screen goes away.
    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.feedback?.endLog()
    }

    // MARK: Geometry helpers (over the feature set)

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

        /// The draggable stand-in for the user's location.
        let simulated = RTMSimulatedUserAnnotation()
        weak var simulatedView: RTMSimulatedUserAnnotationView?

        // Drag state.
        private var lastDragPoint: CGPoint?
        private var lastDotCoordinate: CLLocationCoordinate2D?
        private var travelHeading: CGFloat?   // geographic bearing of travel (radians, 0 = N)
        private var isPinching = false        // true while a zoom pinch is in progress

        // Street renderers + ground width (m), rescaled on every zoom change.
        private var streetRenderers: [(renderer: MKPolylineRenderer, groundMeters: CGFloat)] = []

        // MARK: Locked zoom levels

        /// The four allowed camera distances (meters); a pinch snaps to the nearest.
        private let zoomLevels: [CLLocationDistance] = [120, 300, 650, 1000]
        /// Distance the map opens at and the "center on me" button returns to.
        private let focusDistance: CLLocationDistance = 300
        /// How close (meters) the finger must be to a path for the dot to snap
        /// onto it. Beyond this the dot follows the finger freely, so you can
        /// move through open areas that aren't on a lane (and the map follows).
        private let pathSnapMeters: CLLocationDistance = 30
        private var isSnappingZoom = false
        private var hasPerformedInitialSetup = false

        // MARK: Initial setup (after layout)

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

        /// Centers on the data and zooms to the widest fixed level — the same
        /// view you get by pressing "−" all the way. Excludes the white
        /// background overlay (its bounds cover the whole world, which made the
        /// old "fit" zoom out to a blank screen).
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

        /// Centers on the simulated dot at the default zoom — used on launch and by
        /// the "center on my location" button.
        func focusOnSimulated(animated: Bool) {
            guard let mapView, CLLocationCoordinate2DIsValid(simulated.coordinate) else { return }
            let camera = MKMapCamera(lookingAtCenter: simulated.coordinate, fromDistance: focusDistance, pitch: 0, heading: 0)
            mapView.setCamera(camera, animated: animated)
        }

        /// Jumps the dot to a chosen place / intersection (from the Options menu),
        /// centers on it, and fires feedback so it announces what's there. This is
        /// the VoiceOver-friendly way to move without dragging.
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

        /// Steps the zoom one fixed level in or out (used by the + / − buttons, which
        /// are the easy way for blind/VoiceOver users to zoom without pinching).
        /// `zoomLevels` is sorted small→large, so a smaller distance = more zoomed in.
        func stepZoom(closer: Bool) {
            guard let mapView else { return }
            let levels = zoomLevels.sorted()
            let current = mapView.camera.centerCoordinateDistance
            // Which level are we closest to right now?
            let nearestIndex = levels.indices.min(by: { abs(levels[$0] - current) < abs(levels[$1] - current) }) ?? 0
            // Move one step: zoom in = lower index (smaller distance), zoom out = higher.
            let nextIndex = closer ? max(0, nearestIndex - 1) : min(levels.count - 1, nearestIndex + 1)
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinateDistance = levels[nextIndex]
            mapView.setCamera(camera, animated: true)
        }

        /// Snaps the camera to the nearest locked level once the region settles.
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

        /// Re-scale street widths + intersection dots for the current zoom so paths
        /// stay clearly separated at every level.
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
                return RTMWhiteTileRenderer(tileOverlay: tile)   // synchronous white fill
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
                view.displayPriority = .required   // never hidden by collision
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

        /// Snaps to the nearest of the 4 zoom levels when a pinch finishes.
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

        /// A tap drops the dot on the nearest lane and announces it. (Dragging is
        /// left to the map's own pan, so a drag moves the map.)
        @objc func handlePlaceTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView else { return }
            let point = gesture.location(in: mapView)
            let fingerCoordinate = mapView.convert(point, toCoordinateFrom: mapView)
            // Snap to the nearest lane so a tap "on any lane" lands on it.
            let coordinate = feedback?.snappedToPath(near: fingerCoordinate) ?? fingerCoordinate
            simulated.coordinate = coordinate
            simulatedView?.center = mapView.convert(coordinate, toPointTo: mapView)
            feedback?.update(at: coordinate, heading: nil)
            // It's a tap, not a held touch — end the continuous haptic shortly
            // after so it doesn't buzz forever (speech keeps playing).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.feedback?.stop()
            }
        }

        /// Geographic bearing (radians, clockwise from north) from `a` to `b`, or nil
        /// if they're within ~1 m (too small to be a meaningful direction).
        private static func geographicBearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CGFloat? {
            let metersPerDegLat = 111_320.0
            let metersPerDegLon = 111_320.0 * cos(a.latitude * .pi / 180)
            let east = (b.longitude - a.longitude) * metersPerDegLon
            let north = (b.latitude - a.latitude) * metersPerDegLat
            guard east * east + north * north > 1.0 else { return nil }
            return CGFloat(atan2(east, north))
        }

        /// Scrolls the map to keep the dot inside a margin from the edges (follow mode).
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

/// Calls `onFirstLayout` the first time the map gets a non-zero size. We use this
/// (instead of `updateUIView`) to run the initial camera/zoom/focus setup, because
/// SwiftUI doesn't guarantee an `updateUIView` after the view is laid out — which is
/// why the map previously appeared only after tapping a button.
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
