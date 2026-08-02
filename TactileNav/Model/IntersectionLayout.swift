//
//  IntersectionLayout.swift
//  TactileNav
//
//  The four-way intersection, laid out in millimetres on the glass.
//
//  This is the close-up counterpart to the street map. The map is a whole neighbourhood, so
//  it can only afford one kind of line — everything is a road, drawn 4 mm wide, and sidewalks
//  and crossings would crowd every junction into noise. Here there is one junction and a whole
//  screen to spend on it, so the three parts a pedestrian actually has to tell apart get room:
//  a wide roadway, a sidewalk set back behind the kerb, and a marked crossing between them.
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

    var elementType: TactileElementType {
        switch self {
        case .road: return .road
        case .sidewalk: return .street
        case .crossing: return .crosswalk
        }
    }

    /// Resolves an overlap. A crossing is painted over a roadway, so a tie goes to the
    /// crossing — the thinner, harder-to-find thing.
    var priority: Int {
        switch self {
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

// MARK: - Layout

nonisolated struct IntersectionLayout {

    // MARK: Physical constants (millimetres on the glass)

    /// The roadway. Three times the width of a street line on the wider map — this is the one
    /// surface a pedestrian has to recognise instantly, and at this zoom there is room for it.
    static let roadWidthMM: CGFloat = 12.0
    static let sidewalkWidthMM: CGFloat = 4.0
    /// A crossing is a thin line, the same weight as the paint on the ground.
    static let crossingWidthMM: CGFloat = 2.8
    /// Length of one painted bar along the direction you walk.
    static let crossingBarLengthMM: CGFloat = 1.4
    static let crossingBarCount = 3
    /// Kerb: bare ground between the edge of the roadway and the near edge of the sidewalk.
    static let kerbGapMM: CGFloat = 1.0

    /// Distance from the centre to a sidewalk's centreline, and to the crossings.
    ///
    /// Derived, not chosen, so the pieces cannot drift into each other if one of them is
    /// retuned: half the roadway, then the width of the crossing that runs along this line,
    /// then the kerb, then half the sidewalk itself. It works out at 11.8 mm.
    ///
    /// The sidewalks form a square around the junction and the four crossings are the sides of
    /// that square — a crossing is collinear with the sidewalk it continues, bridging the gap
    /// from one corner to the next. That is how a junction reads to someone walking it: follow
    /// the sidewalk, the kerb drops, cross, and you are back on the sidewalk.
    static var sidewalkOffsetMM: CGFloat {
        roadWidthMM / 2 + crossingWidthMM + kerbGapMM + sidewalkWidthMM / 2
    }

    // MARK: Touch floor (points)

    /// Below about this, a line is drawn but cannot reliably be found by a moving finger. The
    /// crossings in particular are thinner than this on purpose — they are painted lines, and
    /// widening the drawing to make them catchable would misrepresent the ground.
    static let minimumHitRadius: CGFloat = 18

    // MARK: Contents

    let bands: [IntersectionBand]
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

        return IntersectionLayout(bands: bands, size: size, center: center,
                                  alongName: alongName, acrossName: acrossName)
    }

    // MARK: Lookup

    /// What is under a point, or nil for the space between things.
    ///
    /// Nearest thing wins, with `priority` breaking a near-tie — a crossing really is painted
    /// over the roadway, so when the two are equally close the crossing is the honest answer.
    func hit(_ point: CGPoint) -> (id: String, surface: IntersectionSurface, name: String)? {
        var best: (id: String, surface: IntersectionSurface, name: String, distance: CGFloat)?

        for band in bands {
            let distance = distanceToSegment(point, band.from, band.to)
            guard distance <= band.hitRadius else { continue }
            guard let current = best else {
                best = (band.id, band.surface, band.name, distance)
                continue
            }
            if distance < current.distance - Self.tieBreak {
                best = (band.id, band.surface, band.name, distance)
            } else if abs(distance - current.distance) <= Self.tieBreak,
                      band.surface.priority > current.surface.priority {
                best = (band.id, band.surface, band.name, distance)
            }
        }
        return best.map { ($0.id, $0.surface, $0.name) }
    }

    /// How close two things have to be before priority, rather than distance, decides.
    private static let tieBreak: CGFloat = 8
}
