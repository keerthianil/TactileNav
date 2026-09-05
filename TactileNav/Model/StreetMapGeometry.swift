//
//  StreetMapGeometry.swift
//  TactileNav
//
//  Turns a loaded map document into everything the canvas and the finger need, once.
//
//  The document is already in metres with y growing south, and a screen's y also grows
//  downward, so projecting to content points is a single multiply by
//  `StreetMapSizing.pointsPerMeter` — north is up with no flip and no map projection at
//  runtime. Because the whole map lives in one fixed coordinate space, hit-testing is
//  arithmetic against a precomputed grid rather than a per-vertex coordinate conversion on
//  every touch sample, which is what keeps a 60 Hz drag from dropping samples. Dropped
//  samples are how a finger skips a 4 mm line without ever feeling it.
//

import CoreGraphics
import CoreText
import Foundation
import TactileMapCore
import TactileMapView

// MARK: - A drawable, touchable road

/// One road, drawn and felt.
///
/// The map is roads and nothing else. Sidewalks and crossings exist in the extract and are
/// deliberately dropped: at city scale they crowd every junction with lines a few millimetres
/// apart, which reads as noise under a finger rather than as a street network. They belong to
/// the intersection view, where there is room for them at a scale where they can be told
/// apart. Here, one surface means one haptic and no ambiguity about what is under the finger.
nonisolated struct StreetFeature {
    let id: String
    let name: String
    /// Polyline in content points.
    let points: [CGPoint]
    let strokeWidth: CGFloat
    let hitRadius: CGFloat
    let lanes: Int
    /// What is spoken when a finger lands here.
    let announcement: String
    /// Bounding box already grown by the larger of the stroke half-width and hit radius.
    let touchBounds: CGRect
    /// Bounding box grown by the stroke half-width only, for draw culling.
    let drawBounds: CGRect
}

// MARK: - A junction where streets cross

/// One arm of a junction: a direction the roadway continues, and the street it carries.
///
/// Named "arm" rather than "leg" because the crossing-audio simulation already owns
/// `IntersectionLeg` for its own fixed four-leg model.
nonisolated struct IntersectionArm {
    /// Compass bearing from the junction centre: 0 is north, 90 is east.
    let bearing: CGFloat
    let streetName: String

    /// The compass point a traveller would actually say, e.g. "north-east".
    var compassLabel: String { IntersectionArm.compassName(for: bearing) }

    static func compassName(for bearing: CGFloat) -> String {
        let names = ["north", "north-east", "east", "south-east",
                     "south", "south-west", "west", "north-west"]
        let sector = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return names[sector]
    }
}

/// A place where two or more differently-named streets meet.
///
/// Straight from OpenStreetMap's own node topology, computed when the extract is built. Two
/// ways that genuinely meet *share a node*; two ways that merely cross on a bridge do not, so
/// using shared nodes is both the real definition of a junction and what keeps grade
/// separations — I-295 over a downtown street — from being reported as intersections. Every
/// shape comes out of it: two-way corners where one street becomes another, T-junctions,
/// four-way crossings and the occasional five- or six-way.
nonisolated struct Intersection {
    let id: String
    /// The distinct streets that meet here, e.g. "Congress Street", "High Street".
    let streetNames: [String]
    /// Every arm, in bearing order — two for a corner, three for a T, four for a crossing.
    let legs: [IntersectionArm]
    /// Centre of the junction, in content points.
    let position: CGPoint
    /// What is spoken when a finger lands here.
    let announcement: String
    /// Side of the drawn box, in content points.
    let boxWidth: CGFloat
    let hitRadius: CGFloat
    /// Bounding box grown by the touch radius, for the spatial index.
    let touchBounds: CGRect
    /// Bounding box grown by the box half-width, for draw culling.
    let drawBounds: CGRect

    /// "Four-way intersection of Congress Street and High Street".
    static func announcement(shape: Int, streets: [String]) -> String {
        let shapeWord: String
        switch shape {
        case 2: shapeWord = "Two-way"
        case 3: shapeWord = "Three-way"
        case 4: shapeWord = "Four-way"
        case 5: shapeWord = "Five-way"
        case 6: shapeWord = "Six-way"
        default: shapeWord = "\(shape)-way"
        }
        switch streets.count {
        case 0: return "\(shapeWord) intersection"
        case 1: return "\(shapeWord) intersection at \(streets[0])"
        case 2: return "\(shapeWord) intersection of \(streets[0]) and \(streets[1])"
        default:
            let head = streets.dropLast().joined(separator: ", ")
            return "\(shapeWord) intersection of \(head) and \(streets.last!)"
        }
    }
}

// MARK: - Footways, kept for the close-up view

/// A sidewalk or a marked crossing, straight from the extract.
///
/// These are deliberately *not* drawn on the city-scale map — at that zoom they crowd every
/// junction with lines a few millimetres apart and read as noise. They are kept because the
/// intersection close-up has the room to show them, and showing the real ones is the whole
/// point: the crossings and sidewalks around a junction are exactly what a pedestrian needs.
nonisolated struct Footway {
    enum Kind { case sidewalk, crossing }
    let id: String
    let name: String
    let kind: Kind
    /// Polyline in content points, the same space as the roads.
    let points: [CGPoint]
    let bounds: CGRect
}

// MARK: - What the finger is on

/// The result of probing a point on the map. A junction outranks the road it sits on — it is
/// where the roads cross, so the finger is on both, and the junction is the more useful thing
/// to name.
nonisolated enum MapProbe {
    case road(StreetFeature)
    case intersection(Intersection)

    /// Identity for dedup, so feedback fires once per thing and not once per touch sample.
    var id: String {
        switch self {
        case .road(let road): return "road:" + road.id
        case .intersection(let junction): return "int:" + junction.id
        }
    }
}

// MARK: - A placed street-name label

nonisolated struct StreetLabel {
    let line: CTLine
    /// Baseline origin in content points, already offset so the text is centred on the road.
    let position: CGPoint
    let rotation: CGFloat
    let bounds: CGRect
}

// MARK: - The assembled map

/// Converts a real-world latitude/longitude into this map's content-point space — the same
/// projection the extract's own roads were built from (equirectangular, referenced to the
/// request bounding box, then normalised to the content box the way `StreetMap.build` does).
///
/// Exists so geometry from outside the extract — a routing API's response, say — can be drawn
/// in the same coordinate space as the map without inventing a second, separate alignment. `nil`
/// on `StreetMap` only when the document shipped without the bounding-box metadata this needs.
nonisolated struct GeographicProjection {
    let bbox: StreetMapExtras.BoundingBox
    /// Longitude's metres-per-degree at this bbox's latitude — narrower than latitude's fixed
    /// 111,320 m/degree the further from the equator you are, so this has to be computed per
    /// map rather than assumed constant.
    let metersPerDegreeLongitude: CGFloat
    let scale: CGFloat
    let origin: CGPoint

    private static let metersPerDegreeLatitude: CGFloat = 111_320.0

    func project(lat: Double, lon: Double) -> CGPoint {
        let xMeters = (CGFloat(lon) - CGFloat(bbox.west)) * metersPerDegreeLongitude
        let yMeters = (CGFloat(bbox.north) - CGFloat(lat)) * Self.metersPerDegreeLatitude
        return CGPoint(x: xMeters * scale - origin.x, y: yMeters * scale - origin.y)
    }
}

nonisolated struct StreetMap {

    let features: [StreetFeature]
    let labels: [StreetLabel]
    /// Junctions from OpenStreetMap's node topology — see `Intersection`.
    let intersections: [Intersection]
    /// Sidewalks and crossings, for the intersection close-up — see `Footway`.
    let footways: [Footway]
    let contentSize: CGSize
    /// Where to open the viewport, from the document rather than a hardcoded offset.
    let initialCenter: CGPoint
    let hitConfig: HitDetectionConfigValues
    /// The device metrics this map was projected with.
    let metrics: StreetMapSizing.Metrics
    /// How to place a real lat/lon on this map — see `GeographicProjection`.
    let geographicProjection: GeographicProjection?

    private let index: UniformGrid
    private let labelIndex: UniformGrid
    private let intersectionIndex: UniformGrid
    private let footwayIndex: UniformGrid

    /// The subset of `HitDetectionConfig` this map uses, captured at build time.
    struct HitDetectionConfigValues {
        let velocityDivisor: CGFloat
        let velocityBonusMax: CGFloat
        let updateThreshold: TimeInterval
    }

    // MARK: Lookup

    /// The road under a content-space point, or nil for empty space.
    ///
    /// Nearest centreline wins. The radius grows with finger speed: a fast drag samples
    /// further apart, so a fixed radius lets the finger step over a line between two samples
    /// and feel nothing.
    func feature(at point: CGPoint, velocity: CGFloat) -> StreetFeature? {
        let bonus = min(velocity / hitConfig.velocityDivisor, hitConfig.velocityBonusMax)

        var best: (feature: StreetFeature, distance: CGFloat)?
        for featureIndex in index.candidates(near: point, radius: bonus) {
            let feature = features[featureIndex]
            guard feature.touchBounds.insetBy(dx: -bonus, dy: -bonus).contains(point) else { continue }
            let distance = distanceToPolyline(point, feature.points)
            guard distance <= feature.hitRadius + bonus else { continue }
            if best == nil || distance < best!.distance {
                best = (feature, distance)
            }
        }
        return best?.feature
    }

    /// What is under a content-space point: a junction, a road, or nothing.
    ///
    /// A junction wins whenever the finger is within its radius, because it sits exactly where
    /// the roads cross — the finger is already on the road, and the junction is the thing worth
    /// naming. This is the priority NFB uses on its overview map. Off a junction it falls
    /// through to the nearest road.
    func probe(at point: CGPoint, velocity: CGFloat) -> MapProbe? {
        let bonus = min(velocity / hitConfig.velocityDivisor, hitConfig.velocityBonusMax)

        var best: (junction: Intersection, distance: CGFloat)?
        for junctionIndex in intersectionIndex.candidates(near: point, radius: bonus) {
            let junction = intersections[junctionIndex]
            let distance = hypot(point.x - junction.position.x, point.y - junction.position.y)
            guard distance <= junction.hitRadius + bonus else { continue }
            if best == nil || distance < best!.distance {
                best = (junction, distance)
            }
        }
        if let best { return .intersection(best.junction) }
        if let road = feature(at: point, velocity: velocity) { return .road(road) }
        return nil
    }

    /// Features whose ink could land inside `rect`, for tile drawing.
    func features(in rect: CGRect) -> [StreetFeature] {
        index.candidates(intersecting: rect)
            .map { features[$0] }
            .filter { $0.drawBounds.intersects(rect) }
    }

    /// Roads whose centreline passes within `radius` of a point, for the close-up view.
    func roads(near point: CGPoint, within radius: CGFloat) -> [StreetFeature] {
        index.candidates(near: point, radius: radius)
            .map { features[$0] }
            .filter { distanceToPolyline(point, $0.points) <= radius }
    }

    /// Sidewalks and crossings within `radius` of a point, for the close-up view.
    func footways(near point: CGPoint, within radius: CGFloat) -> [Footway] {
        footwayIndex.candidates(near: point, radius: radius)
            .map { footways[$0] }
            .filter { distanceToPolyline(point, $0.points) <= radius }
    }

    /// The junction nearest `point` within `radius`, for the double tap that opens one.
    func intersection(at point: CGPoint, within radius: CGFloat) -> Intersection? {
        var best: (junction: Intersection, distance: CGFloat)?
        for junctionIndex in intersectionIndex.candidates(near: point, radius: radius) {
            let junction = intersections[junctionIndex]
            let distance = hypot(point.x - junction.position.x, point.y - junction.position.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance { best = (junction, distance) }
        }
        return best?.junction
    }

    /// Junctions whose box could land inside `rect`, for drawing.
    func intersections(in rect: CGRect) -> [Intersection] {
        intersectionIndex.candidates(intersecting: rect)
            .map { intersections[$0] }
            .filter { $0.drawBounds.intersects(rect) }
    }

    func labels(in rect: CGRect) -> [StreetLabel] {
        labelIndex.candidates(intersecting: rect)
            .map { labels[$0] }
            .filter { $0.bounds.intersects(rect) }
    }

    /// Nearest road name to a point, used to orient the user after a pan.
    func nearestRoadName(to point: CGPoint, within limit: CGFloat) -> String? {
        var best: (name: String, distance: CGFloat)?
        for featureIndex in index.candidates(near: point, radius: limit) {
            let feature = features[featureIndex]
            let distance = distanceToPolyline(point, feature.points)
            guard distance <= limit else { continue }
            if best == nil || distance < best!.distance {
                best = (feature.name, distance)
            }
        }
        return best?.name
    }

    // MARK: Building

    /// Projects a document into content points and precomputes indices and labels.
    ///
    /// Runs off the main thread — `StreetMap` holds only value types plus immutable
    /// `CTLine`s, so the finished map can cross back to the main actor safely.
    static func build(
        document: TactileMapDocument,
        extras: StreetMapExtras?,
        metrics: StreetMapSizing.Metrics,
        hitConfig: HitDetectionConfig = .default,
        labelFont: CTFont
    ) -> StreetMap {
        let scale = metrics.pointsPerMeter

        // Project first, then normalise, so the content box hugs the real data instead of
        // the request box (the extract keeps a small margin of overhanging geometry).
        var raws: [ProjectedElement] = []
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        // Roads set the content box. Sidewalks and crossings are collected separately below,
        // for the close-up view only — they are never drawn at city scale.
        for element in document.features where element.elementType == .road {
            guard case .lineString(let coordinates) = element.geometry, coordinates.count >= 2 else { continue }
            let points = coordinates.map {
                CGPoint(x: CGFloat($0.x) * scale, y: CGFloat($0.y) * scale)
            }
            for point in points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            raws.append(ProjectedElement(element: element, points: points))
        }

        guard !raws.isEmpty else {
            return StreetMap(
                features: [], labels: [], intersections: [], footways: [],
                contentSize: .zero, initialCenter: .zero,
                hitConfig: .init(velocityDivisor: hitConfig.velocityDivisor,
                                 velocityBonusMax: hitConfig.velocityBonusMax,
                                 updateThreshold: hitConfig.updateThreshold),
                metrics: metrics,
                geographicProjection: nil,
                index: UniformGrid(cellSize: 128, entries: []),
                labelIndex: UniformGrid(cellSize: 512, entries: []),
                intersectionIndex: UniformGrid(cellSize: 256, entries: []),
                footwayIndex: UniformGrid(cellSize: 256, entries: [])
            )
        }

        // Pad by the widest stroke so no ink is clipped at the content edge.
        let pad = metrics.roadWidth
        let origin = CGPoint(x: minX - pad, y: minY - pad)
        let contentSize = CGSize(width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)

        // Every road is one stroke width and one hit radius, so there is nothing to resolve
        // per element beyond shifting it into the content box.
        let stroke = metrics.roadWidth
        let hitRadius = max(stroke / 2, metrics.roadHitRadius)

        var features: [StreetFeature] = []
        features.reserveCapacity(raws.count)

        for raw in raws {
            let points = raw.points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
            let box = boundingBox(points)
            features.append(StreetFeature(
                id: raw.element.id,
                name: raw.element.properties.name,
                points: points,
                strokeWidth: stroke,
                hitRadius: hitRadius,
                lanes: Int(raw.element.properties.custom["lanes"] ?? "") ?? 1,
                // The bare street name. There is only one kind of thing on this map, so
                // saying what it is adds nothing a finger has not already been told.
                announcement: raw.element.properties.name,
                touchBounds: box.insetBy(dx: -hitRadius, dy: -hitRadius),
                drawBounds: box.insetBy(dx: -stroke, dy: -stroke)
            ))
        }

        let entries = features.enumerated().map {
            UniformGrid.Entry(index: $0.offset, bounds: $0.element.touchBounds)
        }
        let labels = buildLabels(features: features, font: labelFont)
        let labelEntries = labels.enumerated().map {
            UniformGrid.Entry(index: $0.offset, bounds: $0.element.bounds)
        }

        var footways: [Footway] = []
        for element in document.features {
            let kind: Footway.Kind
            switch element.elementType {
            case .street: kind = .sidewalk
            case .crosswalk: kind = .crossing
            default: continue
            }
            guard case .lineString(let coordinates) = element.geometry, coordinates.count >= 2 else { continue }
            let points = coordinates.map {
                CGPoint(x: CGFloat($0.x) * scale - origin.x, y: CGFloat($0.y) * scale - origin.y)
            }
            footways.append(Footway(id: element.id, name: element.properties.name,
                                    kind: kind, points: points, bounds: boundingBox(points)))
        }
        let footwayEntries = footways.enumerated().map {
            UniformGrid.Entry(index: $0.offset, bounds: $0.element.bounds)
        }

        let intersections = document.features.compactMap {
            makeIntersection(from: $0, scale: scale, origin: origin, metrics: metrics)
        }
        let intersectionEntries = intersections.enumerated().map {
            UniformGrid.Entry(index: $0.offset, bounds: $0.element.touchBounds)
        }

        var center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        if let requested = extras?.initialCenter {
            center = CGPoint(
                x: CGFloat(requested.x) * scale - origin.x,
                y: CGFloat(requested.y) * scale - origin.y
            )
        }
        // Open on a junction rather than on a nominal centre point.
        //
        // The document's centre is the middle of the requested bounding box, which lands
        // wherever it lands — often mid-block. A junction is a far better place to start: it
        // is the thing the map is named for, it is where the streets can be told apart, and it
        // puts something findable under the first finger that touches the screen.
        let snapLimit = 80 * scale
        if let nearest = intersections.min(by: {
            hypot($0.position.x - center.x, $0.position.y - center.y)
                < hypot($1.position.x - center.x, $1.position.y - center.y)
        }), hypot(nearest.position.x - center.x, nearest.position.y - center.y) <= snapLimit {
            center = nearest.position
        }

        let projection = extras?.bbox.map { bbox -> GeographicProjection in
            let midLat = (bbox.south + bbox.north) / 2.0
            let metersPerDegreeLongitude = 111_320.0 * cos(midLat * .pi / 180.0)
            return GeographicProjection(bbox: bbox, metersPerDegreeLongitude: CGFloat(metersPerDegreeLongitude),
                                        scale: scale, origin: origin)
        }

        return StreetMap(
            features: features,
            labels: labels,
            intersections: intersections,
            footways: footways,
            contentSize: contentSize,
            initialCenter: center,
            hitConfig: .init(velocityDivisor: hitConfig.velocityDivisor,
                             velocityBonusMax: hitConfig.velocityBonusMax,
                             updateThreshold: hitConfig.updateThreshold),
            metrics: metrics,
            geographicProjection: projection,
            index: UniformGrid(cellSize: 128, entries: entries),
            labelIndex: UniformGrid(cellSize: 512, entries: labelEntries),
            intersectionIndex: UniformGrid(cellSize: 256, entries: intersectionEntries),
            footwayIndex: UniformGrid(cellSize: 256, entries: footwayEntries)
        )
    }

    // MARK: Intersections

    /// Turns an `intersection` feature from the extract into a drawable, touchable junction.
    ///
    /// The junctions are found when the extract is built, from OpenStreetMap's node topology —
    /// see `Intersection`. Nothing is inferred here; this only projects the point into content
    /// coordinates and resolves the device-dependent sizes.
    private static func makeIntersection(
        from element: MapElement,
        scale: CGFloat,
        origin: CGPoint,
        metrics: StreetMapSizing.Metrics
    ) -> Intersection? {
        guard element.elementType == .intersection,
              case .point(let coordinate) = element.geometry else { return nil }

        let position = CGPoint(x: CGFloat(coordinate.x) * scale - origin.x,
                               y: CGFloat(coordinate.y) * scale - origin.y)

        let custom = element.properties.custom
        let streets = (custom["streets"] ?? "").split(separator: "|").map(String.init)
        let bearings = (custom["leg_bearings"] ?? "").split(separator: "|").compactMap { Double($0) }
        let legNames = (custom["leg_names"] ?? "").split(separator: "|").map(String.init)
        let legs = zip(bearings, legNames).map {
            IntersectionArm(bearing: CGFloat($0.0), streetName: $0.1)
        }

        let names = streets.isEmpty ? [element.properties.name] : streets
        let half = metrics.intersectionBoxWidth / 2
        let hitRadius = metrics.intersectionHitRadius

        return Intersection(
            id: element.id,
            streetNames: names,
            legs: legs,
            position: position,
            announcement: Intersection.announcement(shape: legs.count, streets: names),
            boxWidth: metrics.intersectionBoxWidth,
            hitRadius: hitRadius,
            touchBounds: CGRect(x: position.x - hitRadius, y: position.y - hitRadius,
                                width: hitRadius * 2, height: hitRadius * 2),
            drawBounds: CGRect(x: position.x - half, y: position.y - half,
                               width: metrics.intersectionBoxWidth,
                               height: metrics.intersectionBoxWidth)
        )
    }

    // MARK: Labels

    /// Places at most one label per road element, on its longest straight run, and keeps
    /// repeats of the same street name from piling up on top of each other.
    private static func buildLabels(features: [StreetFeature], font: CTFont) -> [StreetLabel] {
        struct Candidate {
            let name: String
            let start: CGPoint
            let end: CGPoint
            let length: CGFloat
        }

        var candidates: [Candidate] = []
        for feature in features {
            var best: (CGPoint, CGPoint, CGFloat)?
            for (a, b) in zip(feature.points, feature.points.dropFirst()) {
                let length = hypot(b.x - a.x, b.y - a.y)
                if best == nil || length > best!.2 { best = (a, b, length) }
            }
            guard let best else { continue }
            candidates.append(Candidate(name: feature.name, start: best.0, end: best.1, length: best.2))
        }
        candidates.sort { $0.length > $1.length }

        let minimumSpacing: CGFloat = 600
        var accepted: [StreetLabel] = []
        var placedByName: [String: [CGPoint]] = [:]

        for candidate in candidates {
            let midpoint = CGPoint(x: (candidate.start.x + candidate.end.x) / 2,
                                   y: (candidate.start.y + candidate.end.y) / 2)
            if let existing = placedByName[candidate.name],
               existing.contains(where: { hypot($0.x - midpoint.x, $0.y - midpoint.y) < minimumSpacing }) {
                continue
            }

            // The canvas sets the context fill colour before drawing. Core Text only honours
            // that if the run explicitly opts in — without this flag it silently draws black,
            // which is nearly invisible on the dark road colour underneath.
            let attributed = NSAttributedString(
                string: candidate.name,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            // Only label a run long enough to hold the text without spilling off the road.
            guard candidate.length > textBounds.width + 24 else { continue }

            var angle = atan2(candidate.end.y - candidate.start.y, candidate.end.x - candidate.start.x)
            // Keep text upright: never let a label read upside down.
            if angle > .pi / 2 { angle -= .pi }
            if angle < -.pi / 2 { angle += .pi }

            let halfWidth = textBounds.width / 2
            let radius = halfWidth + textBounds.height
            accepted.append(StreetLabel(
                line: line,
                position: midpoint,
                rotation: angle,
                bounds: CGRect(x: midpoint.x - radius, y: midpoint.y - radius,
                               width: radius * 2, height: radius * 2)
            ))
            placedByName[candidate.name, default: []].append(midpoint)
        }
        return accepted
    }
}

// MARK: - Build-time intermediate

/// A road projected into unshifted content points, before the content origin is known.
nonisolated private struct ProjectedElement {
    let element: MapElement
    let points: [CGPoint]
}

// MARK: - Uniform grid

/// A flat spatial index: features bucketed by the cells their bounding box touches.
///
/// The map is ~27,000 x 17,500 points, so a linear scan of 2,000 polylines per touch
/// sample would be wasted work at 60 Hz. A grid turns each lookup into a handful of cells.
nonisolated struct UniformGrid {
    struct Entry {
        let index: Int
        let bounds: CGRect
    }

    private let cellSize: CGFloat
    private let buckets: [Int64: [Int]]

    init(cellSize: CGFloat, entries: [Entry]) {
        self.cellSize = cellSize
        var buckets: [Int64: [Int]] = [:]
        for entry in entries {
            let minColumn = Int(floor(entry.bounds.minX / cellSize))
            let maxColumn = Int(floor(entry.bounds.maxX / cellSize))
            let minRow = Int(floor(entry.bounds.minY / cellSize))
            let maxRow = Int(floor(entry.bounds.maxY / cellSize))
            guard maxColumn >= minColumn, maxRow >= minRow else { continue }
            for column in minColumn...maxColumn {
                for row in minRow...maxRow {
                    buckets[Self.key(column, row), default: []].append(entry.index)
                }
            }
        }
        self.buckets = buckets
    }

    private static func key(_ column: Int, _ row: Int) -> Int64 {
        (Int64(column) << 32) ^ Int64(row & 0xFFFF_FFFF)
    }

    func candidates(near point: CGPoint, radius: CGFloat) -> [Int] {
        candidates(intersecting: CGRect(x: point.x - radius, y: point.y - radius,
                                        width: radius * 2, height: radius * 2))
    }

    func candidates(intersecting rect: CGRect) -> [Int] {
        let minColumn = Int(floor(rect.minX / cellSize))
        let maxColumn = Int(floor(rect.maxX / cellSize))
        let minRow = Int(floor(rect.minY / cellSize))
        let maxRow = Int(floor(rect.maxY / cellSize))
        guard maxColumn >= minColumn, maxRow >= minRow else { return [] }

        var seen = Set<Int>()
        var result: [Int] = []
        for column in minColumn...maxColumn {
            for row in minRow...maxRow {
                guard let bucket = buckets[Self.key(column, row)] else { continue }
                for index in bucket where seen.insert(index).inserted {
                    result.append(index)
                }
            }
        }
        return result
    }
}

// MARK: - Geometry helpers

nonisolated func boundingBox(_ points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .zero }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for point in points.dropFirst() {
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

nonisolated func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
    var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
    t = max(0, min(1, t))
    return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
}

nonisolated func distanceToPolyline(_ point: CGPoint, _ points: [CGPoint]) -> CGFloat {
    guard points.count >= 2 else {
        guard let only = points.first else { return .greatestFiniteMagnitude }
        return hypot(point.x - only.x, point.y - only.y)
    }
    var minimum = CGFloat.greatestFiniteMagnitude
    for (a, b) in zip(points, points.dropFirst()) {
        minimum = min(minimum, distanceToSegment(point, a, b))
    }
    return minimum
}

nonisolated func closestPointOnPolyline(_ point: CGPoint, _ points: [CGPoint]) -> CGPoint {
    guard points.count >= 2 else { return points.first ?? point }
    var best = points[0]
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for (a, b) in zip(points, points.dropFirst()) {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        var t: CGFloat = 0
        if lengthSquared > 0 {
            t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        }
        let candidate = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        let distance = hypot(point.x - candidate.x, point.y - candidate.y)
        if distance < bestDistance { bestDistance = distance; best = candidate }
    }
    return best
}

nonisolated func polylineMidpoint(_ points: [CGPoint]) -> CGPoint {
    guard points.count >= 2 else { return points.first ?? .zero }
    let total = zip(points, points.dropFirst())
        .reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    var remaining = total / 2
    for (a, b) in zip(points, points.dropFirst()) {
        let length = hypot(b.x - a.x, b.y - a.y)
        if remaining <= length, length > 0 {
            let t = remaining / length
            return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
        }
        remaining -= length
    }
    return points[points.count / 2]
}

nonisolated func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
    func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }
    let o1 = orientation(a, b, c), o2 = orientation(a, b, d)
    let o3 = orientation(c, d, a), o4 = orientation(c, d, b)
    return ((o1 > 0) != (o2 > 0)) && ((o3 > 0) != (o4 > 0))
}

/// Where two segments meet, or nil if they do not.
///
/// The tolerance runs a hair past each endpoint so a road that *ends* on another — a
/// T-junction, where one segment's tip touches the middle of the other — is caught as a
/// crossing, not missed for stopping a fraction short. Parallel segments never meet.
nonisolated func segmentCrossing(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
    let denominator = (b.x - a.x) * (d.y - c.y) - (b.y - a.y) * (d.x - c.x)
    guard abs(denominator) > 1e-9 else { return nil }
    let t = ((c.x - a.x) * (d.y - c.y) - (c.y - a.y) * (d.x - c.x)) / denominator
    let u = ((c.x - a.x) * (b.y - a.y) - (c.y - a.y) * (b.x - a.x)) / denominator
    let slack: CGFloat = 0.001
    guard t >= -slack, t <= 1 + slack, u >= -slack, u <= 1 + slack else { return nil }
    return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
}

/// Walks a polyline and returns the point `distance` along it.
nonisolated func pointAlongPolyline(_ points: [CGPoint], distance: CGFloat) -> CGPoint? {
    guard let first = points.first else { return nil }
    if distance <= 0 { return first }
    var remaining = distance
    for (a, b) in zip(points, points.dropFirst()) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { continue }
        if remaining <= length {
            let t = remaining / length
            return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
        }
        remaining -= length
    }
    return points.last
}

/// Pushes both ends of a polyline `distance` further out, along the direction of its own end
/// segments.
///
/// Used to give a crossing room to reach a pavement it stops short of. The added point keeps the
/// bearing the way already had, so a straight crossing stays straight and a bent one carries on
/// in the direction it was last going.
nonisolated func extendEnds(of points: [CGPoint], by distance: CGFloat) -> [CGPoint] {
    guard points.count >= 2, distance > 0 else { return points }
    var result = points
    if let head = pointBeyond(points[1], points[0], distance) {
        result.insert(head, at: 0)
    }
    if let tail = pointBeyond(points[points.count - 2], points[points.count - 1], distance) {
        result.append(tail)
    }
    return result
}

/// `to`, moved a further `distance` along the direction from `from` to `to`.
nonisolated private func pointBeyond(_ from: CGPoint, _ to: CGPoint,
                                    _ distance: CGFloat) -> CGPoint? {
    let length = hypot(to.x - from.x, to.y - from.y)
    guard length > 0.0001 else { return nil }
    return CGPoint(x: to.x + (to.x - from.x) / length * distance,
                   y: to.y + (to.y - from.y) / length * distance)
}

/// The stretch of a polyline between two arc-length positions along it.
///
/// The cut ends land exactly on `start` and `end`; every original vertex strictly between them
/// is kept, so a bend inside the stretch survives being trimmed.
nonisolated func subpath(of points: [CGPoint], from start: CGFloat, to end: CGFloat) -> [CGPoint] {
    guard points.count >= 2, end > start else { return [] }

    var cut: [CGPoint] = []
    if let first = pointAlongPolyline(points, distance: start) { cut.append(first) }
    var travelled: CGFloat = 0
    for (a, b) in zip(points, points.dropFirst()) {
        travelled += hypot(b.x - a.x, b.y - a.y)
        if travelled > start, travelled < end { cut.append(b) }
    }
    if let last = pointAlongPolyline(points, distance: end) { cut.append(last) }

    // A vertex sitting on top of a cut end would leave a zero-length segment behind, which
    // gives no direction to orient a marking by.
    var cleaned: [CGPoint] = []
    for point in cut {
        if let previous = cleaned.last, hypot(previous.x - point.x, previous.y - point.y) < 0.01 {
            continue
        }
        cleaned.append(point)
    }
    return cleaned
}

nonisolated func polylineLength(_ points: [CGPoint]) -> CGFloat {
    zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
}
