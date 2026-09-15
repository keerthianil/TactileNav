//
//  MapSurface.swift
//  TactileNav
//
//  What a map is made of, what it is drawn at, and what it counts in.
//
//  The reference tool this follows lets a reader decide what goes on the sheet before it is
//  made: streets, footpaths, service roads, railways, each switched on or off, at a chosen
//  scale. That is not a preferences panel. **A tactile map you can declutter is worth more
//  under a finger than a complete one** — every line you add is another thing to be told apart
//  from its neighbours, and past a certain density a street network stops being readable at all.
//  Someone learning one junction wants streets only; someone working out how to get through a
//  block on foot wants the paths and nothing else.
//

import CoreGraphics
import Foundation
import TactileMapCore

// MARK: - What a line is

/// The kind of thing a line on the map represents.
///
/// Each gets its own width, colour and haptic signature, because a finger can only tell two
/// lines apart if they actually feel different — drawing them the same and only naming them
/// differently puts the whole burden on speech, which is the slow channel.
nonisolated enum MapSurfaceCategory: String, CaseIterable, Sendable, Hashable {
    /// The drivable, named street network. The map's backbone.
    case street
    /// Footways, pavements and pedestrianised streets — where a pedestrian may actually walk.
    case path
    /// Back lanes, car park aisles, delivery yards. Drivable, rarely named, and dense.
    case serviceRoad
    /// Rails. Something to cross, never something to walk along.
    case railway

    /// The element type in the extract that produces this.
    var documentType: TactileElementType {
        switch self {
        case .street: return .road
        case .path: return .street
        case .serviceRoad: return TactileElementType(rawValue: "service")
        case .railway: return TactileElementType(rawValue: "railway")
        }
    }

    /// Shown on the options screen, and spoken.
    var label: String {
        switch self {
        case .street: return "Streets"
        case .path: return "Paths"
        case .serviceRoad: return "Service Roads"
        case .railway: return "Railways"
        }
    }

    /// What turning it on actually does, for the reader deciding whether to.
    var explanation: String {
        switch self {
        case .street: return "The named street network. The backbone of the map."
        case .path: return "Pavements and footpaths. Detailed, and crowded at this scale."
        case .serviceRoad: return "Back lanes and car park aisles. Mostly unnamed."
        case .railway: return "Railway lines. Something to cross, not to walk along."
        }
    }

    /// Said when a finger lands on one of these and the line has no name of its own.
    var unnamed: String {
        switch self {
        case .street: return "Street"
        case .path: return "Path"
        case .serviceRoad: return "Service road"
        case .railway: return "Railway"
        }
    }
}

// MARK: - What is on the map

/// The categories a map was built with.
///
/// Applied when the map is *built*, not when it is drawn: a line that is switched off is not in
/// the spatial index either, so it cannot be felt, cannot be spoken, and costs nothing to skip.
/// Switching a category on is a rebuild, which is also how scale works — see `MapScale`.
nonisolated struct MapFeatureSet: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let streets = MapFeatureSet(rawValue: 1 << 0)
    static let paths = MapFeatureSet(rawValue: 1 << 1)
    static let serviceRoads = MapFeatureSet(rawValue: 1 << 2)
    static let railways = MapFeatureSet(rawValue: 1 << 3)

    /// Streets and nothing else — the reference tool's default, and the only thing the
    /// Congress Square map has ever drawn.
    static let `default`: MapFeatureSet = [.streets]

    init(_ categories: [MapSurfaceCategory]) {
        self = categories.reduce(into: MapFeatureSet()) { $0.insert(MapFeatureSet(category: $1)) }
    }

    init(category: MapSurfaceCategory) {
        switch category {
        case .street: self = .streets
        case .path: self = .paths
        case .serviceRoad: self = .serviceRoads
        case .railway: self = .railways
        }
    }

    func contains(_ category: MapSurfaceCategory) -> Bool {
        contains(MapFeatureSet(category: category))
    }

    var categories: [MapSurfaceCategory] {
        MapSurfaceCategory.allCases.filter { contains($0) }
    }

    /// "Streets and paths" — for an announcement, not a label.
    var spoken: String {
        let names = categories.map { $0.label.lowercased() }
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

// MARK: - How much ground fits

/// How much of the city the screen holds.
///
/// **This is not zoom, and the difference matters.** Zoom scales everything, which would make
/// the lines themselves wider or narrower and break the one promise the whole map rests on: a
/// road is 4 mm under the finger on every device, because that is about the narrowest line a
/// fingertip can reliably follow. What changes here is only how much *ground* a millimetre
/// stands for. The lines stay exactly as wide as they were; the blocks get closer together or
/// further apart. That is what a paper map means by scale too, and it is why the reference tool
/// offers a handful of fixed ratios rather than a pinch gesture.
///
/// Changing it rebuilds the map at a new metres-to-points, the same path the first load takes.
nonisolated enum MapScale: String, CaseIterable, Sendable, Identifiable {
    /// One junction and its approaches.
    case close
    /// The default, and what the Congress Square map has always used.
    case standard
    /// A few blocks at once — as wide as stays readable by finger.
    case wide

    var id: String { rawValue }

    /// Millimetres on the glass per `StreetMapSizing.blockLengthMeters` of ground.
    var blockSpacingMM: CGFloat {
        switch self {
        case .close: return 80
        case .standard: return 40
        case .wide: return 24
        }
    }

    /// The ratio a paper map would print, e.g. 1:3000. Derived, never stored — it is
    /// `blockSpacingMM` and the block length saying the same thing a second way.
    var ratio: Int {
        Int((StreetMapSizing.blockLengthMeters * 1000 / blockSpacingMM).rounded())
    }

    var label: String { "1:\(ratio)" }

    /// What that ratio means with a finger on it, which is the part a reader can act on.
    var explanation: String {
        switch self {
        case .close: return "One junction, close up"
        case .standard: return "A block or two"
        case .wide: return "Several blocks"
        }
    }

    /// **Why the range stops here.** A phone is about 67 mm across and a sheet of the reference
    /// tool's paper is 292 mm, so the same ratio shows four times less ground — and the tool's
    /// widest settings simply have no readable equivalent. At 1:12500 a 120 m block would be
    /// 9.6 mm wide against 4 mm lines, leaving about 5 mm of clear space between parallel
    /// streets: narrower than the fingertip meant to tell them apart. Panning covers the
    /// distance instead.
    static let widestReadable = MapScale.wide
}

// MARK: - What distances are counted in

nonisolated enum DistanceUnit: String, CaseIterable, Sendable, Identifiable {
    case feet
    case meters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .feet: return "Feet"
        case .meters: return "Meters"
        }
    }

    /// A ground distance, said the way somebody using these units would say it.
    ///
    /// Rounded hard on purpose. A spoken "eight hundred and forty-three feet" is a worse answer
    /// than "840 feet": the extra digits take longer to hear and none of them change what you
    /// do next.
    func spell(_ meters: CGFloat) -> String {
        switch self {
        case .meters:
            return meters >= 1000
                ? String(format: "%.1f km", meters / 1000)
                : "\(Int((meters / 10).rounded()) * 10) m"
        case .feet:
            let feet = meters * 3.280_84
            return feet >= 5280
                ? String(format: "%.1f miles", feet / 5280)
                : "\(Int((feet / 10).rounded()) * 10) ft"
        }
    }
}
