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
        PhysicalDimensions.mmToPoints(blockSpacingMM) / blockLengthMeters
    }

    /// Stroke width for a road. The same for every road — see the note at the top of the file
    /// on why this deliberately does not scale with lane count.
    static var roadWidth: CGFloat { laneWidthPoints }

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
    static func currentMetrics() -> Metrics {
        Metrics(
            laneWidthPoints: laneWidthPoints,
            pointsPerMeter: pointsPerMeter,
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

    /// Labels are drawn along road centrelines, so they always sit on the dark road colour.
    /// White gives roughly 8:1 contrast against it; a dark label would be near-illegible.
    static let labelColor = CGColor(gray: 1, alpha: 1)

    /// Street-name label size. Fixed points, not scaled with the map — this is a visual aid
    /// for sighted and low-vision users, not a tactile element.
    static let labelFontSize: CGFloat = 13
}
