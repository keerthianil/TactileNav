import MapKit
import TactileMapCore
import TactileMapFeedback

/// The coordinator that handles gesture callbacks, MKMapViewDelegate
/// methods, and feedback dispatch for ``TactileMapView``.
///
/// This class bridges UIKit gesture recognizer callbacks to the
/// ``FeedbackPolicy`` protocol, using ``HitDetector`` to determine
/// which element the user is touching.
@MainActor
public class MapCoordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

    // MARK: - Properties

    /// The parent map view that created this coordinator.
    let parent: MapKitMapView

    /// The hit detector used to find elements at touch points.
    let hitDetector: HitDetector

    /// The element renderer providing annotation views and overlay renderers.
    let renderer: DefaultElementRenderer

    /// All map elements from the document.
    var elements: [MapElement] = []

    /// Anchor point annotations placed on corridors.
    var anchors: [AnchorAnnotation] = []

    /// The element currently being touched during a long press.
    var activeElement: (any TactileMapElement)?

    /// The touch type (direct/anchor) of the current active element.
    var activeTouchType: TouchType?

    // MARK: - Touch tracking

    /// Timestamp of the last element-change update.
    var lastUpdateTime: TimeInterval = 0

    /// The last point recorded during a long press movement.
    var lastMovementPoint: CGPoint?

    /// The current estimated finger velocity in points per second.
    var currentVelocity: CGFloat = 0

    /// Timestamp of the last movement point for velocity calculation.
    private var lastMovementTime: TimeInterval = 0

    // MARK: - Initializer

    /// Creates a coordinator for the given parent view.
    init(parent: MapKitMapView) {
        self.parent = parent
        self.hitDetector = HitDetector(
            config: parent.hitDetection,
            coordinateTransform: parent.coordinateTransform
        )
        self.renderer = DefaultElementRenderer(config: parent.configuration)
        super.init()
    }

    // MARK: - MKMapViewDelegate — Annotation views

    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        // Do not provide custom views for the user location annotation.
        if annotation is MKUserLocation {
            return nil
        }
        return renderer.annotationView(for: annotation, in: mapView)
    }

    // MARK: - MKMapViewDelegate — Overlay renderers

    public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        return renderer.overlayRenderer(for: overlay)
    }

    // MARK: - MKMapViewDelegate — Region changes

    public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Re-fit the map to the document bounds after any region change
        // to prevent the user from scrolling away.
        let mapRect = parent.coordinateTransform.mapRect(
            for: parent.document,
            edgePadding: parent.configuration.edgePadding
        )
        if !mapView.visibleMapRect.intersects(mapRect) {
            mapView.setVisibleMapRect(mapRect, animated: false)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Allow simultaneous recognition so that long press and other
    /// gestures do not block each other unnecessarily.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    // MARK: - Double tap handler

    @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let mapView = gesture.view as? MKMapView else { return }
        let point = gesture.location(in: mapView)

        let result = hitDetector.findElement(
            at: point,
            in: mapView,
            elements: elements,
            anchors: anchors,
            velocity: 0
        )

        if let result = result {
            parent.feedbackPolicy.onTap(element: result.element, touchType: result.touchType)
            parent.onDoubleTap?(result.element)
        }
    }

    // MARK: - Single tap handler

    @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard let mapView = gesture.view as? MKMapView else { return }
        let point = gesture.location(in: mapView)

        let result = hitDetector.findElement(
            at: point,
            in: mapView,
            elements: elements,
            anchors: anchors,
            velocity: 0
        )

        if let result = result {
            parent.feedbackPolicy.onTap(element: result.element, touchType: result.touchType)
        }
    }

    // MARK: - Long press handler (exploration mode)

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let mapView = gesture.view as? MKMapView else { return }
        let point = gesture.location(in: mapView)
        let now = ProcessInfo.processInfo.systemUptime

        switch gesture.state {
        case .began:
            // Reset tracking state.
            lastMovementPoint = point
            lastMovementTime = now
            lastUpdateTime = now
            currentVelocity = 0

            let result = hitDetector.findElement(
                at: point,
                in: mapView,
                elements: elements,
                anchors: anchors,
                velocity: currentVelocity
            )

            if let result = result {
                activeElement = result.element
                activeTouchType = result.touchType
                parent.feedbackPolicy.onEnter(element: result.element, touchType: result.touchType)
            }

        case .changed:
            // Calculate velocity.
            if let lastPoint = lastMovementPoint {
                let dt = now - lastMovementTime
                if dt > 0 {
                    let dist = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
                    currentVelocity = CGFloat(dist / dt)
                }
            }
            lastMovementPoint = point
            lastMovementTime = now

            // Throttle updates.
            guard now - lastUpdateTime >= parent.hitDetection.updateThreshold else { return }
            lastUpdateTime = now

            let result = hitDetector.findElement(
                at: point,
                in: mapView,
                elements: elements,
                anchors: anchors,
                velocity: currentVelocity
            )

            if let newResult = result {
                if let current = activeElement, current.id == newResult.element.id {
                    // Same element: send continue.
                    parent.feedbackPolicy.onContinue(
                        element: newResult.element,
                        touchType: newResult.touchType
                    )
                } else {
                    // Different element: exit old, enter new.
                    if let current = activeElement {
                        parent.feedbackPolicy.onExit(element: current)
                    }
                    activeElement = newResult.element
                    activeTouchType = newResult.touchType
                    parent.feedbackPolicy.onEnter(
                        element: newResult.element,
                        touchType: newResult.touchType
                    )
                }
            } else {
                // No element under finger: exit current if any.
                if let current = activeElement {
                    parent.feedbackPolicy.onExit(element: current)
                    activeElement = nil
                    activeTouchType = nil
                }
            }

        case .ended, .cancelled:
            if let current = activeElement {
                parent.feedbackPolicy.onExit(element: current)
            }
            parent.feedbackPolicy.stopAll()

            activeElement = nil
            activeTouchType = nil
            lastMovementPoint = nil
            currentVelocity = 0

        default:
            break
        }
    }

    // MARK: - Three-finger swipe handler

    @objc func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard parent.configuration.isVoiceOverBackGestureEnabled else { return }
        parent.onBackGesture?()
    }

    // MARK: - Three-finger pan handler

    @objc func handleThreeFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard parent.configuration.isVoiceOverBackGestureEnabled else { return }

        if gesture.state == .ended {
            guard let view = gesture.view else { return }
            let velocity = gesture.velocity(in: view)

            // Detect a rightward swipe with significant horizontal velocity.
            if velocity.x > 500 && abs(velocity.y) < abs(velocity.x) {
                parent.onBackGesture?()
            }
        }
    }
}
