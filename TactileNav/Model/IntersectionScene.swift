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
    /// The exact point where the crossing roads overlap — the middle of the junction.
    case center
    /// A stretch of this junction's roadway that the study route follows. Sits exactly on top
    /// of a `.road` piece — same centreline, since it is cut from the very same real road — so
    /// it has to outrank the road to be felt at all rather than being the same thing twice.
    case route
    /// The route's very first or very last waypoint — where a traveller starts or ends.
    case routeEndpoint
    /// A place the route changes direction. A turn is the one thing about a route a traveller
    /// has to act on rather than just follow, so it is marked in its own right.
    case routeTurn

    var elementType: TactileElementType {
        switch self {
        case .road: return .road
        case .sidewalk: return .street
        case .crossing, .crossingEnd: return .crosswalk
        case .center: return .intersection
        case .route, .routeEndpoint, .routeTurn: return .route
        }
    }

    /// Resolves an overlap. A crossing is painted over a roadway, so when the two are equally
    /// close the crossing is the honest answer — and it is the thinner, harder-to-find thing.
    /// A kerb dot outranks everything on a crossing: it is a single point deliberately placed
    /// where a crossing, a sidewalk and often a roadway all meet, and it is the only one of the
    /// four that tells you *where along* the crossing you are. The centre outranks even that —
    /// it sits on top of the roadway, well away from any kerb dot, so there is nothing for it to
    /// actually compete with; it just needs to win the roadway underneath it. The route's start
    /// or end is a single named place, same as the centre is, and outranks everything: it is
    /// the one thing at that corner more specific than "you have arrived."
    ///
    /// A route stretch runs on the real pavement, not the road, so it competes with the plain
    /// sidewalk beneath it (and, at a corner it has to cross, the plain road) — it wins both,
    /// because "you are on the route" is the more useful thing to feel there than "you are on
    /// pavement in general." It does not try to outrank a marked crossing or its kerb dot,
    /// though: those are the two things a real pedestrian's safety can turn on, and staying
    /// legible on their own is worth more than the route's pulse being felt through them too.
    /// A turn ranks with the route's own ends rather than with the line between them: all three
    /// are single points that say something a stretch cannot, and a turn sitting on top of a
    /// crossing still has to be findable as a turn. Where a turn and an end genuinely coincide
    /// the end wins, because arriving outranks continuing — the same order `oneDotPerPlace`
    /// resolves them in when they are close enough that only one dot should be drawn at all.
    var priority: Int {
        switch self {
        case .routeEndpoint: return 7
        case .routeTurn: return 6
        case .center: return 5
        case .crossingEnd: return 4
        case .crossing: return 3
        case .route: return 2
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
    /// The ceiling is 12 mm to put the roadway at roughly three times `sidewalkWidthMM`, the
    /// ratio asked for by the in-person study this screen is used for. Checked against the real
    /// extract before being set, not assumed: at `radiusMeters` below, almost every corner on
    /// the study route clears it with room to spare, and city-wide only about 3% of real
    /// roadways cannot — see `onlyTheKnownThreeRouteCornersFallBelowTheRoadwayFloor` for exactly
    /// which ones on the route do not, and why 26 m was kept anyway.
    ///
    /// The floor is deliberately well under a fingertip. A roadway is found by its hit radius,
    /// which never drops below `minimumHitRadius` however narrow the drawing gets, so the drawn
    /// width is free to give ground to the kerb beside it — and a kerb that exists is worth far
    /// more than the last millimetre of a roadway that is already unmistakable. It is also the
    /// backstop for the handful of corners the ceiling's clearance check above does not clear:
    /// rather than disappearing, those roads hold this floor — and where the real clearance is
    /// less than the floor itself, that road does touch the pavement beside it. That is a known
    /// trade, not a bug; see `radiusMeters`.
    static let minimumRoadWidthMM: CGFloat = 6.0
    static let maximumRoadWidthMM: CGFloat = 12.0
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

    /// The study route overlay — the reference app's width, and the same on both screens, so
    /// the route is one recognisable thing whether it is met on the city map or in here.
    static let routeWidthMM: CGFloat = 3.5

    /// The route's start and end dot, and its white ring. The reference app's yellow, sized to
    /// match its own route-turn dot rather than the (smaller) crosswalk kerb dot: this is the
    /// one landmark on the whole screen that means "this is where the walk begins or ends,"
    /// and it should read as at least as important as any crossing on the corner.
    static let routeEndpointDiameterMM: CGFloat = 6.0
    static let routeEndpointBorderMM: CGFloat = 0.4

    /// The turn dot, in the reference app's orange — deliberately a different colour from the
    /// route's own yellow ends, because a turn is a thing to do, not a thing to arrive at.
    static let routeTurnDiameterMM: CGFloat = 6.0
    static let routeTurnBorderMM: CGFloat = 0.4

    /// How sharply the route has to change direction at a vertex before it counts as a turn.
    ///
    /// Real pavement is not drawn straight: a sidewalk polyline bends a degree or two at almost
    /// every vertex as it follows the kerb, and the reference app never had to deal with this
    /// because its routes are hand-drawn from two or three points, where every vertex genuinely
    /// is a corner. Marking those here would put a dot every few centimetres along the whole
    /// route. 40 degrees is well past kerb noise and well under the ~90 a real street corner
    /// turns through.
    static let routeTurnMinimumAngleDegrees: CGFloat = 20

    /// Two vertices this close together are the same corner rounded off in the data, not two
    /// turns, and should not get a dot each.
    static let routeTurnMergeMeters: CGFloat = 25

    /// How close a crossing has to run to the route before it counts as *the* crossing the
    /// route uses, rather than just another one at the same junction.
    static let routeCrossingReachMeters: CGFloat = 4.0

    /// How far a detected turn may be moved to land on a real corner.
    ///
    /// A turn is found where the route's own line bends, which is out on the roadway — but the
    /// place a pedestrian actually stands to make that turn is the corner, at the kerb. Wide
    /// enough to reach the kerb from the middle of a junction, narrow enough that a turn with
    /// no corner near it stays where it really is rather than being dragged to an unrelated one.
    static let routeTurnSnapMeters: CGFloat = 15

    /// How far either side of a point the direction of travel is measured over — see
    /// `RouteScene.turns`. Long enough to ignore how ragged real stitched pavement is between
    /// neighbouring vertices, short enough that a genuine street corner still turns fully
    /// within it.
    static let routeTurnWindowMeters: CGFloat = 12

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
    /// `roadWidthLimit`. Narrowed from 0.8 mm to leave more of each corner's real clearance
    /// available to the roadway itself, since the gap only has to be findable, not wide — a
    /// thin, guaranteed white line still reads as a kerb.
    static let kerbGapMM: CGFloat = 0.4

    /// How much ground the close-up covers, measured from the junction centre. Far enough to
    /// take in the corners and the crossings, close enough that a kerb is a finger's width.
    ///
    /// The second half of that sentence is what sets the number, and it is a genuine trade
    /// against `maximumRoadWidthMM`: widening the roadway's ceiling asks more of the same
    /// ground, since the real kerb offset a wider roadway has to clear does not grow with it.
    /// A 16 m radius gives every corner on the study route enough clearance to hold the full
    /// 12 mm ceiling without touching the pavement beside it. 26 m was chosen instead, for the
    /// wider overview of each junction's arms, and the cost of that choice is known and
    /// accepted rather than accidental: three real road/sidewalk pairs on the route — Fore
    /// Street at Silver Street, and two at Fore Street and Market Street — cannot support the
    /// full ceiling at this radius and fall back to `minimumRoadWidthMM` instead, which there
    /// means the road does touch the pavement. See
    /// `onlyTheKnownThreeRouteCornersFallBelowTheRoadwayFloor`, which pins down that this stays
    /// exactly those three and does not quietly grow.
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
        // Named as a screen, not just as a place. Arriving here is a change of context — the
        // scale, the gestures and what is under the finger are all different from the city map
        // — and someone who cannot see the transition has nothing else to tell them it happened.
        "Intersection view. \(junction.announcement). " + armsAnnouncement(for: junction)
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
    ///
    /// `route`, if given, is the same route the city map overlays — checked here against this
    /// one junction's real position, so a close-up on the route shows the same stretch of it,
    /// cut from the same real road geometry, rather than a second, separately-authored line.
    static func build(junction: Intersection, map: StreetMap, size: CGSize,
                      route: RouteScene? = nil) -> IntersectionScene {
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

        pieces.append(centerLandmark(of: pieces, at: center))

        if let route {
            let endpointTolerance = routeEndpointToleranceMeters * map.metrics.pointsPerMeter
            pieces.append(contentsOf: routePieces(for: junction, route: route, place: place, mm: mm,
                                                  searchRadius: radiusInContentPoints,
                                                  endpointTolerance: endpointTolerance))
            pieces = markRouteCorners(pieces, mm: mm,
                                      nearRoute: routeCrossingReachMeters * viewScale,
                                      snapWithin: routeTurnSnapMeters * viewScale)
            pieces = oneDotPerPlace(pieces, mm: mm)
        }

        return IntersectionScene(junction: junction, pieces: pieces,
                                 size: size, center: center, scale: viewScale)
    }

    // MARK: Route

    /// What a route kerb dot says: that this is the crossing to take, and which way it goes.
    ///
    /// The direction is measured to the crossing's *far* end, because that is where the walk is
    /// headed — a traveller standing on this kerb needs to know which way to step off it, and
    /// "cross here" on its own leaves them on a corner with two crossings leading away.
    private static func crossingInstruction(from kerb: CGPoint, along crossing: IntersectionPiece) -> String {
        let ends = [crossing.points.first, crossing.points.last].compactMap { $0 }
        guard let far = ends.max(by: {
            hypot($0.x - kerb.x, $0.y - kerb.y) < hypot($1.x - kerb.x, $1.y - kerb.y)
        }) else { return "Cross here." }
        let direction = compassDirection(from: kerb, to: far)
        return direction.isEmpty ? "Cross here." : "Cross here. Cross to the \(direction)."
    }

    /// What the yellow dot says at the start of the walk.
    ///
    /// Where you are, where you are going, and — the part that was missing — which way to set
    /// off. Without the last one the dot tells a traveller everything except the one thing they
    /// need in order to take a step.
    private static func departureAnnouncement(for route: RouteScene) -> String {
        let opening = "Your location. Route to \(route.destinationName)."
        guard let heading = route.departureInstruction else { return opening }
        return "\(opening) \(heading)"
    }

    /// Puts the route's dots where a pedestrian actually stands, and marks the crossing it uses.
    ///
    /// Two things happen here, both about the corner rather than the carriageway:
    ///
    /// A turn is *detected* out where the route's line bends, which is in the middle of the
    /// junction — useless as a landmark, since nobody stands there. It is moved onto the nearest
    /// real corner: the kerb where the crossing meets the pavement, which is exactly where the
    /// turn is made from.
    ///
    /// And the kerb dots of the crossing the route uses change from the ordinary pink to the
    /// route's own orange. That is what makes "which of these crossings is mine?" a question a
    /// finger can answer — colour alone would be no use, so they take the turn dot's sound and
    /// tap as well, which is what actually tells the two apart without sight.
    private static func markRouteCorners(_ pieces: [IntersectionPiece], mm: (CGFloat) -> CGFloat,
                                         nearRoute: CGFloat, snapWithin: CGFloat) -> [IntersectionPiece] {
        let routeLines = pieces.filter { $0.surface == .route }.map(\.points).filter { $0.count >= 2 }
        guard !routeLines.isEmpty else { return pieces }

        let corners = pieces.filter { $0.surface == .crossingEnd }.compactMap(\.points.first)
        // Kept as pieces, not just ids: telling someone which way to cross needs the crossing's
        // far end, which only the geometry knows.
        let usedCrossings = pieces.filter { $0.surface == .crossing }
            .filter { crossing in
                crossing.points.count >= 2 && routeLines.contains {
                    distanceToPolyline(polylineMidpoint(crossing.points), $0) <= nearRoute
                }
            }

        let turnDiameter = mm(routeTurnDiameterMM)
        let turnHitRadius = max(mm(routeTurnDiameterMM + routeTurnBorderMM) / 2, minimumHitRadius)

        /// Where each turn ends up: on the nearest corner, or where it already was if no corner
        /// is close enough to be the one it means. A turn dragged onto an unrelated corner would
        /// be a landmark pointing at the wrong place, which is worse than one that is awkward.
        func snapped(_ centre: CGPoint) -> CGPoint {
            guard let corner = corners.min(by: {
                hypot($0.x - centre.x, $0.y - centre.y) < hypot($1.x - centre.x, $1.y - centre.y)
            }), hypot(corner.x - centre.x, corner.y - centre.y) <= snapWithin
            else { return centre }
            return corner
        }
        let turnCorners = pieces.filter { $0.surface == .routeTurn }.compactMap(\.points.first).map(snapped)

        /// The crossing the route runs down that this dot stands at an end of, if any.
        ///
        /// Asked of the dot's *position*, not of its id, and that distinction is the whole
        /// point. Two crossings that meet at the same corner share that corner, and
        /// `crossingEnds` keeps only one dot there — which of the two crossings owns the
        /// survivor is an accident of the order they were walked in. Going by id therefore left
        /// the corner pink whenever the survivor happened to belong to the neighbour, which is
        /// exactly what put a pink dot on the route's own crossing at Fore and Market. Where
        /// the dot stands is the same question answered by geometry, and geometry does not care
        /// which duplicate won.
        let sharedCorner = mm(2.0)   // the merge distance `crossingEnds` deduped them at
        func routeCrossing(at dot: CGPoint) -> IntersectionPiece? {
            usedCrossings.first { crossing in
                [crossing.points.first, crossing.points.last].compactMap { $0 }
                    .contains { hypot($0.x - dot.x, $0.y - dot.y) <= sharedCorner }
            }
        }

        return pieces.map { piece in
            guard let centre = piece.points.first else { return piece }
            switch piece.surface {
            case .routeTurn:
                return IntersectionPiece(id: piece.id, surface: .routeTurn, name: piece.name,
                                         points: [snapped(centre)], width: piece.width,
                                         hitRadius: piece.hitRadius)
            case .crossingEnd:
                guard let crossing = routeCrossing(at: centre) else { return piece }
                // Not where a turn has just landed. Both are orange dots on the same corner, and
                // of the two "turn left here" is the instruction — "cross here" is what you do
                // once you have turned. Leaving both would put two dots a millimetre apart and
                // say the less useful one twice.
                guard !turnCorners.contains(where: { hypot($0.x - centre.x, $0.y - centre.y) <= turnDiameter })
                else { return piece }
                return IntersectionPiece(id: piece.id, surface: .routeTurn,
                                         name: crossingInstruction(from: centre, along: crossing),
                                         points: piece.points, width: turnDiameter, hitRadius: turnHitRadius)
            default:
                return piece
            }
        }
    }

    /// Keeps one dot per place a finger can land on.
    ///
    /// A corner the route turns at is very often also a corner a crossing lands on, so the
    /// orange turn dot and the pink kerb dot end up millimetres apart — two landmarks for one
    /// place, which under a fingertip is worse than either alone: you find something, then
    /// find something else half a fingertip away, and neither is the answer on its own.
    ///
    /// So where they collide, the more specific one stays. A turn beats a kerb dot, because
    /// "the route turns here" is a thing to act on where "a crossing reaches the pavement
    /// here" is a thing to know. The route's own start or end beats a turn, for the same
    /// reason one rung up: arriving outranks continuing. Kerb dots away from the route are
    /// untouched — this only ever fires where the route actually puts a dot of its own.
    private static func oneDotPerPlace(_ pieces: [IntersectionPiece],
                                       mm: (CGFloat) -> CGFloat) -> [IntersectionPiece] {
        func centres(_ surface: IntersectionSurface) -> [CGPoint] {
            pieces.filter { $0.surface == surface }.compactMap(\.points.first)
        }
        let endpoints = centres(.routeEndpoint)
        guard !centres(.routeTurn).isEmpty || !endpoints.isEmpty else { return pieces }

        /// Two dots crowd each other once their edges are closer than a hair's breadth apart,
        /// so the test is the sum of their radii — a real distance between real drawn things,
        /// not a number picked to look right.
        func crowds(_ point: CGPoint, _ others: [CGPoint], _ clearance: CGFloat) -> Bool {
            others.contains { hypot($0.x - point.x, $0.y - point.y) <= clearance }
        }
        let turnRadius = mm(routeTurnDiameterMM) / 2
        let kerbClearance = turnRadius + mm(crossingEndDiameterMM) / 2
        let endpointClearance = turnRadius + mm(routeEndpointDiameterMM) / 2

        // Which turns survive, decided before anything is tested against them — snapping a turn
        // to a corner and marking that corner's crossing both aim at the same few millimetres,
        // so two orange dots can land on each other as easily as an orange and a pink one.
        var keptTurns: [CGPoint] = []
        var keptTurnIDs: Set<String> = []
        for piece in pieces where piece.surface == .routeTurn {
            guard let centre = piece.points.first,
                  !crowds(centre, endpoints, endpointClearance),
                  !crowds(centre, keptTurns, turnRadius * 2)
            else { continue }
            keptTurns.append(centre)
            keptTurnIDs.insert(piece.id)
        }

        return pieces.filter { piece in
            guard let centre = piece.points.first else { return true }
            switch piece.surface {
            case .crossingEnd: return !crowds(centre, keptTurns, kerbClearance)
            case .routeTurn: return keptTurnIDs.contains(piece.id)
            default: return true
            }
        }
    }

    /// How close the route's real departure or destination has to sit to a junction before
    /// this counts as *the* corner where the walk begins or ends, not merely a corner the
    /// route happens to pass through nearby. Tight, and deliberately much smaller than
    /// `radiusMeters`: the landmark belongs to one corner, not every one in the close-up.
    static let routeEndpointToleranceMeters: CGFloat = 5.0

    /// The stretch(es) of the route that pass near this junction, plus a start or end dot if
    /// the route's real departure or destination sits close enough to be this corner.
    ///
    /// Proximity-based, the same way sidewalks and roads are pulled into a close-up — not
    /// "is this junction one of the route's authored waypoints," which only the hand-authored
    /// route has an answer for. A route sourced from outside this app (a routing API's
    /// response, say) knows nothing about this app's junctions at all; it is still cut from
    /// the very same leg polylines the city map draws, so a finger that follows the route out
    /// of a close-up and back onto the overview map is following one continuous piece of
    /// geometry, not two that happen to line up.
    private static func routePieces(for junction: Intersection, route: RouteScene,
                                    place: (CGPoint) -> CGPoint, mm: (CGFloat) -> CGFloat,
                                    searchRadius: CGFloat, endpointTolerance: CGFloat)
        -> [IntersectionPiece] {
        let routeWidth = mm(routeWidthMM)
        var pieces: [IntersectionPiece] = []
        for (index, leg) in route.legs.enumerated() where leg.points.count >= 2 {
            guard distanceToPolyline(junction.position, leg.points) <= searchRadius else { continue }
            pieces.append(IntersectionPiece(
                id: "route_leg_\(index)", surface: .route, name: "Route",
                points: leg.points.map(place), width: routeWidth,
                hitRadius: max(routeWidth / 2, minimumHitRadius)))
        }

        let endpointDiameter = mm(routeEndpointDiameterMM)
        let endpointHitRadius = max(mm(routeEndpointDiameterMM + routeEndpointBorderMM) / 2,
                                    minimumHitRadius)
        func isThisCorner(_ position: CGPoint?) -> CGPoint? {
            guard let position,
                  hypot(position.x - junction.position.x, position.y - junction.position.y) <= endpointTolerance
            else { return nil }
            return position
        }
        if let departure = isThisCorner(route.departurePosition) {
            pieces.append(IntersectionPiece(
                id: "route_start", surface: .routeEndpoint,
                name: departureAnnouncement(for: route),
                points: [place(departure)], width: endpointDiameter,
                hitRadius: endpointHitRadius))
        }
        if let destination = isThisCorner(route.destinationPosition) {
            pieces.append(IntersectionPiece(
                id: "route_end", surface: .routeEndpoint,
                name: "End of route.",
                points: [place(destination)], width: endpointDiameter,
                hitRadius: endpointHitRadius))
        }

        let turnDiameter = mm(routeTurnDiameterMM)
        let turnHitRadius = max(mm(routeTurnDiameterMM + routeTurnBorderMM) / 2, minimumHitRadius)
        for (index, turn) in route.turns.enumerated()
        where hypot(turn.position.x - junction.position.x,
                    turn.position.y - junction.position.y) <= searchRadius {
            pieces.append(IntersectionPiece(
                id: "route_turn_\(index)", surface: .routeTurn, name: turn.instruction,
                points: [place(turn.position)], width: turnDiameter, hitRadius: turnHitRadius))
        }
        return pieces
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

    // MARK: Centre

    /// A landmark at the exact point the crossing roads overlap.
    ///
    /// Sweeping a finger across the roadway finds *a* road, but nothing marks the one point that
    /// is every road at once — the middle of the junction itself, which is where a traveller
    /// crossing diagonally, or just trying to find the far corner, actually needs to land. So
    /// this adds a single named point there: silence otherwise reads as "still on some road,"
    /// not "here is the centre."
    ///
    /// Sized to the roadway actually crossing here, not a fixed number — a wide arterial and a
    /// narrow side street should not share one dead-zone size when only one of them is real at
    /// this junction. Widest of the roads found, because the overlap a finger has to land in is
    /// exactly as big as the widest thing crossing through it.
    private static func centerLandmark(of pieces: [IntersectionPiece], at center: CGPoint)
        -> IntersectionPiece {
        let width = pieces.filter { $0.surface == .road }.map(\.width).max()
            ?? PhysicalDimensions.mmToPoints(minimumRoadWidthMM)
        return IntersectionPiece(
            id: "center", surface: .center, name: "Center",
            points: [center], width: width, hitRadius: max(width / 2, minimumHitRadius))
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
        compassDirection(from: from, to: to)
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
