import SwiftUI
import MapKit
import TactileMapCore
import TactileMapFeedback

/// The main SwiftUI entry point for rendering a tactile map.
///
/// Supports two rendering backends selected via
/// ``TactileMapViewConfiguration/renderingMode``:
///
/// - **`.canvas`** (default): SwiftUI Canvas with clean junction rendering,
///   directional touch indicator, and simpler coordinate pipeline.
/// - **`.mapKit`**: MKMapView with overlays and annotations. Use when you
///   need geographic coordinate integration.
///
/// Both modes use the same ``FeedbackPolicy``, ``HitDetectionConfig``,
/// and ``TactileMapViewConfiguration`` for consistent behavior.
public struct TactileMapView: View {

    /// The parsed map document containing features and bounds.
    public let document: TactileMapDocument

    /// Visual and behavioral configuration.
    public let configuration: TactileMapViewConfiguration

    /// The feedback policy invoked when the user touches map elements.
    public let feedbackPolicy: any FeedbackPolicy

    /// Hit detection configuration.
    public let hitDetection: HitDetectionConfig

    /// Coordinate transform for converting document coordinates to geographic.
    /// Only used in `.mapKit` mode.
    public let coordinateTransform: CoordinateTransform

    /// Optional closure called when the user performs a back gesture.
    public var onBackGesture: (() -> Void)?

    // MARK: - Initializer

    /// Creates a tactile map view.
    ///
    /// - Parameters:
    ///   - document: The map document to render.
    ///   - configuration: Visual/behavioral configuration.
    ///   - feedbackPolicy: The feedback policy for element interactions.
    ///   - hitDetection: Hit detection configuration.
    ///   - coordinateTransform: Coordinate transform (MapKit mode only).
    ///   - onBackGesture: Closure called when the user performs a back gesture.
    public init(
        document: TactileMapDocument,
        configuration: TactileMapViewConfiguration = .default,
        feedbackPolicy: any FeedbackPolicy,
        hitDetection: HitDetectionConfig = .default,
        coordinateTransform: CoordinateTransform = .default,
        onBackGesture: (() -> Void)? = nil
    ) {
        self.document = document
        self.configuration = configuration
        self.feedbackPolicy = feedbackPolicy
        self.hitDetection = hitDetection
        self.coordinateTransform = coordinateTransform
        self.onBackGesture = onBackGesture
    }

    // MARK: - Body

    public var body: some View {
        switch configuration.renderingMode {
        case .canvas:
            CanvasMapView(
                document: document,
                configuration: configuration,
                hitDetection: hitDetection,
                policy: feedbackPolicy,
                onBackGesture: onBackGesture
            )

        case .mapKit:
            MapKitMapView(
                document: document,
                configuration: configuration,
                feedbackPolicy: feedbackPolicy,
                hitDetection: hitDetection,
                coordinateTransform: coordinateTransform,
                onBackGesture: onBackGesture
            )
        }
    }
}

// MARK: - MapKit Rendering Backend

/// The UIViewRepresentable wrapper around MKMapView for MapKit rendering mode.
///
/// This provides the original MapKit-based rendering pipeline with:
/// - Blank white background via ``BlankTileOverlay``
/// - All map controls disabled
/// - VoiceOver direct-interaction accessibility
/// - Corridor polylines, intersection/landmark annotations, and anchor points
/// - Gesture recognizers for tap, double tap, long press, and three-finger gestures
struct MapKitMapView: UIViewRepresentable {

    let document: TactileMapDocument
    let configuration: TactileMapViewConfiguration
    let feedbackPolicy: any FeedbackPolicy
    let hitDetection: HitDetectionConfig
    let coordinateTransform: CoordinateTransform
    var onBackGesture: (() -> Void)?

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> MapCoordinator {
        MapCoordinator(parent: self)
    }

    func makeUIView(context: Context) -> AccessibleMapView {
        let mapView = AccessibleMapView()
        let coordinator = context.coordinator

        // -- Map delegate --
        mapView.delegate = coordinator

        // -- Back gesture --
        mapView.onBackGesture = onBackGesture

        // -- Blank white background --
        let blankOverlay = BlankTileOverlay(urlTemplate: nil)
        mapView.addOverlay(blankOverlay, level: .aboveLabels)

        // -- Disable all map controls --
        mapView.isZoomEnabled = false
        mapView.isScrollEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.mapType = .mutedStandard
        mapView.showsBuildings = false
        mapView.showsTraffic = false
        mapView.showsCompass = false
        if #available(iOS 16.0, *) {
            mapView.showsUserLocation = false
        }

        // -- VoiceOver accessibility --
        mapView.isAccessibilityElement = true
        mapView.accessibilityTraits = .allowsDirectInteraction
        mapView.accessibilityLabel = "Tactile map"

        // -- Set visible map rect --
        let mapRect = coordinateTransform.mapRect(
            for: document,
            edgePadding: configuration.edgePadding
        )
        mapView.setVisibleMapRect(mapRect, animated: false)

        // -- Add features --
        addFeatures(to: mapView, coordinator: coordinator)

        // -- Install gesture recognizers --
        installGestures(on: mapView, coordinator: coordinator)

        return mapView
    }

    func updateUIView(_ mapView: AccessibleMapView, context: Context) {
        mapView.onBackGesture = onBackGesture
    }

    // MARK: - Feature population

    private func addFeatures(to mapView: AccessibleMapView, coordinator: MapCoordinator) {
        var elements: [MapElement] = []
        var corridorCoordinates: [(elementId: String, coords: [CLLocationCoordinate2D])] = []
        var landmarksNeedingAnchors: [(element: MapElement, coordinate: CLLocationCoordinate2D)] = []

        for feature in document.features {
            elements.append(feature)

            switch feature.geometry {
            case .lineString(let coords):
                let clCoords = coordinateTransform.toCLCoordinates(coords)
                let polyline = MKPolyline(coordinates: clCoords, count: clCoords.count)
                mapView.addOverlay(polyline, level: .aboveLabels)
                corridorCoordinates.append((elementId: feature.id, coords: clCoords))

            case .point(let coord):
                let clCoord = coordinateTransform.toCLCoordinate(coord)
                let annotation = FeatureAnnotation(element: feature, coordinate: clCoord)
                mapView.addAnnotation(annotation)

                if feature.elementType == .landmark {
                    landmarksNeedingAnchors.append((element: feature, coordinate: clCoord))
                }

            case .polygon:
                break
            }
        }

        // Create anchor points for landmarks on the nearest corridor.
        var anchors: [AnchorAnnotation] = []
        for landmark in landmarksNeedingAnchors {
            if let anchorCoord = findNearestPointOnCorridor(
                from: landmark.coordinate,
                corridors: corridorCoordinates
            ) {
                let anchor = AnchorAnnotation(
                    coordinate: anchorCoord,
                    elementId: landmark.element.id,
                    properties: landmark.element.properties
                )
                anchors.append(anchor)
                mapView.addAnnotation(anchor)
            }
        }

        coordinator.elements = elements
        coordinator.anchors = anchors
    }

    private func findNearestPointOnCorridor(
        from coordinate: CLLocationCoordinate2D,
        corridors: [(elementId: String, coords: [CLLocationCoordinate2D])]
    ) -> CLLocationCoordinate2D? {
        var bestPoint: CLLocationCoordinate2D?
        var bestDistance: Double = .greatestFiniteMagnitude

        for corridor in corridors {
            let coords = corridor.coords
            for i in 0..<(coords.count - 1) {
                let projected = projectPointOnSegment(
                    point: coordinate,
                    segStart: coords[i],
                    segEnd: coords[i + 1]
                )
                let dist = distanceBetween(coordinate, projected)
                if dist < bestDistance {
                    bestDistance = dist
                    bestPoint = projected
                }
            }
        }

        return bestPoint
    }

    private func projectPointOnSegment(
        point: CLLocationCoordinate2D,
        segStart: CLLocationCoordinate2D,
        segEnd: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let dx = segEnd.longitude - segStart.longitude
        let dy = segEnd.latitude - segStart.latitude
        let lengthSquared = dx * dx + dy * dy

        if lengthSquared == 0 {
            return segStart
        }

        let t = max(0, min(1,
            ((point.longitude - segStart.longitude) * dx +
             (point.latitude - segStart.latitude) * dy) / lengthSquared
        ))

        return CLLocationCoordinate2D(
            latitude: segStart.latitude + t * dy,
            longitude: segStart.longitude + t * dx
        )
    }

    private func distanceBetween(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let dx = a.longitude - b.longitude
        let dy = a.latitude - b.latitude
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Gesture installation

    private func installGestures(on mapView: AccessibleMapView, coordinator: MapCoordinator) {
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(MapCoordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator
        mapView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(MapCoordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = coordinator
        mapView.addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(MapCoordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = configuration.longPressMinDuration
        longPress.require(toFail: doubleTap)
        longPress.require(toFail: singleTap)
        longPress.delegate = coordinator
        mapView.addGestureRecognizer(longPress)

        let threeFingerSwipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(MapCoordinator.handleThreeFingerSwipe(_:)))
        threeFingerSwipe.numberOfTouchesRequired = 3
        threeFingerSwipe.direction = .right
        threeFingerSwipe.delegate = coordinator
        mapView.addGestureRecognizer(threeFingerSwipe)

        let threeFingerPan = UIPanGestureRecognizer(target: coordinator, action: #selector(MapCoordinator.handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.delegate = coordinator
        mapView.addGestureRecognizer(threeFingerPan)
    }
}
