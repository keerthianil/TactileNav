//
//  RTMMapFeedbackController.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  The "what is the dot touching, and what should the phone do about it?" brain.
//  Each time the dot moves, the map calls `update(at:)`. This file figures out the
//  closest thing under the dot and makes the phone buzz and/or speak accordingly,
//  using the TactileMapKit haptic + speech engines.
//
//  THE RULES
//   • Priority when several things are nearby: places (POIs) > intersections > streets.
//   • Feedback fires once when the dot ENTERS a new thing (not continuously), so it
//     doesn't repeat over and over while you sit on the same street.
//   • Streets buzz; intersections pulse; places pulse + speak their name.
//
//  "ON YOUR LEFT / RIGHT" for places
//  We figure out which side a place is on ahead of time (is the building left or
//  right of the path it sits next to?). Then, when you walk past it, we flip that
//  left/right if you happen to be going the opposite way down the path. This is
//  steadier than guessing the side from your finger's exact direction each instant.
//
//  Also has two helpers the map uses: `snappedToPath` (keep the dot glued to a path)
//  and `nearestPointOnPath` (where to anchor a place's pin on the path).
//

import Foundation
import CoreLocation
import TactileMapCore
import TactileMapFeedback
import TactileMapLogging

@MainActor
final class RTMMapFeedbackController {

    // MARK: - Data

    private let streets: [RTMDiscoveredStreet]
    private let intersections: [RTMDiscoveredIntersection]

    /// Each POI snapped to its on-path anchor, with the precomputed geometric side
    /// and the bearing of the path segment it anchored to (so we can flip the side
    /// for the user's direction of travel).
    private struct AnchoredPOI {
        let poi: RTMDiscoveredPOI
        let anchor: CLLocationCoordinate2D
        let geometricSide: String   // "left"/"right" relative to the segment's drawn direction
        let segmentBearing: Double  // radians, clockwise from north
    }
    private let anchoredPOIs: [AnchoredPOI]

    // MARK: - Engines (from TactileMapKit)

    private let haptics: HapticEngine
    private let audio: SpatialAudioEngine

    // MARK: - Logging (CSV touch trace)

    private let logger: CSVTouchLogger
    private let sessionStart = Date()

    // MARK: - State

    /// Id of the feature the cursor is on, so we only fire on enter.
    private var activeID: String?

    // MARK: - Detection radii (meters)

    private let poiRadius: CLLocationDistance = 18
    private let intersectionRadius: CLLocationDistance = 20
    private let streetRadius: CLLocationDistance = 12

    // MARK: - Init

    init(
        streets: [RTMDiscoveredStreet],
        intersections: [RTMDiscoveredIntersection],
        pois: [RTMDiscoveredPOI],
        haptics: HapticEngine? = nil,
        audio: SpatialAudioEngine? = nil
    ) {
        self.streets = streets
        self.intersections = intersections
        self.anchoredPOIs = pois.map { poi in
            Self.anchorPOI(poi, in: streets)
        }
        self.haptics = haptics ?? CoreHapticsEngine()
        self.audio = audio ?? AVSpatialAudioEngine()

        self.logger = CSVTouchLogger(fileNameGenerator: { meta in
            let name = meta["sessionName"] ?? "RouxTactileExplorer"
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd_HHmmss"
            return "\(name)_\(df.string(from: Date()))"
        })
        logger.startSession(metadata: ["sessionName": "RouxTactileExplorer"])
    }

    /// Ends the CSV session. Called when the map view is torn down.
    func endLog() {
        logger.endSession()
    }

    // MARK: - Cursor updates

    /// Called as the cursor moves. Resolves the feature under the cursor and, on a
    /// change, delivers haptic + spoken feedback. `heading` is the direction of
    /// travel (radians, 0 = north, clockwise) used only to orient a place's side.
    func update(at coordinate: CLLocationCoordinate2D, heading: CGFloat?) {
        guard let hit = nearestFeature(to: coordinate) else {
            if activeID != nil {
                haptics.stopAll()
                activeID = nil
            }
            return
        }

        guard hit.id != activeID else { return }
        activeID = hit.id
        logEntry(hit, at: coordinate)

        haptics.stopAll()
        switch hit.kind {
        case .street(let roadType):
            haptics.start(pattern: streetPattern(for: roadType))
        case .intersection:
            haptics.start(pattern: .intersectionPulse)
        case .poi:
            haptics.start(pattern: .landmarkFastPulse)
        }

        speak(hit, heading: heading)
    }

    /// Streets/intersections speak their name; places add a side relative to travel.
    private func speak(_ hit: Hit, heading: CGFloat?) {
        guard let name = hit.spokenName else { return }
        if case .poi = hit.kind, let context = hit.sideContext {
            let side = resolvedSide(context, heading: heading)
            audio.speak("\(name), on your \(side)")
        } else {
            audio.speak(name)
        }
    }

    /// Called when the drag ends — silence everything.
    func stop() {
        haptics.stopAll()
        activeID = nil
    }

    /// Logs one CSV row each time the cursor enters a new feature.
    private func logEntry(_ hit: Hit, at coordinate: CLLocationCoordinate2D) {
        let type: TactileElementType?
        switch hit.kind {
        case .street:       type = .corridor
        case .intersection: type = .intersection
        case .poi:          type = .landmark
        }
        let event = TouchEvent(
            timestamp: Date(),
            sessionElapsed: Date().timeIntervalSince(sessionStart),
            eventType: .touchMove,
            elementName: hit.spokenName ?? "unknown",
            elementType: type,
            touchPoint: CGPoint(x: coordinate.longitude, y: coordinate.latitude),
            custom: [
                "lat": String(format: "%.6f", coordinate.latitude),
                "lon": String(format: "%.6f", coordinate.longitude)
            ]
        )
        _ = logger.logEvent(event)
    }

    // MARK: - Snap to path

    /// Closest point lying ON any path to `coordinate`. If `maxDistance` is given,
    /// returns nil when the nearest path is farther than that — so the caller can
    /// let the dot follow the finger freely instead of teleporting onto a path.
    func snappedToPath(near coordinate: CLLocationCoordinate2D, within maxDistance: CLLocationDistance? = nil) -> CLLocationCoordinate2D? {
        guard let anchor = Self.nearestPathAnchor(to: coordinate, in: streets) else { return nil }
        if let maxDistance, meters(from: coordinate, to: anchor.point) > maxDistance {
            return nil
        }
        return anchor.point
    }

    /// The point on the nearest path segment to `coordinate`, plus that segment's
    /// endpoints. Shared by cursor snapping, POI anchoring, and (via
    /// `nearestPointOnPath`) the marker placement in RTMLiveMapView, so everything
    /// agrees on where the paths are.
    struct PathAnchor {
        let point: CLLocationCoordinate2D
        let segmentStart: CLLocationCoordinate2D
        let segmentEnd: CLLocationCoordinate2D
    }

    static func nearestPathAnchor(to coordinate: CLLocationCoordinate2D, in streets: [RTMDiscoveredStreet]) -> PathAnchor? {
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(coordinate.latitude * .pi / 180)

        var best: PathAnchor?
        var bestDistanceSq = Double.greatestFiniteMagnitude

        for street in streets where street.coordinates.count >= 2 {
            let pts = street.coordinates
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let ax = (a.longitude - coordinate.longitude) * metersPerDegLon
                let ay = (a.latitude - coordinate.latitude) * metersPerDegLat
                let bx = (b.longitude - coordinate.longitude) * metersPerDegLon
                let by = (b.latitude - coordinate.latitude) * metersPerDegLat

                let abx = bx - ax, aby = by - ay
                let lengthSq = abx * abx + aby * aby
                let t = lengthSq > 0 ? max(0, min(1, -(ax * abx + ay * aby) / lengthSq)) : 0
                let px = ax + t * abx, py = ay + t * aby
                let distSq = px * px + py * py

                if distSq < bestDistanceSq {
                    bestDistanceSq = distSq
                    let point = CLLocationCoordinate2D(
                        latitude: a.latitude + t * (b.latitude - a.latitude),
                        longitude: a.longitude + t * (b.longitude - a.longitude)
                    )
                    best = PathAnchor(point: point, segmentStart: a, segmentEnd: b)
                }
            }
        }
        return best
    }

    /// Convenience for callers that only need the snapped point (e.g. marker placement).
    static func nearestPointOnPath(to coordinate: CLLocationCoordinate2D, in streets: [RTMDiscoveredStreet]) -> CLLocationCoordinate2D? {
        nearestPathAnchor(to: coordinate, in: streets)?.point
    }

    // MARK: - POI anchoring + geometric side

    private static func anchorPOI(_ poi: RTMDiscoveredPOI, in streets: [RTMDiscoveredStreet]) -> AnchoredPOI {
        guard let anchor = nearestPathAnchor(to: poi.coordinate, in: streets) else {
            return AnchoredPOI(poi: poi, anchor: poi.coordinate, geometricSide: "right", segmentBearing: 0)
        }

        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(anchor.point.latitude * .pi / 180)

        // Segment direction (drawn order) and the vector from the anchor to the POI,
        // both in local meters with x = east, y = north.
        let dirEast = (anchor.segmentEnd.longitude - anchor.segmentStart.longitude) * metersPerDegLon
        let dirNorth = (anchor.segmentEnd.latitude - anchor.segmentStart.latitude) * metersPerDegLat
        let poiEast = (poi.coordinate.longitude - anchor.point.longitude) * metersPerDegLon
        let poiNorth = (poi.coordinate.latitude - anchor.point.latitude) * metersPerDegLat

        // Cross product z: > 0 means the POI is to the LEFT of the drawn direction
        // (standard math axes, y up). Tie → default right.
        let cross = dirEast * poiNorth - dirNorth * poiEast
        let side = cross > 0 ? "left" : "right"
        let bearing = atan2(dirEast, dirNorth)  // clockwise from north

        return AnchoredPOI(poi: poi, anchor: anchor.point, geometricSide: side, segmentBearing: bearing)
    }

    private struct SideContext {
        let geometricSide: String
        let segmentBearing: Double
    }

    /// The geometric side, flipped when the user travels against the segment's drawn
    /// direction. With no heading (standing still), we report the geometric side as-is.
    private func resolvedSide(_ context: SideContext, heading: CGFloat?) -> String {
        guard let heading else { return context.geometricSide }
        // cos(angle between travel and segment) ≥ 0 → travelling in the drawn direction.
        let forward = cos(Double(heading) - context.segmentBearing) >= 0
        if forward { return context.geometricSide }
        return context.geometricSide == "left" ? "right" : "left"
    }

    // MARK: - Hit detection

    private struct Hit {
        enum Kind {
            case street(RTMRoadType)
            case intersection
            case poi(RTMPOICategory)
        }
        let id: String
        let kind: Kind
        let spokenName: String?
        /// Side info for POIs (nil otherwise).
        let sideContext: SideContext?
    }

    /// Highest-priority feature within range: POI → intersection → street.
    private func nearestFeature(to coordinate: CLLocationCoordinate2D) -> Hit? {
        // 1. POIs — detected against their on-path anchor.
        if let match = closest(anchoredPOIs, to: coordinate, within: poiRadius, point: { $0.anchor }) {
            return Hit(
                id: "poi_\(match.poi.id)",
                kind: .poi(match.poi.category),
                spokenName: match.poi.name,
                sideContext: SideContext(geometricSide: match.geometricSide, segmentBearing: match.segmentBearing)
            )
        }

        // 2. Intersections.
        if let intersection = closest(intersections, to: coordinate, within: intersectionRadius, point: \.coordinate) {
            return Hit(id: "int_\(intersection.id)", kind: .intersection, spokenName: intersection.name, sideContext: nil)
        }

        // 3. Streets (nearest point on any segment).
        var bestStreet: RTMDiscoveredStreet?
        var bestDistance = streetRadius
        for street in streets where street.coordinates.count >= 2 {
            let distance = distanceToPolyline(street.coordinates, from: coordinate)
            if distance <= bestDistance {
                bestDistance = distance
                bestStreet = street
            }
        }
        if let street = bestStreet {
            return Hit(id: "street_\(street.id)", kind: .street(street.roadType), spokenName: street.name, sideContext: nil)
        }

        return nil
    }

    /// Closest element whose point is within `radius` of `coordinate`, else nil.
    private func closest<T>(
        _ elements: [T],
        to coordinate: CLLocationCoordinate2D,
        within radius: CLLocationDistance,
        point: (T) -> CLLocationCoordinate2D
    ) -> T? {
        var best: T?
        var bestDistance = radius
        for element in elements {
            let distance = meters(from: coordinate, to: point(element))
            if distance <= bestDistance {
                bestDistance = distance
                best = element
            }
        }
        return best
    }

    // MARK: - Haptic pattern per road type
    //
    // Primary roads buzz strong, local streets medium, trails/paths light — so the
    // type of way is felt, not just its presence.
    private func streetPattern(for roadType: RTMRoadType) -> HapticPattern {
        switch roadType {
        case .primary:
            return HapticPattern(intensity: 1.0, sharpness: 0.4, mode: .continuous(duration: 100))
        case .residential, .service:
            return HapticPattern(intensity: 0.7, sharpness: 0.3, mode: .continuous(duration: 100))
        case .footway, .path, .cycleway, .steps:
            return HapticPattern(intensity: 0.45, sharpness: 0.3, mode: .continuous(duration: 100))
        }
    }

    // MARK: - Geometry (planar meters, accurate at neighborhood scale)

    private func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * metersPerDegLon
        let dy = (b.latitude - a.latitude) * metersPerDegLat
        return (dx * dx + dy * dy).squareRoot()
    }

    private func distanceToPolyline(_ polyline: [CLLocationCoordinate2D], from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(coordinate.latitude * .pi / 180)
        func local(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - coordinate.longitude) * metersPerDegLon,
             (c.latitude - coordinate.latitude) * metersPerDegLat)
        }
        var best = CLLocationDistance.greatestFiniteMagnitude
        for i in 0..<(polyline.count - 1) {
            let a = local(polyline[i])
            let b = local(polyline[i + 1])
            best = min(best, distanceFromOriginToSegment(a: a, b: b))
        }
        return best
    }

    private func distanceFromOriginToSegment(a: (x: Double, y: Double), b: (x: Double, y: Double)) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSq = abx * abx + aby * aby
        let t = lengthSq > 0 ? max(0, min(1, -(a.x * abx + a.y * aby) / lengthSq)) : 0
        let px = a.x + t * abx, py = a.y + t * aby
        return (px * px + py * py).squareRoot()
    }
}
