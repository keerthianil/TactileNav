//
//  StreetMapSizing.swift
//  TactileNav
//
//  Physical sizing for the Congress Square street map.
//
//  Everything here is expressed in millimetres on the glass and converted with
//  `PhysicalDimensions.mmToPoints`, which divides by the device's PPI. That is the whole
//  point: a road must be the same width under a finger on an iPhone SE, an iPhone 16 Pro
//  and an iPad. Sizes derived from the viewport (a fraction of the screen's short edge,
//  say) fail that test — they change with the device and with the visible span.
//
//  Line width and map scale are two independent numbers, and the important thing is that they
//  stay independent:
//
//    • **Line width.** Every road is drawn 4 mm wide, whatever its lane count. 4 mm is a
//      perceptual constant, not a measurement of asphalt — it is about the narrowest line a
//      fingertip can reliably follow. Scaling it by lane count sounds more faithful but is
//      self-defeating: a four-lane road would be 16 mm, wider than a fingertip, so it stops
//      being a line you can trace and becomes a plane with edges you cannot feel.
//
//    • **Map scale.** How much ground fits on the glass. Set from block spacing, not from the
//      lane width. Deriving it from the lane width — "4 mm on the glass is one real 3.3 m
//      lane" — sounds principled but makes the drawing life-size: the whole extract becomes
//      about 67 screens across and roughly 55 m of street fits on a phone, so the viewport
//      holds two streets and a junction and the grid can never be seen at all. A map you have
//      to pan for a minute to reach the next corner is not a map of a neighbourhood.
//
//  Every road map resolves this the same way: schematic line weight, separate scale. Both
//  numbers here are still physical millimetres, so both are the same size on every device.
//

import CoreGraphics
import TactileMapCore

nonisolated enum StreetMapSizing {

    // MARK: - Physical constants (millimetres on the glass)

    /// Width of one traffic lane, and the width every road line is drawn at.
    static let laneWidthMM: CGFloat = 4.0

    /// Width of the route overlay line. Narrower than the road it runs on, so the blue still
    /// shows either side of it and a route reads as a marking on the road rather than a
    /// second, wider road drawn on top of the first.
    /// The route overlay's width — the reference app's, and the same as the close-up's own
    /// `IntersectionScene.routeWidthMM`, so the route is one recognisable thing on both screens.
    static let routeWidthMM: CGFloat = 3.5

    /// How far apart two parallel streets should sit on the glass.
    ///
    /// This is the map's scale, expressed the way it is actually judged: by how far a finger
    /// has to travel from one street to the next. 40 mm is a little under a hand span, so a
    /// block can be crossed in one movement and a junction and its neighbours are on screen
    /// together — which is what makes a grid feel like a grid rather than a corridor.
    static let blockSpacingMM: CGFloat = 40.0

    // MARK: - Real-world reference

    /// Standard urban travel lane.
    static let laneWidthMeters: CGFloat = 3.3

    /// A typical downtown Portland block, and the ground `blockSpacingMM` represents.
    static let blockLengthMeters: CGFloat = 120.0

    // MARK: - Derived scale

    /// One lane's width in screen points on this device.
    static var laneWidthPoints: CGFloat {
        PhysicalDimensions.mmToPoints(laneWidthMM)
    }

    /// Screen points per real-world metre.
    ///
    /// Derived from block spacing, not from the lane width — see the note at the top of the
    /// file. Both terms are physical, so the scale is the same on every device; only the
    /// point count changes with pixel density.
    static var pointsPerMeter: CGFloat {
        pointsPerMeter(at: .standard)
    }

    /// The same, at a chosen scale. **Only this number moves when the scale changes** — the
    /// lane width above does not, which is what keeps a road 4 mm wide under the finger at every
    /// setting. See `MapScale`.
    static func pointsPerMeter(at scale: MapScale) -> CGFloat {
        PhysicalDimensions.mmToPoints(scale.blockSpacingMM) / blockLengthMeters
    }

    /// Stroke width for a road. The same for every road — see the note at the top of the file
    /// on why this deliberately does not scale with lane count.
    static var roadWidth: CGFloat { laneWidthPoints }

    // MARK: - Width by category

    /// How wide each kind of line is drawn, in millimetres on the glass.
    ///
    /// A street is the widest because it is the backbone and has to be the easiest thing to
    /// find and follow. The rest are narrower so that a finger crossing from one to another
    /// feels the change as a change of *size* as well as of texture — two cues for the same
    /// fact, which is what makes it readable at speed. None goes below 2.5 mm: under that a
    /// line stops being reliably traceable at all, and a line you cannot follow is worse than
    /// one that is not drawn.
    static func widthMM(of category: MapSurfaceCategory) -> CGFloat {
        switch category {
        case .street: return laneWidthMM
        case .path: return 2.5
        case .serviceRoad: return 2.5
        case .railway: return 3.0
        }
    }

    /// The same, in points, with the street's own width passed in so the caller's resolved
    /// metrics stay the single source of truth for it.
    static func width(of category: MapSurfaceCategory, streetWidth: CGFloat) -> CGFloat {
        category == .street ? streetWidth : PhysicalDimensions.mmToPoints(widthMM(of: category))
    }

    /// The colour each kind is drawn in.
    ///
    /// Paths take the same grey the junction close-up already uses for pavement, so the two
    /// screens agree about what grey means. Railways are near-black, service roads a washed-out
    /// blue that reads as a lesser relative of the street it branches off.
    static func color(of category: MapSurfaceCategory) -> CGColor {
        switch category {
        case .street: return roadColor
        case .path: return CGColor(red: 0x9E / 255, green: 0x9E / 255, blue: 0x9E / 255, alpha: 1)
        case .serviceRoad: return CGColor(red: 0x7F / 255, green: 0x9C / 255, blue: 0xC4 / 255, alpha: 1)
        case .railway: return CGColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 1)
        }
    }

    // MARK: - Hit-test radius (screen points)

    /// Touch radius for a road.
    ///
    /// Wider than the drawn line on purpose. Half a 4 mm line is only ~12 pt, and on a dense
    /// real street grid that asks a finger to trace within about a metre and a half of a
    /// centreline. Floors in the low twenties are the established practice for exactly this
    /// reason.
    static let roadHitRadius: CGFloat = 22

    // MARK: - Intersections

    /// Side of the red intersection square, in millimetres on the glass.
    static let intersectionBoxMM: CGFloat = 6.0

    /// White outline around the box, so it reads as a marking sitting on the road rather than
    /// a hole punched through it.
    static let intersectionBorderMM: CGFloat = 0.5

    /// Touch radius for an intersection. The box's half-width, floored so a small box is still
    /// easy to land on. An intersection outranks the road under it, so this is the radius
    /// inside which the junction — not the street — is what the finger feels.
    static var intersectionBoxWidth: CGFloat { PhysicalDimensions.mmToPoints(intersectionBoxMM) }
    static var intersectionHitRadius: CGFloat { max(intersectionBoxWidth / 2, 22) }

    /// Catch radius for the deliberate double tap that opens a junction. Wider than the drag
    /// radius: the user has already found the junction once, and asking them to hit the same
    /// few millimetres twice inside half a second is the wrong test.
    static var intersectionOpenRadius: CGFloat { max(intersectionBoxWidth / 2, 36) }

    // MARK: - Route landmark

    /// The route's start/end dot, drawn directly on the overview map — same size as the
    /// close-up's own dot (`IntersectionScene.routeEndpointDiameterMM`), so it reads as the
    /// same landmark wherever it turns up.
    static let routeEndpointDiameterMM: CGFloat = 6.0
    static let routeEndpointBorderMM: CGFloat = 0.4
    static var routeEndpointDiameter: CGFloat { PhysicalDimensions.mmToPoints(routeEndpointDiameterMM) }
    static var routeEndpointHitRadius: CGFloat { max(routeEndpointDiameter / 2, 22) }

    // MARK: - The searched place

    /// The dot marking where a search sent the map.
    ///
    /// A hair larger than the junction box it usually sits beside, and larger than the route's
    /// own landmarks, because it has to be findable by someone who does not yet know where on
    /// the grid they are — it is the one thing on the screen whose position is not implied by
    /// the street network.
    static let locatorDiameterMM: CGFloat = 6.5
    static let locatorBorderMM: CGFloat = 0.6

    static var locatorDiameter: CGFloat { PhysicalDimensions.mmToPoints(locatorDiameterMM) }
    static var locatorHitRadius: CGFloat { max(locatorDiameter / 2, 24) }

    // MARK: - Resolved metrics

    /// Every device-dependent size, resolved once.
    ///
    /// The values above read the screen's pixel density, which belongs on the main actor,
    /// but the map is projected on a background thread. Snapshotting them into a plain value
    /// keeps UIKit globals out of the background path entirely, and has the side benefit that
    /// one loaded map is internally consistent even if something about the screen changes
    /// underneath it mid-load.
    struct Metrics: Sendable {
        let laneWidthPoints: CGFloat
        let pointsPerMeter: CGFloat
        let roadWidth: CGFloat
        let roadHitRadius: CGFloat
        let intersectionBoxWidth: CGFloat
        let intersectionHitRadius: CGFloat
        let intersectionOpenRadius: CGFloat
        let routeEndpointDiameter: CGFloat
        let routeEndpointHitRadius: CGFloat
    }

    /// Resolve the current device's metrics. Call on the main actor.
    @MainActor
    static func currentMetrics(scale: MapScale = .standard) -> Metrics {
        Metrics(
            laneWidthPoints: laneWidthPoints,
            pointsPerMeter: pointsPerMeter(at: scale),
            roadWidth: roadWidth,
            roadHitRadius: roadHitRadius,
            intersectionBoxWidth: intersectionBoxWidth,
            intersectionHitRadius: intersectionHitRadius,
            intersectionOpenRadius: intersectionOpenRadius,
            routeEndpointDiameter: routeEndpointDiameter,
            routeEndpointHitRadius: routeEndpointHitRadius
        )
    }

    // MARK: - Palette

    static let roadColor = CGColor(red: 0x02 / 255, green: 0x3E / 255, blue: 0x8A / 255, alpha: 1)
    static let backgroundColor = CGColor(gray: 1, alpha: 1)

    /// The intersection marker: NFB's red (#c1121f) with a white outline.
    static let intersectionColor = CGColor(red: 0xC1 / 255, green: 0x12 / 255, blue: 0x1F / 255, alpha: 1)
    static let intersectionBorderColor = CGColor(gray: 1, alpha: 1)

    /// The route overlay: NFB's cyan (#48cae4), drawn above the road it runs on.
    static let routeColor = CGColor(red: 0x48 / 255, green: 0xCA / 255, blue: 0xE4 / 255, alpha: 1)

    /// The route's start/end dot — the same yellow as the close-up's own
    /// (`IntersectionPalette.routeEndpoint`), so the two screens agree on what this landmark
    /// looks like.
    static let routeEndpointColor = CGColor(red: 1, green: 0xD7 / 255, blue: 0, alpha: 1)
    static let routeEndpointBorderColor = CGColor(gray: 1, alpha: 1)

    /// The searched place: green, ringed in white.
    ///
    /// Green because everything nearer the warm end is already spoken for and means something
    /// else — red is a junction, yellow the end of a route, orange a turn in one, pink a kerb.
    /// A dot that means "the thing you asked for" has to be the one colour on the map that
    /// cannot be mistaken for a piece of the route, since one day it will sit on top of one.
    static let locatorColor = CGColor(red: 0x00 / 255, green: 0x9E / 255, blue: 0x4F / 255, alpha: 1)
    static let locatorBorderColor = CGColor(gray: 1, alpha: 1)

    /// The north arrow and scale bar. Dark enough to read on the white background without
    /// competing with the street network for attention.
    static let orientationColor = CGColor(gray: 0.25, alpha: 1)

    /// Labels are drawn along road centrelines, so they always sit on the dark road colour.
    /// White gives roughly 8:1 contrast against it; a dark label would be near-illegible.
    static let labelColor = CGColor(gray: 1, alpha: 1)

    /// Street-name label size. Fixed points, not scaled with the map — this is a visual aid
    /// for sighted and low-vision users, not a tactile element.
    static let labelFontSize: CGFloat = 13
}
