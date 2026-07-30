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
//  The map's geometric scale is *anchored* to the lane width rather than chosen
//  independently: 4 mm on the glass is defined to be one real traffic lane. So a two-lane
//  street draws 8 mm wide, a four-lane arterial 16 mm, and the drawn roadway matches the
//  real roadway at map scale. That anchor is what makes the street geometry read correctly
//  instead of being a diagram with arbitrary line weights.
//

import CoreGraphics
import TactileMapCore

nonisolated enum StreetMapSizing {

    // MARK: - Physical constants (millimetres on the glass)

    /// Width of one traffic lane. Also the minimum width of any road, so a
    /// single-lane way is still wide enough to trace.
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

    /// Stroke width for a road with the given lane count, floored at one lane.
    static func roadWidth(lanes: Int) -> CGFloat {
        laneWidthPoints * CGFloat(max(lanes, 1))
    }

    static var sidewalkWidth: CGFloat {
        PhysicalDimensions.mmToPoints(sidewalkWidthMM)
    }

    static var crosswalkStripeWidth: CGFloat {
        PhysicalDimensions.mmToPoints(crosswalkStripeWidthMM)
    }

    // MARK: - Hit-test radii (screen points)

    /// Minimum touch radius for a line, so a thin feature is still findable. Roads use
    /// half their own stroke width once that exceeds this.
    static var minimumLineHitRadius: CGFloat {
        laneWidthPoints / 2
    }

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
        let minimumLineHitRadius: CGFloat
        let sidewalkHitRadius: CGFloat
        let crosswalkHitRadius: CGFloat

        func roadWidth(lanes: Int) -> CGFloat {
            laneWidthPoints * CGFloat(max(lanes, 1))
        }
    }

    /// Resolve the current device's metrics. Call on the main actor.
    @MainActor
    static func currentMetrics() -> Metrics {
        Metrics(
            laneWidthPoints: laneWidthPoints,
            pointsPerMeter: pointsPerMeter,
            sidewalkWidth: sidewalkWidth,
            crosswalkStripeWidth: crosswalkStripeWidth,
            minimumLineHitRadius: minimumLineHitRadius,
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
