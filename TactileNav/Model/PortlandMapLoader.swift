//
//  PortlandMapLoader.swift
//  TactileNav
//
//  Loads the Congress Square map + overlays. The Level-1 base map is parsed by the
//  TactileMapKit package (`TactileMapDocument.load`) and adapted by `CongressSquareAdapter`.
//  APS + traffic overlays are decoded from their own real-schema JSON files. Level-2
//  intersection detail is generated procedurally from the real bearings of the streets
//  that meet at the chosen intersection (no per-intersection files to maintain).
//

import Foundation
import CoreLocation
import TactileMapCore

enum PortlandMapLoader {

    // MARK: - Level 1 (real OSM base map, via the package)

    static func loadLevel1() -> CongressSquareAdapter.Result {
        guard let doc = try? TactileMapDocument.load(from: "congress_square", bundle: .main) else {
            return CongressSquareAdapter.Result(corridors: [], intersections: [], landmarks: [])
        }
        return CongressSquareAdapter.convert(doc)
    }

    // MARK: - Traffic + APS overlays

    static func loadTraffic() -> (segments: [PortlandTrafficSegment],
                                  intersections: [PortlandTrafficIntersection]) {
        guard let obj = loadJSON("portland_traffic") else { return ([], []) }
        var segments: [PortlandTrafficSegment] = []
        var intersections: [PortlandTrafficIntersection] = []
        if let arr = obj["road_segments"] {
            segments = decode([PortlandTrafficSegment].self, from: arr) ?? []
        }
        if let arr = obj["intersections"] {
            intersections = decode([PortlandTrafficIntersection].self, from: arr) ?? []
        }
        return (segments, intersections)
    }

    static func loadAPS() -> [PortlandAPS] {
        guard let obj = loadJSON("portland_aps"), let arr = obj["aps_locations"] else { return [] }
        return decode([PortlandAPS].self, from: arr) ?? []
    }

    // MARK: - Level 2 (procedural intersection detail)

    /// Builds a zoomed, direction-faithful crossing view for one intersection from the
    /// real bearings of the streets that meet there: one road leg per street, flanking
    /// sidewalks, and a marked crosswalk across each leg sized to the real crossing width.
    static func generateIntersectionDetail(for intersection: PortlandIntersection,
                                           allCorridors: [PortlandCorridor],
                                           segments: [PortlandTrafficSegment]) -> [PortlandMapFeature] {
        let center = intersection.coordinate
        let legLengthM = 45.0
        let crosswalkOutM = 20.0

        // Real bearings of the streets radiating from this intersection.
        var legs: [(bearing: Double, name: String, crossingM: Double)] = []
        for c in allCorridors {
            let coords = c.getCoordinates()
            // find the vertex nearest the intersection centre
            guard let (idx, d) = coords.enumerated()
                .map({ ($0.offset, haversine(center, $0.element)) })
                .min(by: { $0.1 < $1.1 }), d < 25 else { continue }
            // bearing toward the neighbour vertex away from centre
            let neighbour = coords[idx == 0 ? min(1, coords.count - 1) : idx - 1]
            let far = coords[idx == coords.count - 1 ? max(0, coords.count - 2) : idx + 1]
            let outward = haversine(center, far) >= haversine(center, neighbour) ? far : neighbour
            let b = bearing(from: center, to: outward)
            // de-dup near-parallel legs of the same street
            if legs.contains(where: { abs(angleDelta($0.bearing, b)) < 20 && $0.name == c.featureName }) { continue }
            legs.append((b, c.featureName, c.crossingDistanceM))
        }
        if legs.count < 2 {
            legs = [(0, "North", 9.9), (90, "East", 9.9), (180, "South", 9.9), (270, "West", 9.9)]
        }

        var features: [PortlandMapFeature] = []
        for (i, leg) in legs.enumerated() {
            let end = destination(from: center, distanceM: legLengthM, bearing: leg.bearing)
            features.append(PortlandCorridor(
                id: "\(intersection.featureId)-leg\(i)", name: leg.name, level: 2,
                accessible: true, coordinates: [center, end],
                crossingDistanceM: leg.crossingM))

            // flanking sidewalks (parallel offset either side of the leg)
            let halfRoad = 6.5
            for sign in [1.0, -1.0] {
                let a = destination(from: center, distanceM: halfRoad, bearing: leg.bearing + 90 * sign)
                let b = destination(from: end, distanceM: halfRoad, bearing: leg.bearing + 90 * sign)
                features.append(PortlandSidewalk(
                    id: "\(intersection.featureId)-sw\(i)-\(sign > 0 ? "r" : "l")",
                    name: "\(leg.name) sidewalk", level: 2, coordinates: [a, b]))
            }

            // crosswalk across the leg, sized to the real crossing width
            let mid = destination(from: center, distanceM: crosswalkOutM, bearing: leg.bearing)
            let cwA = destination(from: mid, distanceM: leg.crossingM / 2, bearing: leg.bearing + 90)
            let cwB = destination(from: mid, distanceM: leg.crossingM / 2, bearing: leg.bearing - 90)
            features.append(PortlandCrosswalk(
                id: "\(intersection.featureId)-cw\(i)",
                name: "\(leg.name) crosswalk, \(Int(leg.crossingM.rounded())) meters wide",
                level: 2, coordinates: [cwA, cwB]))
        }

        features.append(PortlandIntersection(
            id: intersection.featureId, name: intersection.featureName, level: 2,
            coordinate: center, ways: legs.count,
            signalized: intersection.signalized, streets: intersection.streets))
        return features
    }

    // MARK: - Geodesic helpers (metric offsets on the local map)

    private static func destination(from c: CLLocationCoordinate2D,
                                    distanceM: Double, bearing deg: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let br = deg * .pi / 180, lat1 = c.latitude * .pi / 180, lon1 = c.longitude * .pi / 180
        let dr = distanceM / R
        let lat2 = asin(sin(lat1) * cos(dr) + cos(lat1) * sin(dr) * cos(br))
        let lon2 = lon1 + atan2(sin(br) * sin(dr) * cos(lat1), cos(dr) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    private static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi).truncatingRemainder(dividingBy: 360)
    }

    private static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat/2) * sin(dLat/2) + cos(a.latitude * .pi/180) * cos(b.latitude * .pi/180) * sin(dLon/2) * sin(dLon/2)
        return 2 * R * asin(min(1, sqrt(h)))
    }

    private static func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }; if d < -180 { d += 360 }
        return d
    }

    // MARK: - JSON

    private static func loadJSON(_ name: String) -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func decode<T: Decodable>(_ type: T.Type, from any: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
