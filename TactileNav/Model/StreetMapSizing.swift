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
//  Two separate things both come off the 4 mm lane constant, and it is worth keeping them
//  apart:
//
//    • **Line width.** Every road is drawn 4 mm wide, whatever its lane count. 4 mm is a
//      perceptual constant, not a measurement of asphalt — it is about the narrowest line a
//      fingertip can reliably follow. Scaling it by lane count sounds more faithful but is
//      self-defeating: a four-lane road would be 16 mm, wider than a fingertip, so it stops
//      being a line you can trace and becomes a plane with edges you cannot feel. It also
//      buries the sidewalk beside it under the paint.
//
//    • **Map scale.** 4 mm on the glass represents one real 3.3 m lane, and that is what sets
//      metres to points. So the *spacing* of the network — how far apart two streets are, how
//      wide a junction is — stays true to the ground even though the lines themselves are a
//      constant width. That is how street maps have always worked.
//

import CoreGraphics
import TactileMapCore

nonisolated enum StreetMapSizing {

    // MARK: - Physical constants (millimetres on the glass)

    /// Width of one traffic lane, and the width every road line is drawn at.
    static let laneWidthMM: CGFloat = 4.0

    /// Sidewalks are a fixed width regardless of the street they follow — a real
    /// sidewalk is narrower than a lane, but below ~4 mm a line is easy to slip off.
    static let sidewalkWidthMM: CGFloat = 4.0

    /// Width of a single crosswalk stripe.
    static let crosswalkStripeWidthMM: CGFloat = 2.8

    /// Number of stripes drawn per crossing.
    static let crosswalkStripeCount = 3

    /// Shortest a stripe may be, in points.
    ///
    /// The stripe length itself is a fraction of the crossing's span (see
    /// `crosswalkStripeLength`) rather than a fixed number of points. A fixed length is fine
    /// when roads are a few points wide, but at true lane scale a crossing spans ~100 points,
    /// and three 6-point dashes across it read as specks rather than as a marked crossing.
    static let crosswalkStripeMinimumLengthPoints: CGFloat = 6

    /// Stripe length for a crossing of the given span: three stripes separated by four equal
    /// gaps, so the pattern is centred and fills the crossing at any scale.
    static func crosswalkStripeLength(span: CGFloat) -> CGFloat {
        max(span / CGFloat(crosswalkStripeCount * 2 + 1), crosswalkStripeMinimumLengthPoints)
    }

    // MARK: - Real-world reference

    /// Standard urban travel lane. The single number tying millimetres to metres.
    static let laneWidthMeters: CGFloat = 3.3

    // MARK: - Derived scale

    /// One lane's width in screen points on this device.
    static var laneWidthPoints: CGFloat {
        PhysicalDimensions.mmToPoints(laneWidthMM)
    }

    /// Screen points per real-world metre.
    ///
    /// Derived, never chosen: `laneWidthPoints / laneWidthMeters`. On a 460 ppi phone this
    /// is ≈ 7.3 pt/m, on an iPad ≈ 6.3 — the physical size is constant, the point count
    /// varies with pixel density.
    static var pointsPerMeter: CGFloat {
        laneWidthPoints / laneWidthMeters
    }

    /// Stroke width for a road. The same for every road — see the note at the top of the file
    /// on why this deliberately does not scale with lane count.
    static var roadWidth: CGFloat { laneWidthPoints }

    static var sidewalkWidth: CGFloat {
        PhysicalDimensions.mmToPoints(sidewalkWidthMM)
    }

    static var crosswalkStripeWidth: CGFloat {
        PhysicalDimensions.mmToPoints(crosswalkStripeWidthMM)
    }

    // MARK: - Hit-test radii (screen points)

    /// Touch radius for a road.
    ///
    /// Wider than the drawn line on purpose. Half a 4 mm line is only ~12 pt, and on a dense
    /// real street grid that asks a finger to trace within about a metre and a half of a
    /// centreline. Floors in the low twenties are the established practice for exactly this
    /// reason, and it stays under the sidewalk radius so a sidewalk beside a road is still
    /// reachable rather than being swallowed.
    static let roadHitRadius: CGFloat = 22

    /// Crossings are short and easy to miss between two streets, so they get a wider
    /// catch radius than their 2.8 mm stripe would imply.
    static let crosswalkHitRadius: CGFloat = 34

    /// Sidewalks sit close to the roadway; a floor of 26 pt keeps them reachable without
    /// swallowing the road beside them.
    static let sidewalkHitRadius: CGFloat = 26

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
        let sidewalkWidth: CGFloat
        let crosswalkStripeWidth: CGFloat
        let roadWidth: CGFloat
        let roadHitRadius: CGFloat
        let sidewalkHitRadius: CGFloat
        let crosswalkHitRadius: CGFloat
    }

    /// Resolve the current device's metrics. Call on the main actor.
    @MainActor
    static func currentMetrics() -> Metrics {
        Metrics(
            laneWidthPoints: laneWidthPoints,
            pointsPerMeter: pointsPerMeter,
            sidewalkWidth: sidewalkWidth,
            crosswalkStripeWidth: crosswalkStripeWidth,
            roadWidth: roadWidth,
            roadHitRadius: roadHitRadius,
            sidewalkHitRadius: sidewalkHitRadius,
            crosswalkHitRadius: crosswalkHitRadius
        )
    }

    // MARK: - Palette

    static let roadColor = CGColor(red: 0x02 / 255, green: 0x3E / 255, blue: 0x8A / 255, alpha: 1)
    static let sidewalkColor = CGColor(red: 0x9E / 255, green: 0x9E / 255, blue: 0x9E / 255, alpha: 1)
    static let crosswalkColor = CGColor(gray: 1, alpha: 1)
    static let backgroundColor = CGColor(gray: 1, alpha: 1)

    /// Labels are drawn along road centrelines, so they always sit on the dark road colour.
    /// White gives roughly 8:1 contrast against it; a dark label would be near-illegible.
    static let labelColor = CGColor(gray: 1, alpha: 1)

    /// Street-name label size. Fixed points, not scaled with the map — this is a visual aid
    /// for sighted and low-vision users, not a tactile element. Roads are ~24 pt per lane
    /// wide here, so a 13 pt label sits comfortably inside even a single-lane way.
    static let labelFontSize: CGFloat = 13
}
