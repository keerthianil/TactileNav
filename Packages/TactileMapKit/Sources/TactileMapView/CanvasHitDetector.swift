import Foundation
import TactileMapCore
import TactileMapFeedback

/// Performs hit detection against map elements using screen-space distances.
///
/// This is the Canvas-mode equivalent of ``HitDetector``. It works directly
/// in screen coordinates using a ``CanvasMapTransform``, without requiring
/// an MKMapView for coordinate conversion.
///
/// Priority order: anchor points > landmarks > intersections > corridors.
/// Corridor hit radius is velocity-adaptive, growing as the user's finger
/// moves faster to accommodate imprecise swipe gestures.
struct CanvasHitDetector {

    let config: HitDetectionConfig

    // MARK: - Public API

    /// Find the highest-priority element at a touch point.
    ///
    /// Priority: anchor points > landmarks > intersections > corridors.
    func findElement(
        at point: CGPoint,
        elements: [MapElement],
        transform t: CanvasMapTransform,
        velocity: CGFloat,
        anchorCenter: (_ feature: MapElement, _ screenPt: CGPoint) -> CGPoint
    ) -> (element: MapElement, touchType: TouchType)? {

        let anchorR   = config.anchorHitRadiusPts
        let pointR    = config.pointHitRadiusPts
        let corridorR = config.corridorBaseRadiusPts +
                        min(velocity / config.velocityDivisor, config.velocityBonusMax)

        // 1. Anchor dots (highest priority).
        for f in elements where f.elementType == .landmark {
            guard case .point(let c) = f.geometry else { continue }
            let anchor = anchorCenter(f, t.apply(c))
            if dist(point, anchor) <= anchorR {
                return (f, .anchor)
            }
        }

        // 2. Point elements — landmarks first, then intersections.
        var bestLandmark:     (MapElement, CGFloat)?
        var bestIntersection: (MapElement, CGFloat)?

        for f in elements {
            guard case .point(let c) = f.geometry else { continue }
            let screenPt = t.apply(c)
            let d = dist(point, screenPt)
            guard d <= pointR else { continue }

            if f.elementType == .landmark {
                if bestLandmark == nil || d < bestLandmark!.1 {
                    bestLandmark = (f, d)
                }
            } else if f.elementType == .intersection {
                if bestIntersection == nil || d < bestIntersection!.1 {
                    bestIntersection = (f, d)
                }
            }
        }

        if let (lm, _) = bestLandmark     { return (lm, .direct) }
        if let (ix, _) = bestIntersection  { return (ix, .direct) }

        // 3. Corridors (lineString) with velocity-adaptive radius.
        var bestCorridor: (MapElement, CGFloat)?

        for f in elements where f.elementType == .corridor {
            guard case .lineString(let pts) = f.geometry, pts.count >= 2 else { continue }
            for i in 0..<(pts.count - 1) {
                let d = distToSegment(point, t.apply(pts[i]), t.apply(pts[i + 1]))
                if d <= corridorR {
                    if bestCorridor == nil || d < bestCorridor!.1 {
                        bestCorridor = (f, d)
                    }
                }
            }
        }

        if let (cor, _) = bestCorridor { return (cor, .direct) }

        return nil
    }

    // MARK: - Geometry helpers

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Perpendicular distance from a point to a line segment.
    private func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return dist(p, a) }
        let u = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return dist(p, CGPoint(x: a.x + u * dx, y: a.y + u * dy))
    }
}
