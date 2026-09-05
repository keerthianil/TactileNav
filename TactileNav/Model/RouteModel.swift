//
//  RouteModel.swift
//  TactileNav
//
//  A route for a study participant to walk, overlaid on the real street map.
//
//  Hand-authored, not computed: a route is a specific real walk someone actually takes, and the
//  streets and turns that make it up are a fact about that walk, not something to search for
//  over the road graph. So a route is just an ordered list of the real intersections it passes
//  through, plus the street used to get from each one to the next — the reference app's own
//  route files work the same way, hand-drawn rather than path-found.
//
//  What is *not* hand-authored is the geometry. The reference app hand-draws a polyline that has
//  to be kept in sync with its own map by hand; here the streets and junctions are already real,
//  loaded geometry, so a route's polyline is cut directly out of the roads it actually runs
//  along — see `RouteScene.build`.
//

import CoreGraphics
import Foundation

// MARK: - Authoring

/// One real intersection the route passes through, in order.
nonisolated struct RouteWaypointSpec {
    /// The streets that meet here — matched against `Intersection.streetNames`, not an id, since
    /// ids are assigned when junctions are computed and are not something to hand-author against.
    let streetNames: Set<String>
    /// The street the route takes from here to the *next* waypoint. `nil` on the last waypoint,
    /// which has nowhere further to go.
    let viaStreet: String?
}

/// The route for the in-person study: Custom House Street & Fore Street to Fore Street &
/// Union Street.
///
/// Confirmed against the real road network before being hand-fixed here — this is the shortest
/// path through the actual OpenStreetMap topology between the two named intersections, checked
/// against the walk it is standing in for rather than assumed from it.
///
/// **Shortened at both ends from the original Custom House–to–Center-and-Spring walk.** The
/// destination end: the streets beyond Union Street — Cross Street, Cotton Street, and
/// Center/Fore/Pleasant on the way to Center & Spring — have no sidewalk mapped anywhere near
/// them in this extract (the nearest real sidewalk to Center & Spring is 97 m away). The
/// departure end: the real sidewalk fragments right at Custom House Street & Fore Street do
/// not reach anywhere near close enough to the fragments at Pearl Street to be honestly
/// stitched together — every other block on this route connects within about 9 m of real
/// data; that one needed close to 30 m, nearly the width of the whole block, which is a gap
/// in the mapping, not a gap this app's job to quietly paper over. A pedestrian route has to
/// run on a pavement, not a road and not a guess, so both ends sit wherever the real pavement
/// data actually does rather than somewhere the walk would have to be invented to reach.
nonisolated enum ForeStreetStudyRoute {
    static let departureName = "Fore Street and Pearl Street"
    static let destinationName = "Fore Street and Union Street"

    static let waypoints: [RouteWaypointSpec] = [
        RouteWaypointSpec(streetNames: ["Fore Street", "Pearl Street"], viaStreet: "Fore Street"),
        RouteWaypointSpec(streetNames: ["Fore Street", "Silver Street"], viaStreet: "Fore Street"),
        RouteWaypointSpec(streetNames: ["Fore Street", "Market Street"], viaStreet: "Fore Street"),
        RouteWaypointSpec(streetNames: ["Fore Street", "Moulton Street"], viaStreet: "Fore Street"),
        RouteWaypointSpec(streetNames: ["Exchange Street", "Fore Street"], viaStreet: "Fore Street"),
        RouteWaypointSpec(streetNames: ["Fore Street", "Union Street"], viaStreet: nil),
    ]

    static func build(map: StreetMap) -> RouteScene? {
        RouteScene.build(waypoints: waypoints, departureName: departureName,
                         destinationName: destinationName, map: map)
    }
}

/// A route sourced from a walking-directions API's response, rather than hand-authored against
/// this map's own topology.
///
/// **This is the shape a future live routing call is expected to take**: a single real-world
/// polyline in latitude/longitude, no knowledge of this app's junctions or sidewalks baked in —
/// exactly what a GeoJSON `LineString` from a pedestrian routing API looks like. For now it
/// reads one bundled, already-downloaded GeoJSON file standing in for that response, so the
/// rendering and feedback path can be built and proven out before anything is actually calling
/// an API.
///
/// **What this does *not* promise, on purpose.** `ForeStreetStudyRoute`'s geometry is cut from
/// this app's own sidewalks and crossings, checked against real gaps in the mapping before
/// being trusted (see its own doc comment). A routing API's polyline carries no such guarantee
/// — whether it actually stayed on a pavement is a property of that API and that response, not
/// of this loader, which draws whatever real-world line it is given exactly where that line
/// really runs.
nonisolated enum GeoJSONRoute {

    private struct Document: Decodable {
        let geometry: Geometry
        struct Geometry: Decodable {
            let type: String
            let coordinates: [[Double]]
        }
    }

    /// Loads `resource`.geojson from the app bundle and places its line on `map`, or returns
    /// `nil` if the file is missing, is not a `LineString`, or `map` was built without the
    /// geographic bounding-box metadata `GeographicProjection` needs.
    static func build(resource: String, departureName: String, destinationName: String,
                      map: StreetMap) -> RouteScene? {
        guard let projection = map.geographicProjection,
              let url = Bundle.main.url(forResource: resource, withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.geometry.type == "LineString"
        else { return nil }

        let points = document.geometry.coordinates.compactMap { coordinate -> CGPoint? in
            guard coordinate.count == 2 else { return nil }
            // GeoJSON orders a position [longitude, latitude] — the opposite of how the two
            // are usually said aloud, and a real, easy way to transpose a route's whole shape
            // if read the other way round.
            return projection.project(lat: coordinate[1], lon: coordinate[0])
        }
        guard points.count >= 2 else { return nil }

        let leg = RouteLeg(streetName: "Route", points: points, hitRadius: map.metrics.roadHitRadius)
        return RouteScene(departureName: departureName, destinationName: destinationName,
                          legs: [leg], waypointPositions: [points[0], points[points.count - 1]],
                          pointsPerMeter: map.metrics.pointsPerMeter)
    }
}

// MARK: - Built

/// One leg of the built route: the real pavement connecting two consecutive waypoints — a
/// sidewalk the whole way, never the roadway it runs alongside. See `RouteScene.build`.
nonisolated struct RouteLeg {
    let streetName: String
    /// Content-space polyline, running from this leg's waypoint to the next one, along the
    /// real sidewalk (and, where the walk has to cross to reach it, a real marked crossing).
    let points: [CGPoint]
    let hitRadius: CGFloat
}

/// A route, built against one loaded map.
///
/// Drawn as its own line above the roads, and felt as its own rhythmic pulse in place of the
/// road's steady buzz wherever a finger is both on a road and on the route — matching the
/// reference app's route/corridor distinction. A junction still wins over either, exactly as it
/// wins over a plain road: the route does not change that priority, only what a plain road
/// feels and sounds like underneath it.
nonisolated struct RouteScene {
    let departureName: String
    let destinationName: String
    let legs: [RouteLeg]
    /// Every waypoint's real position, in order — the exact `Intersection.position` values the
    /// legs were cut against, kept so an intersection close-up can recognise "this is waypoint
    /// 3 of the route" by exact match rather than by re-deriving distance from street names.
    let waypointPositions: [CGPoint]
    /// The scale the legs were built at, so distances in real metres can still be reasoned
    /// about — `turns` needs it to merge two vertices that are the same rounded-off corner.
    let pointsPerMeter: CGFloat

    var departurePosition: CGPoint? { waypointPositions.first }
    var destinationPosition: CGPoint? { waypointPositions.last }

    /// Where the route actually changes direction, in content points.
    ///
    /// Computed from the built geometry rather than authored, because the geometry is the only
    /// thing that knows: a hand-written waypoint list says which junctions the walk passes
    /// through, not which of them it turns at, and an imported route has no waypoints at all.
    /// See `IntersectionScene.routeTurnMinimumAngleDegrees` for why this needs an angle
    /// threshold rather than the reference app's "any non-collinear vertex" test.
    var turns: [CGPoint] {
        // Walking every leg end-to-end as one path, so a turn made *at* a waypoint — where one
        // leg stops and the next starts — is caught the same as one made mid-block.
        let path = legs.flatMap(\.points)
        guard path.count >= 3 else { return [] }

        let minimumAngle = IntersectionScene.routeTurnMinimumAngleDegrees * .pi / 180
        let window = IntersectionScene.routeTurnWindowMeters * pointsPerMeter
        let mergeWithin = IntersectionScene.routeTurnMergeMeters * pointsPerMeter
        let total = polylineLength(path)
        guard total > window * 2 else { return [] }

        // Compared over a window either side, not between neighbouring vertices.
        //
        // Real pavement stitched out of real fragments is not smooth: consecutive vertices
        // disagree by tens of degrees all the way along a straight block, and a connector
        // bridging two fragments meets each at an angle. Testing neighbours found 9 "turns" on
        // a route that runs dead straight down one street. Looking a few metres back and a few
        // metres on instead asks the question that actually matters — has the direction of
        // travel changed? — and that is flat along a straight block however ragged the vertices.
        var found: [CGPoint] = []
        var distance = window
        let step = max(window / 4, 1)
        while distance <= total - window {
            guard let at = pointAlongPolyline(path, distance: distance),
                  let back = pointAlongPolyline(path, distance: distance - window),
                  let ahead = pointAlongPolyline(path, distance: distance + window)
            else { break }
            let incoming = atan2(at.y - back.y, at.x - back.x)
            let outgoing = atan2(ahead.y - at.y, ahead.x - at.x)
            var change = abs(outgoing - incoming)
            if change > .pi { change = 2 * .pi - change }
            if change >= minimumAngle,
               !found.contains(where: { hypot($0.x - at.x, $0.y - at.y) <= mergeWithin }) {
                found.append(at)
            }
            distance += step
        }
        return found
    }

    /// Which waypoint a position is, if it is one at all. Exact match (to a fraction of a
    /// point) rather than a tolerance: both this and every leg were cut from the very same
    /// `Intersection.position` values, so there is nothing to be approximate about.
    func waypointIndex(at position: CGPoint) -> Int? {
        waypointPositions.firstIndex {
            hypot($0.x - position.x, $0.y - position.y) < 0.01
        }
    }

    /// Indices into `legs` for the leg arriving at a waypoint and the one leaving it — one of
    /// each for a waypoint in the middle of the route, only one at either end.
    func legIndices(at waypointIndex: Int) -> [Int] {
        var indices: [Int] = []
        if waypointIndex > 0 { indices.append(waypointIndex - 1) }
        if waypointIndex < legs.count { indices.append(waypointIndex) }
        return indices
    }

    /// How far a waypoint's real, clustered position may sit from the road actually named for
    /// its leg before that road is rejected as the wrong one. Generous, and in real metres: a
    /// junction's position is an average of nearby crossing points, not the exact node the route
    /// was authored against, and this tolerance has nothing to do with how wide a finger's
    /// target on the drawn route is — see `hitRadius` below for that.
    private static let waypointMatchToleranceMeters: CGFloat = 20

    /// How far apart two sidewalk fragments may sit and still be treated as the same, real,
    /// continuous pavement rather than two unrelated pieces. Sidewalk ways are frequently cut
    /// at driveways and alley mouths that are not gaps a real pedestrian notices, so this is
    /// generous — but nowhere near wide enough to bridge a genuinely unmapped block, which is
    /// exactly the failure this is meant to keep from being papered over silently.
    private static let maxSidewalkGapMeters: CGFloat = 8

    /// Cuts this route's geometry out of `map`'s real sidewalks and crossings, or returns `nil`
    /// if any waypoint, or the pavement for any leg, cannot be found — which means the route
    /// cannot honestly be walked as drawn, not that it should be drawn down the middle of the
    /// road instead. A route is a pedestrian's path, and the roadway is the one place on this
    /// whole screen a pedestrian must not be standing; see `IntersectionScene`'s own reasoning
    /// for the same rule at a junction.
    static func build(waypoints: [RouteWaypointSpec], departureName: String,
                      destinationName: String, map: StreetMap) -> RouteScene? {
        let matchTolerance = waypointMatchToleranceMeters * map.metrics.pointsPerMeter
        let maxGap = maxSidewalkGapMeters * map.metrics.pointsPerMeter
        // The route is not a narrower target than the road it runs alongside.
        let hitRadius = map.metrics.roadHitRadius

        // Every waypoint has to be a real, computed junction — not a point on the map, but the
        // specific place two named streets actually cross.
        var positions: [CGPoint] = []
        for spec in waypoints {
            guard let junction = map.intersections.first(where: { Set($0.streetNames) == spec.streetNames })
            else { return nil }
            positions.append(junction.position)
        }

        var streetNames: [String] = []
        var legPoints: [[CGPoint]] = []
        for index in waypoints.indices.dropLast() {
            // The named street has to be a real road actually connecting these two waypoints —
            // more than one road in the city can share a name, so this is what rejects a
            // same-named street on the far side of downtown, or a plain typo in `viaStreet`.
            // Its geometry is not otherwise needed: the walk is on the sidewalk beside it, not
            // on it.
            guard let streetName = waypoints[index].viaStreet,
                  roadPolyline(from: positions[index], to: positions[index + 1],
                              named: streetName, in: map, tolerance: matchTolerance) != nil,
                  let sidewalk = sidewalkPolyline(from: positions[index], to: positions[index + 1],
                                                  in: map, matchTolerance: matchTolerance, maxGap: maxGap)
            else { return nil }
            streetNames.append(streetName)
            legPoints.append(sidewalk)
        }

        // Bridge the join between one leg's pavement and the next. Where they already meet —
        // the ordinary case, both sidewalks reaching the same corner — nothing is inserted.
        // Where the walk has to cross the road to reach the next block's pavement, the real
        // marked crossing at that corner is spliced onto the end of the leg arriving there;
        // only if none exists does this fall back to a straight connector, which is appended
        // the same way rather than represented as a crossing of its own.
        var legs: [RouteLeg] = []
        for index in legPoints.indices {
            let points = legPoints[index]
            if let previousEnd = points.first, index > 0,
               let arrivingEnd = legPoints[index - 1].last,
               dist(arrivingEnd, previousEnd) > matchTolerance / 4 {
                let bridge = crossingBridge(from: arrivingEnd, to: previousEnd, near: positions[index],
                                            in: map, matchTolerance: matchTolerance)
                legs[legs.count - 1] = RouteLeg(streetName: legs[legs.count - 1].streetName,
                                                points: legs[legs.count - 1].points + bridge,
                                                hitRadius: hitRadius)
            }
            legs.append(RouteLeg(streetName: streetNames[index], points: points, hitRadius: hitRadius))
        }
        return RouteScene(departureName: departureName, destinationName: destinationName,
                          legs: legs, waypointPositions: positions,
                          pointsPerMeter: map.metrics.pointsPerMeter)
    }

    /// The real sidewalk pavement running from `start` to `end` — possibly stitched together
    /// from several short OSM ways, since sidewalks are mapped in fragments far more often than
    /// roads are.
    ///
    /// Not split by which side of the road a fragment is on before searching. A pedestrian
    /// does not cross the road mid-block, so that sounds like a safeguard worth having — but a
    /// hard near/far partition also throws away the one adjacent fragment on the *other* side
    /// that might be the only thing within reach of a corner's last few metres of real data,
    /// and the road itself is normally far wider than `maxGap`, so a genuine mid-block jump to
    /// the wrong side essentially cannot win the search anyway.
    private static func sidewalkPolyline(from start: CGPoint, to end: CGPoint, in map: StreetMap,
                                         matchTolerance: CGFloat, maxGap: CGFloat) -> [CGPoint]? {
        let corridorRadius = dist(start, end) / 2 + matchTolerance
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let candidates = map.footways(near: mid, within: corridorRadius).filter { $0.kind == .sidewalk }
        guard !candidates.isEmpty else { return nil }
        return chain(candidates, from: start, to: end, maxGap: maxGap, matchTolerance: matchTolerance)
    }

    /// Finds the real chain of sidewalk fragments from `start` to `end` — genuinely the
    /// shortest one, by Dijkstra over a small graph rather than a greedy nearest-endpoint walk.
    ///
    /// **Greedy nearest-endpoint stitching was tried first, and it is not enough.** Real
    /// corners have short, unrelated fragments nearby — a driveway apron, a kerb ramp — that
    /// can sit closer to `start` than the fragment that actually continues toward `end`. A
    /// greedy walk anchors on whichever is nearest and has no way back out of a dead end; a
    /// shortest-path search considers every fragment's *other* end too, so a stub that goes
    /// nowhere simply never appears on the winning path.
    ///
    /// The graph: each fragment is an edge between its own two endpoints, weighted by its own
    /// length; any two different fragments' endpoints within `maxGap` of each other are also
    /// joined, weighted by that gap — a real, if unmapped, connection, the same generosity
    /// `pavementReachMeters` extends to a crossing that stops short of the kerb it is meant to
    /// reach. Two virtual nodes, `start` and `end`, connect to every fragment endpoint within
    /// `matchTolerance` of the real point they stand for.
    private static func chain(_ pieces: [Footway], from start: CGPoint, to end: CGPoint,
                      maxGap: CGFloat, matchTolerance: CGFloat) -> [CGPoint]? {
        guard !pieces.isEmpty else { return nil }

        // Node 0 = start, node 1 = end, then two nodes per fragment (its own p0 and p1).
        let startNode = 0, endNode = 1
        func p0Node(_ i: Int) -> Int { 2 + i * 2 }
        func p1Node(_ i: Int) -> Int { 2 + i * 2 + 1 }
        let nodeCount = 2 + pieces.count * 2

        func point(of node: Int) -> CGPoint {
            switch node {
            case startNode: return start
            case endNode: return end
            default:
                let i = (node - 2) / 2
                return (node - 2).isMultiple(of: 2) ? pieces[i].points[0] : pieces[i].points[pieces[i].points.count - 1]
            }
        }

        var adjacency: [[(to: Int, weight: CGFloat)]] = Array(repeating: [], count: nodeCount)
        func connect(_ a: Int, _ b: Int, _ weight: CGFloat) {
            adjacency[a].append((b, weight))
            adjacency[b].append((a, weight))
        }
        for (i, piece) in pieces.enumerated() {
            connect(p0Node(i), p1Node(i), polylineLength(piece.points))
        }
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                for (na, nb) in [(p0Node(i), p0Node(j)), (p0Node(i), p1Node(j)),
                                 (p1Node(i), p0Node(j)), (p1Node(i), p1Node(j))] {
                    let gap = dist(point(of: na), point(of: nb))
                    if gap <= maxGap { connect(na, nb, gap) }
                }
            }
            for node in [p0Node(i), p1Node(i)] {
                let toStart = dist(point(of: node), start)
                if toStart <= matchTolerance { connect(startNode, node, toStart) }
                let toEnd = dist(point(of: node), end)
                if toEnd <= matchTolerance { connect(endNode, node, toEnd) }
            }
        }

        // Dijkstra, start to end.
        var distance = [CGFloat](repeating: .greatestFiniteMagnitude, count: nodeCount)
        var previous = [Int?](repeating: nil, count: nodeCount)
        var visited = [Bool](repeating: false, count: nodeCount)
        distance[startNode] = 0
        for _ in 0..<nodeCount {
            guard let current = (0..<nodeCount).filter({ !visited[$0] })
                .min(by: { distance[$0] < distance[$1] }), distance[current] < .greatestFiniteMagnitude
            else { break }
            visited[current] = true
            for (neighbor, weight) in adjacency[current] where !visited[neighbor] {
                let candidate = distance[current] + weight
                if candidate < distance[neighbor] { distance[neighbor] = candidate; previous[neighbor] = current }
            }
        }
        guard distance[endNode] < .greatestFiniteMagnitude else { return nil }

        // Walk the path back from `end`, turning each fragment edge into its real points and
        // each gap edge into a straight two-point connector.
        var path = [endNode]
        var node = endNode
        while let prior = previous[node] { path.append(prior); node = prior }
        path.reverse()

        // The edges touching the virtual start/end nodes contribute nothing of their own on a
        // normal path — the real point they connect to is already the first or last point of a
        // fragment edge right beside them. The one exception is a path of just three nodes
        // (start, one real node, end): on a short enough block, one fragment's single endpoint
        // can sit within tolerance of *both* real waypoints at once, and that lone point is the
        // whole route, not something to be silently dropped for having no fragment edge either
        // side of it. Duplicated rather than left as one point, since a leg is drawn and
        // hit-tested as a polyline — this is a genuinely short block, not a missing one.
        if path.count == 3 { return [point(of: path[1]), point(of: path[1])] }

        var points: [CGPoint] = []
        for (a, b) in zip(path, path.dropFirst()) {
            guard a != startNode, a != endNode, b != startNode, b != endNode else { continue }
            let sameFragment = (a - 2) / 2 == (b - 2) / 2
            if sameFragment {
                let i = (min(a, b) - 2) / 2
                points.append(contentsOf: a < b ? pieces[i].points : pieces[i].points.reversed())
            } else {
                if points.isEmpty { points.append(point(of: a)) }
                points.append(point(of: b))
            }
        }
        return points.isEmpty ? nil : points
    }

    /// The real marked crossing nearest `waypoint` that actually connects `from` to `to`, or a
    /// straight connector if none does. The straight fallback is deliberately unmarked in the
    /// model — it is extra points appended to the previous leg, not a leg or a crossing of its
    /// own — so it is never announced or felt as if it were a real, mapped crossing.
    private static func crossingBridge(from: CGPoint, to: CGPoint, near waypoint: CGPoint,
                                       in map: StreetMap, matchTolerance: CGFloat) -> [CGPoint] {
        let crossings = map.footways(near: waypoint, within: matchTolerance * 3).filter { $0.kind == .crossing }
        for crossing in crossings {
            let (p0, p1) = (crossing.points[0], crossing.points[crossing.points.count - 1])
            let matchesForward = dist(p0, from) <= matchTolerance && dist(p1, to) <= matchTolerance
            let matchesReverse = dist(p1, from) <= matchTolerance && dist(p0, to) <= matchTolerance
            guard matchesForward || matchesReverse else { continue }
            return matchesForward ? crossing.points : Array(crossing.points.reversed())
        }
        return [to]
    }

    /// The stretch of `streetName` that actually runs from `start` to `end` — used only to
    /// confirm `viaStreet` really is a real road connecting these two waypoints, not a typo or
    /// a same-named street on the far side of downtown; its geometry is otherwise unused, since
    /// the walk itself follows the sidewalk beside it, not the road.
    private static func roadPolyline(from start: CGPoint, to end: CGPoint, named streetName: String,
                                     in map: StreetMap, tolerance: CGFloat) -> [CGPoint]? {
        var best: (points: [CGPoint], length: CGFloat)?
        for feature in map.features where feature.name == streetName {
            guard distanceToPolyline(start, feature.points) <= tolerance,
                  distanceToPolyline(end, feature.points) <= tolerance else { continue }
            let a = arcLength(of: start, along: feature.points)
            let b = arcLength(of: end, along: feature.points)
            let cut = subpath(of: feature.points, from: min(a, b), to: max(a, b))
            guard cut.count >= 2 else { continue }
            let length = polylineLength(cut)
            if best == nil || length < best!.length { best = (cut, length) }
        }
        return best?.points
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Distance along `points` to the spot closest to `point` — the inverse of
    /// `pointAlongPolyline`, needed to cut a road down to the stretch between two positions on it.
    private static func arcLength(of point: CGPoint, along points: [CGPoint]) -> CGFloat {
        var best: (distance: CGFloat, arcLength: CGFloat)?
        var accumulated: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let segmentLength = dist(a, b)
            let closest = closestPointOnSegment(point, a, b)
            let candidate = accumulated + dist(a, closest)
            let distance = dist(point, closest)
            if best == nil || distance < best!.distance { best = (distance, candidate) }
            accumulated += segmentLength
        }
        return best?.arcLength ?? 0
    }

    private static func closestPointOnSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    }

    // MARK: Lookup

    /// The leg under a content-space point, or nil if the finger is on a road the route does not
    /// use here.
    func leg(at point: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, leg) in legs.enumerated() {
            let distance = distanceToPolyline(point, leg.points)
            guard distance <= leg.hitRadius else { continue }
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// What is spoken on entering a leg: the destination on the very first one, so a finger that
    /// starts exploring at the departure end hears where the route goes, and just "Route"
    /// afterwards — matching the reference app, which does not re-announce the destination on
    /// every subsequent leg.
    func announcement(forLeg index: Int) -> String {
        index == 0 ? "Route to \(destinationName)" : "Route"
    }
}
