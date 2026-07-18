import Foundation
import CoreGraphics

// MARK: - DepartureDirection

/// Cardinal direction from a reference point (e.g., an intersection).
public enum DepartureDirection: String, Codable, Sendable, Hashable {
    /// Toward the top of the screen (decreasing Y in screen coordinates).
    case up
    /// Toward the bottom of the screen (increasing Y in screen coordinates).
    case down
    /// Toward the left of the screen (decreasing X).
    case left
    /// Toward the right of the screen (increasing X).
    case right
}

// MARK: - DepartureZone

/// A directional region adjacent to a reference point (typically an intersection)
/// that detects when a user's finger moves away in a specific direction.
///
/// Use departure zones to trigger corridor announcements when a user leaves
/// an intersection. For example, "80 foot hallway" when the finger moves
/// right from a corner.
///
/// Configure zones per-map by specifying which intersections have which
/// departure directions.
///
/// ```swift
/// let zone = DepartureZone(
///     referenceId: "i1",
///     direction: .right,
///     corridorId: "c1",
///     announcement: "80 foot hallway",
///     minDistance: 25,
///     maxDistance: 100
/// )
///
/// if zone.contains(point: touchPoint, referenceCenter: intersectionCenter) {
///     audioEngine.speak(zone.announcement)
/// }
/// ```
public struct DepartureZone: Sendable, Hashable {

    /// The ID of the reference element (usually an intersection).
    public let referenceId: String

    /// Which direction from the reference this zone covers.
    public let direction: DepartureDirection

    /// The corridor ID this zone leads to (for context in announcements).
    public let corridorId: String

    /// The text to announce when the user enters this zone
    /// (e.g. "80 foot hallway").
    public let announcement: String

    /// Minimum distance (in screen points) from the reference center
    /// before the zone activates. Prevents triggering while still
    /// on the intersection.
    public let minDistance: CGFloat

    /// Maximum distance (in screen points) from the reference center.
    /// Beyond this the zone is no longer active.
    public let maxDistance: CGFloat

    // MARK: - Initializer

    public init(
        referenceId: String,
        direction: DepartureDirection,
        corridorId: String,
        announcement: String,
        minDistance: CGFloat = 25,
        maxDistance: CGFloat = 100
    ) {
        self.referenceId = referenceId
        self.direction = direction
        self.corridorId = corridorId
        self.announcement = announcement
        self.minDistance = minDistance
        self.maxDistance = maxDistance
    }

    // MARK: - Hit testing

    /// Checks whether a touch point falls within this departure zone.
    ///
    /// The point must be:
    /// 1. Between `minDistance` and `maxDistance` from `referenceCenter`.
    /// 2. Moving primarily in the zone's `direction` (the dominant axis
    ///    component must exceed the other).
    ///
    /// - Parameters:
    ///   - point: The touch location in screen coordinates.
    ///   - referenceCenter: The intersection's center in screen coordinates.
    /// - Returns: `true` if the point is inside this zone.
    public func contains(point: CGPoint, referenceCenter: CGPoint) -> Bool {
        let dx = point.x - referenceCenter.x
        let dy = point.y - referenceCenter.y
        let distance = sqrt(dx * dx + dy * dy)

        // Must be within distance range
        guard distance >= minDistance && distance <= maxDistance else {
            return false
        }

        // Must be in the correct direction (dominant axis)
        switch direction {
        case .up:
            return dy < 0 && abs(dy) > abs(dx)
        case .down:
            return dy > 0 && abs(dy) > abs(dx)
        case .left:
            return dx < 0 && abs(dx) > abs(dy)
        case .right:
            return dx > 0 && abs(dx) > abs(dy)
        }
    }
}

// MARK: - DepartureZone builder helpers

extension DepartureZone {

    /// Creates departure zones for an intersection based on its connected corridors.
    ///
    /// This is a convenience for building zones from a ``MapElement`` intersection
    /// and its connected corridor elements. You provide the corridor lengths
    /// (in real-world units) and it generates appropriately labeled zones.
    ///
    /// - Parameters:
    ///   - intersection: The intersection element.
    ///   - corridors: Array of (corridorId, direction, lengthDescription) tuples.
    ///   - minDistance: Minimum activation distance. Default 25 pts.
    ///   - maxDistance: Maximum activation distance. Default 100 pts.
    /// - Returns: Array of departure zones for this intersection.
    public static func zones(
        for intersectionId: String,
        corridors: [(corridorId: String, direction: DepartureDirection, lengthDescription: String)],
        minDistance: CGFloat = 25,
        maxDistance: CGFloat = 100
    ) -> [DepartureZone] {
        corridors.map { corridor in
            DepartureZone(
                referenceId: intersectionId,
                direction: corridor.direction,
                corridorId: corridor.corridorId,
                announcement: corridor.lengthDescription,
                minDistance: minDistance,
                maxDistance: maxDistance
            )
        }
    }
}
