//
//  IntersectionLayout.swift
//  TactileNav
//
//  The four-way intersection, laid out in millimetres on the glass.
//
//  This is the close-up counterpart to the street map. The map is a whole neighbourhood, so
//  it can only afford one kind of line — everything is a road, drawn 4 mm wide, and sidewalks
//  and crossings would crowd every junction into noise. Here there is one junction and a whole
//  screen to spend on it, so the parts a pedestrian actually has to tell apart get room: a
//  wide roadway, a sidewalk set back behind the kerb, a marked crossing, and the kerb ramps at
//  each end of it.
//
//  The layout is schematic — a plus, axis-aligned — rather than a projection of the real
//  bearings. Two reasons. A finger tracing a leg wants a straight line it can follow without
//  drifting off, and the four legs have to be the same length or the shorter ones read as
//  less important. The intersection it *names* is real, and the audio simulation on the same
//  screen runs on the real bearings; only the drawing is idealised.
//
//  Everything below is in millimetres from the centre, converted to points once at build time
//  through `PhysicalDimensions.mmToPoints`. Nothing here is a fraction of the view, so the
//  roadway is the same width under a finger on any device.
//

import CoreGraphics
import Foundation
import TactileMapCore

// MARK: - What the finger can land on

nonisolated enum IntersectionSurface {
    /// The roadway. Wide, and the one thing you must not be standing on.
    case road
    /// The walkway behind the kerb.
    case sidewalk
    /// The marked crossing over a roadway.
    case crossing
    /// The kerb ramp at either end of a crossing — where you wait, and where you arrive.
    case kerbRamp

    var elementType: TactileElementType {
        switch self {
        case .road: return .road
        case .sidewalk: return .street
        case .crossing: return .crosswalk
        case .kerbRamp: return .landmark
        }
    }

    /// Resolves an overlap. A crossing is painted on top of a road, and a ramp sits at the end
    /// of a crossing, so a tie goes to the smaller, harder-to-find thing.
    var priority: Int {
        switch self {
        case .kerbRamp: return 3
        case .crossing: return 2
        case .sidewalk: return 1
        case .road: return 0
        }
    }
}

// MARK: - Pieces

nonisolated struct IntersectionBand {
    let id: String
    let surface: IntersectionSurface
    let name: String
    /// Centreline in view points.
    let from: CGPoint
    let to: CGPoint
    let width: CGFloat
    /// Half-width plus a floor, so a thin line is still catchable.
    let hitRadius: CGFloat
}

nonisolated struct IntersectionDot {
    let id: String
    let name: String
    let center: CGPoint
    let diameter: CGFloat
    let hitRadius: CGFloat
}

// MARK: - Layout

nonisolated struct IntersectionLayout {

    // MARK: Physical constants (millimetres on the glass)

    /// The roadway. Three times the width of a street line on the map — this is the one
    /// surface a pedestrian has to recognise instantly, and at this zoom there is room for it.
    static let roadWidthMM: CGFloat = 12.0
    static let sidewalkWidthMM: CGFloat = 4.0
    /// Width of one painted bar, across the direction you walk.
    static let crossingStripeWidthMM: CGFloat = 2.8
    static let crossingStripeCount = 3
    /// How wide the crossing is — the band you stay inside while crossing.
    ///
    /// Only slightly wider than the sidewalk it continues. Much wider and the crossings stop
    /// reading as part of the same line and start reading as four blocks laid over the
    /// junction, which is the opposite of the shape a walker needs to see.
    static let crossingWidthMM: CGFloat = 5.0
    static let kerbRampDiameterMM: CGFloat = 5.0

    /// Distance from the centre to a sidewalk's centreline, and to the crossings.
    ///
    /// The sidewalks form a square around the junction and the four crossings are the sides of
    /// that square — a crossing is collinear with the sidewalk it continues, bridging the gap
    /// from one corner to the next. That is how a real junction reads to someone walking it:
    /// you follow the sidewalk, the kerb drops, you cross, and you are back on the sidewalk.
    ///
    /// Wide enough that a crossing clears the roadway it spans with room to spare.
    static let sidewalkOffsetMM: CGFloat = 18.0

    // MARK: Touch floors (points)

    /// Below about this, a line is drawn but cannot reliably be found by a moving finger.
    static let minimumHitRadius: CGFloat = 18
    static let dotHitRadius: CGFloat = 22

    // MARK: Contents

    let bands: [IntersectionBand]
    let dots: [IntersectionDot]
    let size: CGSize
    let center: CGPoint
    /// The streets this junction is made of, for what gets spoken.
    let alongName: String
    let acrossName: String

    // MARK: Build

    /// Lays the junction out to fill `size`.
    ///
    /// `alongName` runs east–west and `acrossName` north–south, matching how they are drawn.
    static func build(size: CGSize, alongName: String, acrossName: String) -> IntersectionLayout {
        let mm = { PhysicalDimensions.mmToPoints($0) }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        let roadWidth = mm(roadWidthMM)
        let sidewalkWidth = mm(sidewalkWidthMM)
        let sidewalkOffset = mm(sidewalkOffsetMM)
        let crossingWidth = mm(crossingWidthMM)

        // Legs run past the edge of the view on every side. Using the *longer* edge for both
        // axes is what guarantees that: sizing to the shorter one leaves the legs on the long
        // axis stopping in mid-air, and a leg that visibly ends reads as a dead end rather
        // than as a street carrying on.
        let reach = max(size.width, size.height)

        var bands: [IntersectionBand] = []
        var dots: [IntersectionDot] = []

        func band(_ id: String, _ surface: IntersectionSurface, _ name: String,
                  _ from: CGPoint, _ to: CGPoint, _ width: CGFloat) {
            bands.append(IntersectionBand(
                id: id, surface: surface, name: name, from: from, to: to, width: width,
                hitRadius: max(width / 2, minimumHitRadius)))
        }

        // --- Roadways: two bands crossing at the centre.
        band("road-ew", .road, alongName,
             CGPoint(x: center.x - reach, y: center.y),
             CGPoint(x: center.x + reach, y: center.y), roadWidth)
        band("road-ns", .road, acrossName,
             CGPoint(x: center.x, y: center.y - reach),
             CGPoint(x: center.x, y: center.y + reach), roadWidth)

        // --- Sidewalks: one each side of each roadway, broken at the junction so the four
        // corners read as corners rather than as a continuous ring.
        for sign in [CGFloat(-1), CGFloat(1)] {
            let offset = sidewalkOffset * sign
            // y grows downward, so a negative offset is north; x grows east.
            let alongSide = sign < 0 ? "North" : "South"
            let acrossSide = sign < 0 ? "West" : "East"

            band("walk-ew-\(alongSide)-west", .sidewalk, "\(alongSide) sidewalk, \(alongName)",
                 CGPoint(x: center.x - reach, y: center.y + offset),
                 CGPoint(x: center.x - sidewalkOffset, y: center.y + offset), sidewalkWidth)
            band("walk-ew-\(alongSide)-east", .sidewalk, "\(alongSide) sidewalk, \(alongName)",
                 CGPoint(x: center.x + sidewalkOffset, y: center.y + offset),
                 CGPoint(x: center.x + reach, y: center.y + offset), sidewalkWidth)

            band("walk-ns-\(acrossSide)-north", .sidewalk, "\(acrossSide) sidewalk, \(acrossName)",
                 CGPoint(x: center.x + offset, y: center.y - reach),
                 CGPoint(x: center.x + offset, y: center.y - sidewalkOffset), sidewalkWidth)
            band("walk-ns-\(acrossSide)-south", .sidewalk, "\(acrossSide) sidewalk, \(acrossName)",
                 CGPoint(x: center.x + offset, y: center.y + sidewalkOffset),
                 CGPoint(x: center.x + offset, y: center.y + reach), sidewalkWidth)
        }

        // --- Crossings: the four sides of the sidewalk square, each bridging the gap between
        // two corners and spanning the roadway that runs between them.
        //
        // The north and south crossings run east–west, so they are the ones that take you over
        // the north–south street; the east and west crossings are the other way round. Naming
        // the street you are stepping into the traffic of is the whole point of the label.
        let corner = sidewalkOffset
        let crossings: [(id: String, label: String, from: CGPoint, to: CGPoint, crosses: String)] = [
            ("north", "North",
             CGPoint(x: center.x - corner, y: center.y - corner),
             CGPoint(x: center.x + corner, y: center.y - corner), acrossName),
            ("south", "South",
             CGPoint(x: center.x - corner, y: center.y + corner),
             CGPoint(x: center.x + corner, y: center.y + corner), acrossName),
            ("west", "West",
             CGPoint(x: center.x - corner, y: center.y - corner),
             CGPoint(x: center.x - corner, y: center.y + corner), alongName),
            ("east", "East",
             CGPoint(x: center.x + corner, y: center.y - corner),
             CGPoint(x: center.x + corner, y: center.y + corner), alongName),
        ]

        for crossing in crossings {
            band("cross-\(crossing.id)", .crossing,
                 "\(crossing.label) crossing, across \(crossing.crosses)",
                 crossing.from, crossing.to, crossingWidth)
        }

        // --- Kerb ramps, one at each of the four corners.
        //
        // A corner is shared by two crossings, so there are four ramps and not eight — which
        // is also how it works on the ground: you stand on one ramp and choose which of the
        // two crossings to take.
        let corners: [(String, CGPoint)] = [
            ("north-west", CGPoint(x: center.x - corner, y: center.y - corner)),
            ("north-east", CGPoint(x: center.x + corner, y: center.y - corner)),
            ("south-west", CGPoint(x: center.x - corner, y: center.y + corner)),
            ("south-east", CGPoint(x: center.x + corner, y: center.y + corner)),
        ]
        for (name, point) in corners {
            dots.append(IntersectionDot(
                id: "ramp-\(name)",
                name: "Kerb ramp, \(name.replacingOccurrences(of: "-", with: " ")) corner",
                center: point,
                diameter: mm(kerbRampDiameterMM),
                hitRadius: dotHitRadius))
        }

        return IntersectionLayout(bands: bands, dots: dots, size: size, center: center,
                                  alongName: alongName, acrossName: acrossName)
    }

    // MARK: Lookup

    /// What is under a point, or nil for the space between things.
    ///
    /// Nearest thing wins, with `priority` breaking a near-tie — a crossing really is painted
    /// on top of the roadway, and a ramp really does sit at the end of a crossing, so when two
    /// are equally close the smaller one is the honest answer.
    func hit(_ point: CGPoint) -> (id: String, surface: IntersectionSurface, name: String)? {
        var best: (id: String, surface: IntersectionSurface, name: String, distance: CGFloat)?

        func consider(_ id: String, _ surface: IntersectionSurface, _ name: String, _ distance: CGFloat) {
            guard let current = best else {
                best = (id, surface, name, distance)
                return
            }
            if distance < current.distance - Self.tieBreak {
                best = (id, surface, name, distance)
            } else if abs(distance - current.distance) <= Self.tieBreak,
                      surface.priority > current.surface.priority {
                best = (id, surface, name, distance)
            }
        }

        for dot in dots {
            let distance = hypot(point.x - dot.center.x, point.y - dot.center.y)
            if distance <= dot.hitRadius { consider(dot.id, .kerbRamp, dot.name, distance) }
        }
        for band in bands {
            let distance = distanceToSegment(point, band.from, band.to)
            if distance <= band.hitRadius { consider(band.id, band.surface, band.name, distance) }
        }
        return best.map { ($0.id, $0.surface, $0.name) }
    }

    /// How close two things have to be before priority, rather than distance, decides.
    private static let tieBreak: CGFloat = 8
}
