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
    /// The kerb at one end of a crossing: where you wait, and where you arrive.
    case crossingEnd

    var elementType: TactileElementType {
        switch self {
        case .road: return .road
        case .sidewalk: return .street
        case .crossing, .crossingEnd: return .crosswalk
        }
    }

    /// Resolves an overlap. A crossing is painted over a roadway, so when the two are equally
    /// close the crossing is the honest answer — and it is the thinner, harder-to-find thing.
    /// A kerb dot outranks everything: it is a single point deliberately placed where a
    /// crossing, a sidewalk and often a roadway all meet, and it is the only one of the four
    /// that tells you *where along* the crossing you are.
    var priority: Int {
        switch self {
        case .crossingEnd: return 3
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
    /// What is spoken when a finger lands here. A `.crossingEnd` is not spoken — see
    /// `IntersectionFeedbackController.enter` — but still carries a name, for the touch log.
    let name: String
    /// Polyline in view points, junction at the centre, north up. A `.crossingEnd` is a
    /// single point: it is a dot, not a line.
    let points: [CGPoint]
    /// Stroke width for a line; diameter for a `.crossingEnd` dot.
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
    ///
    /// The floor is deliberately well under a fingertip. A roadway is found by its hit radius,
    /// which never drops below `minimumHitRadius` however narrow the drawing gets, so the drawn
    /// width is free to give ground to the kerb beside it — and a kerb that exists is worth far
    /// more than the last millimetre of a roadway that is already unmistakable.
    static let minimumRoadWidthMM: CGFloat = 6.0
    static let maximumRoadWidthMM: CGFloat = 16.0
    static let sidewalkWidthMM: CGFloat = 4.0
    /// A crossing is a thin line, the weight of the paint on the ground.
    static let crossingWidthMM: CGFloat = 2.8
    /// One painted bar, and the gap to the next. Bars repeat at this pitch for the whole
    /// length of a crossing; only the ones lying on the roadway are drawn.
    static let crossingBarLengthMM: CGFloat = 1.2
    static let crossingBarPitchMM: CGFloat = 2.6

    /// The dot at each end of a crossing, and its white ring. The reference app's sizes.
    static let crossingEndDiameterMM: CGFloat = 5.0
    static let crossingEndBorderMM: CGFloat = 0.4

    /// How far a crossing may be stretched to reach the pavement it is meant to land on.
    ///
    /// Generous enough to close the gap left by a way that stops at the kerb, and short enough
    /// that a crossing with no pavement near it is left alone rather than dragged across the
    /// block to the nearest unrelated footway.
    static let pavementReachMeters: CGFloat = 9.0

    /// The white line left between a roadway and the pavement beside it.
    ///
    /// A kerb is the most important edge at a junction — it is the difference between standing
    /// on the footway and standing in traffic — so it is guaranteed rather than hoped for. See
    /// `roadWidthLimit`.
    static let kerbGapMM: CGFloat = 0.8

    /// How much ground the close-up covers, measured from the junction centre. Far enough to
    /// take in the corners and the crossings, close enough that a kerb is a finger's width.
    ///
    /// The second half of that sentence is what sets the number, and 42 m did not satisfy it.
    /// Downtown Portland puts its pavements a median of 8.7 m from the road centreline — a
    /// quarter of them closer than 6.7 m — while the roadway drawn over them needed about
    /// 7.8 m of clearance to leave the pavement whole. So across the extract, two fifths of
    /// every stretch of pavement running alongside a road was partly painted over, and the grey
    /// line came out thinner than it should be or disappeared for a while. There is no way to
    /// draw an 8 mm roadway, a 4 mm pavement and a real kerb offset in 6 m of ground: the only
    /// fix is more glass per metre. At 26 m the same measurement falls to under a tenth, and
    /// what is lost is block, not junction — 52 m across the short edge still holds the corners
    /// and every crossing.
    static let radiusMeters: CGFloat = 26

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
        "\(junction.announcement). " + armsAnnouncement(for: junction)
    }

    /// The same thing with the junction's name left off.
    ///
    /// With VoiceOver on, the name has just been read out as the drawing's accessibility label
    /// when focus landed on it. Saying it again here would be the same sentence twice, once in
    /// each voice, which is exactly the thing this split exists to avoid.
    static func armsAnnouncement(for junction: Intersection) -> String {
        var parts: [String] = []
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

        // Footways first, because the roadways are sized against them — see `roadWidthLimit`.
        let sidewalkWidth = mm(sidewalkWidthMM)
        let crossingWidth = mm(crossingWidthMM)
        var sidewalkLines: [[CGPoint]] = []

        for footway in map.footways(near: junction.position, within: radiusInContentPoints) {
            let placed = footway.points.map(place)
            switch footway.kind {
            case .sidewalk:
                sidewalkLines.append(placed)
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

        for road in map.roads(near: junction.position, within: radiusInContentPoints) {
            let placed = road.points.map(place)
            // True width for this roadway, then held inside the tactile bounds, then held
            // clear of the pavement running beside it.
            let realWidth = CGFloat(max(road.lanes, 1)) * laneWidthMeters * viewScale
            var roadWidth = min(max(realWidth, mm(minimumRoadWidthMM)), mm(maximumRoadWidthMM))
            let limit = roadWidthLimit(centreline: placed, sidewalks: sidewalkLines,
                                       sidewalkWidth: sidewalkWidth, gap: mm(kerbGapMM))
            roadWidth = max(min(roadWidth, limit), mm(minimumRoadWidthMM))
            pieces.append(IntersectionPiece(
                id: road.id,
                surface: .road,
                name: road.name,
                points: placed,
                width: roadWidth,
                hitRadius: max(roadWidth / 2, minimumHitRadius)))
        }

        // A crossing runs from pavement to pavement — see `crossingSpanningThePavements`.
        pieces = pieces.map { piece in
            guard piece.surface == .crossing else { return piece }
            return crossingSpanningThePavements(piece, sidewalks: sidewalkLines,
                                                sidewalkWidth: sidewalkWidth,
                                                reach: pavementReachMeters * viewScale)
        }

        pieces.append(contentsOf: crossingEnds(of: pieces, sidewalks: sidewalkLines,
                                               sidewalkWidth: sidewalkWidth, mm: mm))

        return IntersectionScene(junction: junction, pieces: pieces,
                                 size: size, center: center, scale: viewScale)
    }

    // MARK: Crossings

    /// Cuts a crossing down to the stretch that actually links one pavement to the other.
    ///
    /// **A crossing is the thing that joins two pavements, so that is where it has to start and
    /// stop.** OpenStreetMap does not promise this: a crossing way is drawn to whatever the
    /// mapper found convenient, so some stop at the kerb and leave a gap of blank ground before
    /// the pavement, and others run on well past it down the block. Under a finger both are
    /// wrong in the same way — the line you are following gives out, and there is nothing to
    /// tell you whether you have arrived or lost it.
    ///
    /// So the way is extended a little at both ends, then trimmed back to the first and last
    /// place it meets a pavement. Short ones grow to reach; long ones lose their overhang. The
    /// extension is bounded by `pavementReachMeters`, and a crossing with no pavement within
    /// that falls back to the kerbs of the roadway it is on, which is the best that can be said
    /// about it.
    ///
    /// Trimming the piece itself, rather than only what is drawn, is deliberate: the markings,
    /// the touch target and the kerb dots then all agree, and a finger can run off the pavement,
    /// along the crossing and onto the far pavement without the line ever going quiet.
    private static func crossingSpanningThePavements(
        _ crossing: IntersectionPiece,
        sidewalks: [[CGPoint]],
        sidewalkWidth: CGFloat,
        reach: CGFloat
    ) -> IntersectionPiece {
        guard crossing.points.count >= 2 else { return crossing }
        let extended = extendEnds(of: crossing.points, by: reach)
        let total = polylineLength(extended)
        guard total > 0 else { return crossing }

        let onPavement = sidewalkWidth / 2 + 1
        func touchesPavement(_ point: CGPoint) -> Bool {
            sidewalks.contains { distanceToPolyline(point, $0) <= onPavement }
        }

        // `extendEnds` prepends and appends one point at exactly `reach`, so the way's own ends
        // sit at these two positions along the extended line.
        let ownStart = reach
        let ownEnd = total - reach

        /// The pavement contact *nearest this end of the way*, searched outward and inward
        /// together.
        ///
        /// Deliberately not the first contact anywhere along the extended line. Searching from
        /// the far tip of the extension finds whichever pavement it ran into out there —
        /// typically the one running along the far side of the block — and trimming to that left
        /// the crossing overhanging the pavement it was supposed to stop at by several metres.
        /// The stripes then ran on across the grey, punching a dashed hole through a pavement
        /// that is meant to read as one continuous line under a finger.
        func nearestPavement(to anchor: CGFloat) -> CGFloat? {
            var offset: CGFloat = 0
            while offset <= reach {
                for candidate in offset == 0 ? [anchor] : [anchor - offset, anchor + offset] {
                    guard candidate >= 0, candidate <= total,
                          let point = pointAlongPolyline(extended, distance: candidate),
                          touchesPavement(point) else { continue }
                    return candidate
                }
                offset += 2
            }
            return nil
        }

        // No pavement within reach of an end means there is nothing to connect it to, so that
        // end is left exactly as OpenStreetMap drew it. Inventing a stopping point for it would
        // be guessing at geometry that is simply absent — and it gets no dot either, because
        // there is nowhere to stand.
        let from = nearestPavement(to: ownStart) ?? ownStart
        let to = nearestPavement(to: ownEnd) ?? ownEnd
        guard to > from else { return crossing }

        let trimmed = subpath(of: extended, from: from, to: to)
        guard trimmed.count >= 2 else { return crossing }

        return IntersectionPiece(
            id: crossing.id, surface: crossing.surface, name: crossing.name,
            points: trimmed, width: crossing.width, hitRadius: crossing.hitRadius)
    }

    // MARK: Kerbs

    /// The widest this roadway may be drawn without eating the pavement beside it.
    ///
    /// The drawn roadway is the real one — lane count times lane width — and the sidewalks are
    /// at their real offsets, but those two numbers come from different parts of OpenStreetMap
    /// and do not have to agree. Where they disagreed, the roadway was drawn wider than the
    /// gap to the kerb, and since the roadway is painted over the pavement the grey line came
    /// out visibly thinner than it should be, or vanished for a stretch. That is not a drawing
    /// artefact to live with: a sidewalk whose width changes under a finger reads as a
    /// different surface, and the kerb it is supposed to mark stops existing.
    ///
    /// So the width is capped at twice the clearance to the nearest sidewalk, less that
    /// sidewalk's own half-width and a kerb gap. Only *parallel* sidewalks count. A sidewalk
    /// crossing the road head-on at a junction passes straight through the middle of it, and
    /// counting that one would collapse every roadway in the scene to the minimum.
    static func roadWidthLimit(centreline: [CGPoint], sidewalks: [[CGPoint]],
                               sidewalkWidth: CGFloat, gap: CGFloat) -> CGFloat {
        guard centreline.count >= 2 else { return .greatestFiniteMagnitude }

        var clearance = CGFloat.greatestFiniteMagnitude
        for line in sidewalks {
            for (a, b) in zip(line, line.dropFirst()) {
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let distance = distanceToPolyline(middle, centreline)
                guard distance < clearance else { continue }
                guard runsAlongside(a, b, centreline, at: middle) else { continue }
                clearance = distance
            }
        }
        guard clearance < .greatestFiniteMagnitude else { return .greatestFiniteMagnitude }
        return max((clearance - sidewalkWidth / 2 - gap) * 2, 0)
    }

    /// Whether a sidewalk segment runs along a roadway rather than across it.
    private static func runsAlongside(_ a: CGPoint, _ b: CGPoint, _ centreline: [CGPoint],
                                      at point: CGPoint) -> Bool {
        guard let walk = direction(from: a, to: b),
              let road = nearestSegmentDirection(to: point, in: centreline) else { return false }
        // |sin| of the angle between the two. 0.42 is a little over 25 degrees, which is wide
        // enough to catch a pavement following a bend and narrow enough to reject a crossing.
        return abs(walk.dx * road.dy - walk.dy * road.dx) <= 0.42
    }

    private static func direction(from a: CGPoint, to b: CGPoint) -> CGVector? {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.001 else { return nil }
        return CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
    }

    private static func nearestSegmentDirection(to point: CGPoint, in line: [CGPoint]) -> CGVector? {
        var best: (direction: CGVector, distance: CGFloat)?
        for (a, b) in zip(line, line.dropFirst()) {
            guard let unit = direction(from: a, to: b) else { continue }
            let distance = distanceToSegment(point, a, b)
            if best == nil || distance < best!.distance { best = (unit, distance) }
        }
        return best?.direction
    }

    /// A dot on the pavement at each end of a crossing.
    ///
    /// **On the pavement, not on the kerb.** The dot marks the place a pedestrian actually
    /// stands: waiting to step off at this end, and arrived at the other. That place is the
    /// footway behind the kerb, not the edge of the traffic — a dot on the kerb line marks the
    /// boundary you are trying not to be standing on.
    ///
    /// Because the piece has already been cut to the stretch between the two pavements — see
    /// `crossingSpanningThePavements` — the two ends of the crossing *are* the two waiting
    /// places, so this is simply its endpoints. That also makes the three things agree: the
    /// crossing you feel, the markings you see and the dots all start and stop together, and a
    /// finger can run off one pavement, along the crossing and onto the other without the line
    /// ever going quiet.
    ///
    /// An end that did not reach a pavement gets no dot. Those are the crossings that fell back
    /// to kerb-to-kerb for want of any mapped footway, and a dot out on blank ground marks
    /// nothing a traveller can use.
    private static func crossingEnds(of pieces: [IntersectionPiece],
                                     sidewalks: [[CGPoint]],
                                     sidewalkWidth: CGFloat,
                                     mm: (CGFloat) -> CGFloat) -> [IntersectionPiece] {
        let diameter = mm(crossingEndDiameterMM)
        let hitRadius = max(mm(crossingEndDiameterMM + crossingEndBorderMM) / 2, minimumHitRadius)
        let mergeWithin = mm(2.0)
        // The crossing was trimmed to the near edge of the pavement band, so a dot is on the
        // pavement if it is within that band's half width, with a little slack for the trim.
        let onPavement = sidewalkWidth / 2 + 1.5

        var dots: [IntersectionPiece] = []
        for piece in pieces where piece.surface == .crossing {
            guard let first = piece.points.first, let last = piece.points.last else { continue }
            for (index, end) in [first, last].enumerated() {
                guard sidewalks.contains(where: { distanceToPolyline(end, $0) <= onPavement })
                else { continue }
                // Where two crossings meet at a corner they share a waiting place, and two dots
                // on the same spot would ding twice for one place.
                guard !dots.contains(where: {
                    hypot($0.points[0].x - end.x, $0.points[0].y - end.y) <= mergeWithin
                }) else { continue }
                dots.append(IntersectionPiece(
                    id: "\(piece.id)_kerb_\(index)",
                    surface: .crossingEnd,
                    name: "Kerb, \(piece.name.lowercased())",
                    points: [end],
                    width: diameter,
                    hitRadius: hitRadius))
            }
        }
        return dots
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
