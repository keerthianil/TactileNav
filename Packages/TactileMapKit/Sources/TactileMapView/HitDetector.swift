import MapKit
import TactileMapCore
import TactileMapFeedback

/// The result of a hit test against the map's elements.
public struct HitTestResult {
    /// The element that was hit.
    public let element: any TactileMapElement

    /// Whether the touch was on the element directly or on an anchor point.
    public let touchType: TouchType

    /// The screen-space distance from the touch point to the element.
    public let distance: CGFloat

    public init(element: any TactileMapElement, touchType: TouchType, distance: CGFloat) {
        self.element = element
        self.touchType = touchType
        self.distance = distance
    }
}

/// Performs hit detection against map elements using screen-space distances.
///
/// Priority order: anchor points > landmarks > intersections > other points > lines.
/// Corridor hit radius is velocity-adaptive, growing as the user's finger
/// moves faster to accommodate imprecise swipe gestures.
public final class HitDetector {

    /// The configuration controlling hit radii and velocity adaptation.
    public let config: HitDetectionConfig

    /// The coordinate transform used to convert element coordinates to geographic coordinates.
    private let coordinateTransform: CoordinateTransform

    // MARK: - Initializer

    /// Creates a hit detector with the given configuration and coordinate transform.
    ///
    /// - Parameters:
    ///   - config: Hit detection configuration.
    ///   - coordinateTransform: Transform for converting element coordinates to CLLocationCoordinate2D.
    public init(config: HitDetectionConfig = .default, coordinateTransform: CoordinateTransform = .default) {
        self.config = config
        self.coordinateTransform = coordinateTransform
    }

    // MARK: - Public API

    /// Find the highest-priority element at a touch point.
    ///
    /// Priority: anchor points > landmarks > intersections > other points > lines > nothing.
    ///
    /// - Parameters:
    ///   - point: The touch location in the map view's coordinate space.
    ///   - mapView: The MKMapView used to convert geographic coordinates to screen points.
    ///   - elements: All map elements to test against.
    ///   - anchors: Anchor point annotations placed on corridors for landmarks.
    ///   - velocity: Current touch velocity (pts/s) for adaptive corridor radius.
    /// - Returns: The highest-priority hit result, or `nil` if no element was hit.
    public func findElement(
        at point: CGPoint,
        in mapView: MKMapView,
        elements: [any TactileMapElement],
        anchors: [AnchorAnnotation],
        velocity: CGFloat
    ) -> HitTestResult? {

        // 1. Check anchor points first (highest priority).
        for anchor in anchors {
            let anchorScreenPoint = mapView.convert(anchor.coordinate, toPointTo: mapView)
            let dist = hypot(point.x - anchorScreenPoint.x, point.y - anchorScreenPoint.y)
            if dist < config.anchorHitRadiusPts {
                if let matchingElement = elements.first(where: { $0.id == anchor.elementId }) {
                    return HitTestResult(element: matchingElement, touchType: .anchor, distance: dist)
                }
            }
        }

        // 2. Check point-type elements: landmarks > intersections > other points.
        var bestLandmark: HitTestResult?
        var bestIntersection: HitTestResult?
        var bestOtherPoint: HitTestResult?

        for element in elements {
            switch element.geometry {
            case .point(let coord):
                let clCoord = coordinateTransform.toCLCoordinate(coord)
                let screenPoint = mapView.convert(clCoord, toPointTo: mapView)
                let dist = hypot(point.x - screenPoint.x, point.y - screenPoint.y)

                if dist < config.pointHitRadiusPts {
                    let result = HitTestResult(element: element, touchType: .direct, distance: dist)
                    if element.elementType == .landmark {
                        if bestLandmark == nil || dist < bestLandmark!.distance {
                            bestLandmark = result
                        }
                    } else if element.elementType == .intersection {
                        if bestIntersection == nil || dist < bestIntersection!.distance {
                            bestIntersection = result
                        }
                    } else {
                        if bestOtherPoint == nil || dist < bestOtherPoint!.distance {
                            bestOtherPoint = result
                        }
                    }
                }

            case .lineString, .polygon:
                break
            }
        }

        if let landmark = bestLandmark {
            return landmark
        }
        if let intersection = bestIntersection {
            return intersection
        }
        if let otherPoint = bestOtherPoint {
            return otherPoint
        }

        // 3. Check line elements (any lineString geometry) with velocity-adaptive radius.
        let effectiveRadius = config.corridorBaseRadiusPts + min(velocity / config.velocityDivisor, config.velocityBonusMax)
        var bestLine: HitTestResult?

        for element in elements {
            switch element.geometry {
            case .lineString(let coords):
                let clCoords = coordinateTransform.toCLCoordinates(coords)
                let screenPoints = clCoords.map { mapView.convert($0, toPointTo: mapView) }

                for i in 0..<(screenPoints.count - 1) {
                    let dist = distanceFromPoint(point, toLineFrom: screenPoints[i], to: screenPoints[i + 1])
                    if dist < effectiveRadius {
                        if bestLine == nil || dist < bestLine!.distance {
                            bestLine = HitTestResult(element: element, touchType: .direct, distance: dist)
                        }
                    }
                }

            case .point, .polygon:
                break
            }
        }

        return bestLine
    }

    /// Check if a point is near a specific element.
    ///
    /// - Parameters:
    ///   - point: The touch location in the map view's coordinate space.
    ///   - element: The element to test against.
    ///   - mapView: The MKMapView for coordinate conversion.
    ///   - velocity: Current touch velocity (pts/s).
    /// - Returns: `true` if the point is within the hit radius of the element.
    public func isPointNear(
        _ point: CGPoint,
        element: any TactileMapElement,
        in mapView: MKMapView,
        velocity: CGFloat
    ) -> Bool {
        switch element.geometry {
        case .point(let coord):
            let clCoord = coordinateTransform.toCLCoordinate(coord)
            let screenPoint = mapView.convert(clCoord, toPointTo: mapView)
            let dist = hypot(point.x - screenPoint.x, point.y - screenPoint.y)
            return dist < config.pointHitRadiusPts

        case .lineString(let coords):
            let effectiveRadius = config.corridorBaseRadiusPts + min(velocity / config.velocityDivisor, config.velocityBonusMax)
            let clCoords = coordinateTransform.toCLCoordinates(coords)
            let screenPoints = clCoords.map { mapView.convert($0, toPointTo: mapView) }

            for i in 0..<(screenPoints.count - 1) {
                let dist = distanceFromPoint(point, toLineFrom: screenPoints[i], to: screenPoints[i + 1])
                if dist < effectiveRadius {
                    return true
                }
            }
            return false

        case .polygon(let coords):
            let clCoords = coordinateTransform.toCLCoordinates(coords)
            let screenPoints = clCoords.map { mapView.convert($0, toPointTo: mapView) }
            for i in 0..<(screenPoints.count - 1) {
                let dist = distanceFromPoint(point, toLineFrom: screenPoints[i], to: screenPoints[i + 1])
                if dist < config.pointHitRadiusPts {
                    return true
                }
            }
            return false
        }
    }

    /// Computes the perpendicular distance from a point to a line segment.
    ///
    /// - Parameters:
    ///   - point: The query point.
    ///   - start: The start of the line segment.
    ///   - end: The end of the line segment.
    /// - Returns: The minimum distance from the point to the closest location on the segment.
    public func distanceFromPoint(_ point: CGPoint, toLineFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        if lengthSquared == 0 {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))

        let projX = start.x + t * dx
        let projY = start.y + t * dy

        return hypot(point.x - projX, point.y - projY)
    }
}
