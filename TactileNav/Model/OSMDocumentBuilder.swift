//
//  OSMDocumentBuilder.swift
//  TactileNav
//
//  Turning a live OpenStreetMap answer into the same document the bundled maps are.
//
//  This is the offline builder's logic, on the device: project to local metres, classify each
//  way, drop the unnamed roads, simplify, clip to the box, and find the junctions from node
//  topology. Deliberately the *same* logic rather than a lighter version of it — a map fetched
//  for a postcode has to behave exactly like the one that ships with the app, or everything
//  downstream that was tuned against the shipped one is tuned against nothing.
//
//  The output is a real `TactileMapDocument`, so `StreetMap.build` consumes it unchanged, and
//  it can be written to disk in the same JSON the bundled maps use — which is what makes a
//  place, once fetched, work offline ever after.
//

import CoreGraphics
import Foundation
import TactileMapCore

// MARK: - The OpenStreetMap vocabulary

nonisolated enum OSMTags {

    /// Drivable classes kept. `service` is deliberately not one of them: it is a category of
    /// its own here, because it is overwhelmingly car park aisles and back lanes and a reader
    /// should be able to switch the thicket off.
    static let roadClasses = [
        "motorway", "trunk", "primary", "secondary", "tertiary",
        "residential", "unclassified", "living_street",
        "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
    ]

    static let railwayClasses = ["rail", "light_rail", "tram", "subway", "narrow_gauge"]

    /// Lanes by class, for the great majority of ways that carry no `lanes` tag. A
    /// classification rather than a measurement, and every road records which of the two it got.
    static let lanesByClass: [String: Int] = [
        "motorway": 4, "trunk": 4, "primary": 4, "secondary": 3, "tertiary": 2,
        "residential": 2, "unclassified": 2, "living_street": 1,
        "motorway_link": 1, "trunk_link": 1, "primary_link": 1,
        "secondary_link": 1, "tertiary_link": 1,
    ]

    static let metersPerDegreeLatitude = 111_320.0

    /// Ways are cut to the box, but with a margin, so a line does not stop dead exactly at the
    /// edge of what was fetched.
    static let clipMarginMeters = 25.0

    /// Douglas–Peucker tolerance. A metre is far below anything a finger can resolve at these
    /// scales and takes a third of the vertices out.
    static let simplifyEpsilonMeters = 1.0
}

// MARK: - Builder

nonisolated enum OSMDocumentBuilder {

    enum Failure: LocalizedError {
        case emptyArea

        var errorDescription: String? {
            switch self {
            case .emptyArea:
                return "There are no mapped streets here."
            }
        }
    }

    /// A square of ground, in degrees, around a point.
    struct Box: Sendable {
        let south, west, north, east: Double

        /// `halfSpanMeters` each way from the centre.
        init(centreLatitude: Double, centreLongitude: Double, halfSpanMeters: Double) {
            let dLat = halfSpanMeters / OSMTags.metersPerDegreeLatitude
            let dLon = halfSpanMeters
                / (OSMTags.metersPerDegreeLatitude * cos(centreLatitude * .pi / 180))
            south = centreLatitude - dLat
            north = centreLatitude + dLat
            west = centreLongitude - dLon
            east = centreLongitude + dLon
        }

        var metersPerDegreeLongitude: Double {
            OSMTags.metersPerDegreeLatitude * cos(((south + north) / 2) * .pi / 180)
        }

        /// Metres from the north-west corner, y growing south — the same planar space the
        /// bundled documents are in, so there is no projection left to do at runtime.
        func project(latitude: Double, longitude: Double) -> CGPoint {
            CGPoint(x: (longitude - west) * metersPerDegreeLongitude,
                    y: (north - latitude) * OSMTags.metersPerDegreeLatitude)
        }

        var width: Double { (east - west) * metersPerDegreeLongitude }
        var height: Double { (north - south) * OSMTags.metersPerDegreeLatitude }
    }

    // MARK: Building

    /// Parses an Overpass answer into a document ready for `StreetMap.build`.
    static func build(overpass data: Data, box: Box, name: String) throws -> TactileMapDocument {
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        let ways = answer.elements.filter { $0.type == "way" && ($0.geometry?.count ?? 0) >= 2 }

        var features: [MapElement] = []
        var lanesFromTag = 0
        var lanesFromClass = 0

        for way in ways {
            guard let geometry = way.geometry else { continue }
            let tags = way.tags ?? [:]
            guard let kind = classify(tags) else { continue }

            var custom: [String: String] = [:]
            let elementName: String

            switch kind {
            case .crosswalk:
                elementName = (tags["name"]?.trimmed).nonEmpty ?? "Crosswalk"
                if let markings = tags["crossing:markings"] { custom["crossing_markings"] = markings }
                if let control = tags["crossing"] { custom["crossing_control"] = control }
            case .path:
                elementName = (tags["name"]?.trimmed).nonEmpty ?? "Sidewalk"
                if let footway = tags["footway"] { custom["footway"] = footway }
            case .service:
                elementName = (tags["name"]?.trimmed).nonEmpty ?? "Service road"
                if let service = tags["service"] { custom["osm_service"] = service }
            case .railway:
                elementName = (tags["name"]?.trimmed).nonEmpty ?? "Railway"
                custom["osm_railway"] = tags["railway"] ?? "rail"
            case .road:
                // Unnamed roads are dropped — a line a finger can find but the map cannot name
                // is a dead end in the one channel that was supposed to explain it. Ramps are
                // the exception: they carry the grade separations that make a network make
                // sense and are almost never named.
                guard let roadName = roadName(tags) else { continue }
                elementName = roadName
                let (lanes, source) = laneCount(tags)
                if source == "osm" { lanesFromTag += 1 } else { lanesFromClass += 1 }
                custom["lanes"] = String(lanes)
                custom["lanes_source"] = source
                custom["osm_highway"] = tags["highway"] ?? ""
                if let oneway = tags["oneway"] { custom["oneway"] = oneway }
            }

            let projected = geometry.map { box.project(latitude: $0.lat, longitude: $0.lon) }
            for (index, run) in splitInsideBox(projected, box).enumerated() {
                let simplified = dropRepeats(simplify(run, OSMTags.simplifyEpsilonMeters))
                guard simplified.count >= 2, polylineLength(simplified) >= 1 else { continue }
                features.append(MapElement(
                    id: "\(kind.idPrefix)-\(way.id)\(index == 0 ? "" : "-\(index)")",
                    elementType: kind.elementType,
                    geometry: .lineString(simplified.map {
                        TactileCoordinate(x: rounded(Double($0.x)), y: rounded(Double($0.y)))
                    }),
                    properties: TactileProperties(
                        name: elementName,
                        category: tags["highway"] ?? kind.idPrefix,
                        isAccessible: true,
                        custom: custom)))
            }
        }

        features.append(contentsOf: intersections(in: ways, box: box))
        guard features.contains(where: { $0.elementType == .road }) else { throw Failure.emptyArea }
        features.sort { $0.id < $1.id }

        return TactileMapDocument(
            version: "2.0",
            bounds: TactileMapBounds(width: rounded(box.width), height: rounded(box.height)),
            features: features,
            metadata: TactileMapMetadata(
                name: name,
                scale: "1 unit = 1 meter",
                coordinateUnit: .meters,
                coordinateOrigin: "NW corner; y grows south",
                author: "OpenStreetMap contributors (ODbL)"))
    }

    // MARK: Classification

    private enum Kind {
        case crosswalk, path, service, railway, road

        var elementType: TactileElementType {
            switch self {
            case .crosswalk: return .crosswalk
            case .path: return .street
            case .service: return TactileElementType(rawValue: "service")
            case .railway: return TactileElementType(rawValue: "railway")
            case .road: return .road
            }
        }

        var idPrefix: String {
            switch self {
            case .crosswalk: return "c"
            case .path: return "s"
            case .service: return "v"
            case .railway: return "y"
            case .road: return "r"
            }
        }
    }

    /// First match wins, and the order matters: a marked crossing is tagged as a footway too, so
    /// it has to be recognised before footways are.
    private static func classify(_ tags: [String: String]) -> Kind? {
        let highway = tags["highway"] ?? ""
        if tags["footway"] == "crossing" { return .crosswalk }
        if highway == "footway" || highway == "pedestrian" || tags["footway"] == "sidewalk" {
            return .path
        }
        if highway == "service" { return .service }
        if let railway = tags["railway"], OSMTags.railwayClasses.contains(railway) { return .railway }
        if OSMTags.roadClasses.contains(highway) { return .road }
        return nil
    }

    private static func roadName(_ tags: [String: String]) -> String? {
        if let name = tags["name"]?.trimmed, !name.isEmpty { return name }
        guard (tags["highway"] ?? "").hasSuffix("_link") else { return nil }
        if let ref = tags["ref"]?.trimmed, !ref.isEmpty { return "\(ref) ramp" }
        return "Ramp"
    }

    private static func laneCount(_ tags: [String: String]) -> (Int, String) {
        if let raw = tags["lanes"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
           let value = Double(raw), Int(value) >= 1 {
            return (Int(value), "osm")
        }
        return (OSMTags.lanesByClass[tags["highway"] ?? ""] ?? 2, "class")
    }

    // MARK: Junctions

    /// Junctions straight from OpenStreetMap's node topology.
    ///
    /// Two ways that genuinely meet share a node; two that merely cross on a bridge do not — so
    /// sharing a node is both the real definition of a junction and what keeps grade
    /// separations out for free, with no bridge tag needed. A node shared only by ways carrying
    /// the *same* name is one street split into pieces, not a junction, so two distinct names
    /// are required.
    private static func intersections(in ways: [Answer.Element], box: Box) -> [MapElement] {
        struct Use {
            let name: String
            let index: Int
            let count: Int
            let points: [CGPoint]
        }

        var usesByNode: [Int: [Use]] = [:]
        for way in ways {
            let tags = way.tags ?? [:]
            guard OSMTags.roadClasses.contains(tags["highway"] ?? ""),
                  let name = roadName(tags),
                  let nodes = way.nodes, let geometry = way.geometry,
                  nodes.count == geometry.count else { continue }

            let projected = geometry.map { box.project(latitude: $0.lat, longitude: $0.lon) }
            for (index, node) in nodes.enumerated() {
                usesByNode[node, default: []].append(
                    Use(name: name, index: index, count: nodes.count, points: projected))
            }
        }

        var elements: [MapElement] = []
        let margin = OSMTags.clipMarginMeters

        for (node, uses) in usesByNode {
            let names = Set(uses.map(\.name)).sorted()
            guard names.count >= 2, let first = uses.first else { continue }

            let point = first.points[first.index]
            guard Double(point.x) >= -margin, Double(point.x) <= box.width + margin,
                  Double(point.y) >= -margin, Double(point.y) <= box.height + margin else { continue }

            // One leg per direction the roadway continues: a way ending here gives one, a way
            // passing through gives two.
            var legs: [(bearing: Double, name: String)] = []
            for use in uses {
                if use.index > 0 {
                    legs.append((bearing(from: point, to: use.points[use.index - 1]), use.name))
                }
                if use.index < use.count - 1 {
                    legs.append((bearing(from: point, to: use.points[use.index + 1]), use.name))
                }
            }
            legs.sort { $0.bearing == $1.bearing ? $0.name < $1.name : $0.bearing < $1.bearing }

            elements.append(MapElement(
                id: "x-\(node)",
                elementType: .intersection,
                geometry: .point(TactileCoordinate(x: rounded(Double(point.x)),
                                                   y: rounded(Double(point.y)))),
                properties: TactileProperties(
                    name: names.joined(separator: " and "),
                    category: "intersection",
                    isAccessible: true,
                    custom: [
                        "streets": names.joined(separator: "|"),
                        "legs": String(legs.count),
                        "leg_bearings": legs.map { String(format: "%.1f", $0.bearing) }
                            .joined(separator: "|"),
                        "leg_names": legs.map(\.name).joined(separator: "|"),
                    ])))
        }
        return elements
    }

    /// Compass bearing from one point to another. 0 is north, 90 east; y grows south, hence -dy.
    private static func bearing(from: CGPoint, to: CGPoint) -> Double {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        let degrees = atan2(dx, -dy) * 180 / .pi
        return degrees.truncatingRemainder(dividingBy: 360) < 0
            ? degrees.truncatingRemainder(dividingBy: 360) + 360
            : degrees.truncatingRemainder(dividingBy: 360)
    }

    // MARK: Geometry

    /// The runs of a way that lie inside the padded box. A way that leaves and comes back
    /// becomes two pieces rather than one with a line stretched across the gap.
    private static func splitInsideBox(_ points: [CGPoint], _ box: Box) -> [[CGPoint]] {
        let margin = OSMTags.clipMarginMeters
        func inside(_ point: CGPoint) -> Bool {
            Double(point.x) >= -margin && Double(point.x) <= box.width + margin
                && Double(point.y) >= -margin && Double(point.y) <= box.height + margin
        }
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for point in points {
            if inside(point) {
                current.append(point)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.filter { $0.count >= 2 }
    }

    /// Douglas–Peucker, iterative so a long way cannot blow the stack.
    private static func simplify(_ points: [CGPoint], _ epsilon: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var worst = 0.0
            var worstIndex = start
            for index in (start + 1)..<end {
                let distance = Double(distanceToSegment(points[index], points[start], points[end]))
                if distance > worst { worst = distance; worstIndex = index }
            }
            if worst > epsilon {
                keep[worstIndex] = true
                stack.append((start, worstIndex))
                stack.append((worstIndex, end))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    private static func dropRepeats(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, hypot(point.x - last.x, point.y - last.y) <= 1e-6 { continue }
            result.append(point)
        }
        return result
    }

    /// Two decimal places, matching the bundled documents — a centimetre, which is far finer
    /// than anything downstream can use and keeps a cached file from being needlessly large.
    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: Overpass JSON

    private struct Answer: Decodable {
        struct Element: Decodable {
            struct Vertex: Decodable { let lat: Double; let lon: Double }
            let type: String
            let id: Int
            let tags: [String: String]?
            let nodes: [Int]?
            let geometry: [Vertex]?
        }
        let elements: [Element]
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
