//
//  IntersectionScene.swift
//  TactileNav
//
//  One junction, close up, built from the real OpenStreetMap geometry around it.
//
//  This is the counterpart to the city-scale map. Out there every road is one 4 mm line and
//  sidewalks and crossings are dropped, because at that zoom they crowd every junction into
//  noise. Here there is one junction and a whole screen to spend on it, so the three things a
//  pedestrian has to tell apart each get room: the roadway, the sidewalk behind the kerb, and
//  the marked crossing between them.
//
//  Nothing here is schematic. The legs run at their true bearings, the sidewalks and crossings
//  are the ones OpenStreetMap records at that corner, and the whole thing is the same geometry
//  the overview map is drawn from — just translated so the junction is at the centre and
//  scaled up so a finger can work at the scale of a kerb rather than a city block.
//

import CoreGraphics
import Foundation
import TactileMapCore

// MARK: - What the finger can land on

nonisolated enum IntersectionSurface {
    /// The roadway. The one place you must not be standing.
    case road
    /// The walkway behind the kerb.
    case sidewalk
    /// A marked crossing over a roadway.
    case crossing

    var elementType: TactileElementType {
        switch self {
        case .road: return .road
        case .sidewalk: return .street
        case .crossing: return .crosswalk
        }
    }

    /// Resolves an overlap. A crossing is painted over a roadway, so when the two are equally
    /// close the crossing is the honest answer — and it is the thinner, harder-to-find thing.
    var priority: Int {
        switch self {
        case .crossing: return 2
        case .sidewalk: return 1
        case .road: return 0
        }
    }
}

// MARK: - A drawable, touchable piece

nonisolated struct IntersectionPiece {
    let id: String
    let surface: IntersectionSurface
    /// What is spoken when a finger lands here.
    let name: String
    /// Polyline in view points, junction at the centre, north up.
    let points: [CGPoint]
    let width: CGFloat
    let hitRadius: CGFloat
}

// MARK: - The assembled close-up

nonisolated struct IntersectionScene {

    // MARK: Physical constants (millimetres on the glass)

    /// A traffic lane, for working out how wide a roadway really is.
    static let laneWidthMeters: CGFloat = 3.3

    /// Bounds on the drawn roadway. Between these it is drawn at its *true* width — lane count
    /// times lane width — because at this zoom there is room for the real thing, and because
    /// the sidewalks and crossings around it are at their real positions. Drawing the roadway
    /// at a fixed width instead pushes its edge across the sidewalk beside it, and the kerb —
    /// the single most important line at a junction — stops existing.
    static let minimumRoadWidthMM: CGFloat = 8.0
    static let maximumRoadWidthMM: CGFloat = 16.0
    static let sidewalkWidthMM: CGFloat = 4.0
    /// A crossing is a thin line, the weight of the paint on the ground.
    static let crossingWidthMM: CGFloat = 2.8
    /// Length of one painted bar along the direction you walk.
    static let crossingBarLengthMM: CGFloat = 1.4
    static let crossingBarCount = 3

    /// How much ground the close-up covers, measured from the junction centre. Far enough to
    /// take in the corners and the crossings, close enough that a kerb is a finger's width.
    static let radiusMeters: CGFloat = 42

    /// Below this a line is drawn but cannot reliably be found by a moving finger.
    static let minimumHitRadius: CGFloat = 18

    // MARK: Contents

    let junction: Intersection
    let pieces: [IntersectionPiece]
    let size: CGSize
    let center: CGPoint
    /// Points per metre inside this view — much larger than the city map's.
    let scale: CGFloat

    /// "Four-way intersection of Congress Street and High Street"
    var title: String { junction.announcement }

    /// What VoiceOver reads on arrival: the junction, then the arms a traveller can take.
    ///
    /// Static because it is needed before the scene exists — the screen announces itself while
    /// the view is still being laid out.
    static func entryAnnouncement(for junction: Intersection) -> String {
        var parts = ["\(junction.announcement)."]
        if !junction.legs.isEmpty {
            let arms = junction.legs.map { "\($0.streetName) to the \($0.compassLabel)" }
            parts.append("Streets from here: " + arms.joined(separator: ", ") + ".")
        }
        parts.append("Drag one finger to feel the roadway, the sidewalks and the crossings.")
        return parts.joined(separator: " ")
    }

    // MARK: Build

    /// Cuts the real geometry around `junction` out of the map and lays it out to fill `size`.
    ///
    /// Everything is translated so the junction sits at the centre and scaled so the chosen
    /// radius fills the shorter edge. North stays up, and the bearings are whatever the real
    /// streets do — a junction that meets at 43 degrees is drawn at 43 degrees.
    static func build(junction: Intersection, map: StreetMap, size: CGSize) -> IntersectionScene {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let mm = { PhysicalDimensions.mmToPoints($0) }

        // Points per metre for this view: the radius has to fit inside the shorter edge.
        let viewScale = max(min(size.width, size.height) / 2, 1) / radiusMeters
        // The city map is in content points, so convert its distances to metres first.
        let radiusInContentPoints = radiusMeters * map.metrics.pointsPerMeter

        /// Map a content point into this view.
        func place(_ point: CGPoint) -> CGPoint {
            let metresX = (point.x - junction.position.x) / map.metrics.pointsPerMeter
            let metresY = (point.y - junction.position.y) / map.metrics.pointsPerMeter
            return CGPoint(x: center.x + metresX * viewScale, y: center.y + metresY * viewScale)
        }

        // Nothing is trimmed. Keeping only the vertices inside the radius throws away any
        // two-point way with one end outside it — which is most sidewalks and every crossing,
        // since they are short and start at the kerb. The canvas clips to its own bounds, so
        // a road running off the edge costs nothing and the geometry stays intact.

        var pieces: [IntersectionPiece] = []

        for road in map.roads(near: junction.position, within: radiusInContentPoints) {
            // True width for this roadway, then held inside the tactile bounds.
            let realWidth = CGFloat(max(road.lanes, 1)) * laneWidthMeters * viewScale
            let roadWidth = min(max(realWidth, mm(minimumRoadWidthMM)), mm(maximumRoadWidthMM))
            pieces.append(IntersectionPiece(
                id: road.id,
                surface: .road,
                name: road.name,
                points: road.points.map(place),
                width: roadWidth,
                hitRadius: max(roadWidth / 2, minimumHitRadius)))
        }

        let sidewalkWidth = mm(sidewalkWidthMM)
        let crossingWidth = mm(crossingWidthMM)
        for footway in map.footways(near: junction.position, within: radiusInContentPoints) {
            let placed = footway.points.map(place)
            switch footway.kind {
            case .sidewalk:
                pieces.append(IntersectionPiece(
                    id: footway.id,
                    surface: .sidewalk,
                    name: sidewalkName(for: placed, center: center),
                    points: placed,
                    width: sidewalkWidth,
                    hitRadius: max(sidewalkWidth / 2, minimumHitRadius)))
            case .crossing:
                pieces.append(IntersectionPiece(
                    id: footway.id,
                    surface: .crossing,
                    name: crossingName(for: placed, center: center, junction: junction),
                    points: placed,
                    width: crossingWidth,
                    hitRadius: max(crossingWidth / 2, minimumHitRadius)))
            }
        }

        return IntersectionScene(junction: junction, pieces: pieces,
                                 size: size, center: center, scale: viewScale)
    }

    /// "North sidewalk" — which side of the junction it runs along.
    ///
    /// The extract names every sidewalk just "Sidewalk", so the side is read off the geometry:
    /// the compass direction of its middle from the junction centre. That is the thing a
    /// traveller needs, and it is not in the data.
    private static func sidewalkName(for points: [CGPoint], center: CGPoint) -> String {
        let middle = polylineMidpoint(points)
        let direction = compass(from: center, to: middle)
        return direction.isEmpty ? "Sidewalk" : "\(direction.capitalized) sidewalk"
    }

    /// "Crossing on the north side" — a crossing is identified by which arm it serves.
    private static func crossingName(for points: [CGPoint], center: CGPoint,
                                     junction: Intersection) -> String {
        let middle = polylineMidpoint(points)
        let direction = compass(from: center, to: middle)
        return direction.isEmpty ? "Crossing" : "Crossing on the \(direction) side"
    }

    /// Compass direction of `to` from `from`. Screen y grows south.
    private static func compass(from: CGPoint, to: CGPoint) -> String {
        let dx = to.x - from.x
        let dy = to.y - from.y
        guard hypot(dx, dy) > 0.5 else { return "" }
        let bearing = atan2(dx, -dy) * 180 / .pi
        return IntersectionArm.compassName(for: CGFloat(bearing))
    }

    // MARK: Lookup

    /// How close two pieces have to be before priority, rather than distance, decides.
    private static let tieBreak: CGFloat = 8

    /// What is under a point, or nil for the space between things.
    func piece(at point: CGPoint) -> IntersectionPiece? {
        var best: (piece: IntersectionPiece, distance: CGFloat)?
        for piece in pieces {
            let distance = distanceToPolyline(point, piece.points)
            guard distance <= piece.hitRadius else { continue }
            guard let current = best else {
                best = (piece, distance)
                continue
            }
            if distance < current.distance - Self.tieBreak {
                best = (piece, distance)
            } else if abs(distance - current.distance) <= Self.tieBreak,
                      piece.surface.priority > current.piece.surface.priority {
                best = (piece, distance)
            }
        }
        return best?.piece
    }
}
