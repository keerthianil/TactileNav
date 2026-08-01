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

// MARK: - Surface types

/// The three surfaces this map draws. Each has its own haptic signature and its own
/// spoken form, and they are hit-tested in this order of priority.
nonisolated enum StreetSurface {
    case crosswalk
    case sidewalk
    case road

    var elementType: TactileElementType {
        switch self {
        case .crosswalk: return .crosswalk
        case .sidewalk: return .street
        case .road: return .road
        }
    }

    /// Breaks a tie when two lines are effectively under the finger together. A crossing is
    /// painted on top of the road, and a sidewalk sits beside it, so that is the order.
    var hitPriority: Int {
        switch self {
        case .crosswalk: return 2
        case .sidewalk: return 1
        case .road: return 0
        }
    }
}

// MARK: - A drawable, touchable feature

nonisolated struct StreetFeature {
    let id: String
    let name: String
    let surface: StreetSurface
    /// Polyline in content points.
    let points: [CGPoint]
    let strokeWidth: CGFloat
    let hitRadius: CGFloat
    let lanes: Int
    /// What VoiceOver says when a finger lands here.
    let announcement: String
    /// Bounding box already grown by the larger of the stroke half-width and hit radius.
    let touchBounds: CGRect
    /// Bounding box grown by the stroke half-width only, for draw culling.
    let drawBounds: CGRect
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

nonisolated struct StreetMap {

    let features: [StreetFeature]
    let labels: [StreetLabel]
    let contentSize: CGSize
    /// Where to open the viewport, from the document rather than a hardcoded offset.
    let initialCenter: CGPoint
    let hitConfig: HitDetectionConfigValues
    /// The device metrics this map was projected with.
    let metrics: StreetMapSizing.Metrics

    private let index: UniformGrid
    private let labelIndex: UniformGrid

    /// The subset of `HitDetectionConfig` this map uses, captured at build time.
    struct HitDetectionConfigValues {
        let velocityDivisor: CGFloat
        let velocityBonusMax: CGFloat
        let updateThreshold: TimeInterval
    }

    // MARK: Lookup

    /// How close two lines must be before type priority, rather than distance, decides.
    private static let tieBreakMargin: CGFloat = 6

    /// The feature under a content-space point, or nil for empty space.
    ///
    /// **Nearest line wins.** Strict priority by type — crossing, then sidewalk, then road —
    /// sounds right because a crossing is painted on top of the road it spans, but it means a
    /// crossing's catch radius claims every road near it. With hundreds of crossings around
    /// the junctions, a finger tracing a road would feel crossing ticks a good part of the
    /// time while plainly looking at a road. So whichever line the finger is genuinely closest
    /// to wins, and type priority only settles it when two are within a few points of each
    /// other — which is exactly where a crossing really is on top of the road.
    ///
    /// The radius grows with finger speed. A fast drag samples further apart, so a fixed
    /// radius lets the finger step over a line between two samples and feel nothing.
    func feature(at point: CGPoint, velocity: CGFloat) -> StreetFeature? {
        let bonus = min(velocity / hitConfig.velocityDivisor, hitConfig.velocityBonusMax)

        var best: (feature: StreetFeature, distance: CGFloat)?
        for featureIndex in index.candidates(near: point, radius: bonus) {
            let feature = features[featureIndex]
            guard feature.touchBounds.insetBy(dx: -bonus, dy: -bonus).contains(point) else { continue }
            let distance = distanceToPolyline(point, feature.points)
            guard distance <= feature.hitRadius + bonus else { continue }

            guard let current = best else {
                best = (feature, distance)
                continue
            }
            if distance < current.distance - Self.tieBreakMargin {
                best = (feature, distance)
            } else if abs(distance - current.distance) <= Self.tieBreakMargin,
                      feature.surface.hitPriority > current.feature.surface.hitPriority {
                best = (feature, distance)
            }
        }
        return best?.feature
    }

    /// Features whose ink could land inside `rect`, for tile drawing.
    func features(in rect: CGRect) -> [StreetFeature] {
        index.candidates(intersecting: rect)
            .map { features[$0] }
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
            guard feature.surface == .road else { continue }
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

        for element in document.features {
            guard let surface = surface(for: element.elementType) else { continue }
            guard case .lineString(let coordinates) = element.geometry, coordinates.count >= 2 else { continue }
            let points = coordinates.map {
                CGPoint(x: CGFloat($0.x) * scale, y: CGFloat($0.y) * scale)
            }
            for point in points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            raws.append(ProjectedElement(element: element, surface: surface, points: points))
        }

        guard !raws.isEmpty else {
            return StreetMap(
                features: [], labels: [], contentSize: .zero, initialCenter: .zero,
                hitConfig: .init(velocityDivisor: hitConfig.velocityDivisor,
                                 velocityBonusMax: hitConfig.velocityBonusMax,
                                 updateThreshold: hitConfig.updateThreshold),
                metrics: metrics,
                index: UniformGrid(cellSize: 128, entries: []),
                labelIndex: UniformGrid(cellSize: 512, entries: [])
            )
        }

        // Pad by the widest stroke so no ink is clipped at the content edge.
        let pad = metrics.roadWidth
        let origin = CGPoint(x: minX - pad, y: minY - pad)
        let contentSize = CGSize(width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)

        // Pass 1: geometry, so sidewalks and crossings can be related to roads in pass 2.
        var placed: [PlacedElement] = []
        for raw in raws {
            let shifted = raw.points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
            let lanes = Int(raw.element.properties.custom["lanes"] ?? "") ?? 1
            let stroke: CGFloat
            switch raw.surface {
            case .road: stroke = metrics.roadWidth
            case .sidewalk: stroke = metrics.sidewalkWidth
            case .crosswalk: stroke = metrics.crosswalkStripeWidth
            }
            placed.append(PlacedElement(
                id: raw.element.id,
                name: raw.element.properties.name,
                surface: raw.surface,
                points: shifted,
                lanes: lanes,
                stroke: stroke
            ))
        }

        // Road-only grid, used to name the street a sidewalk follows or a crossing spans.
        let roadEntries: [UniformGrid.Entry] = placed.enumerated().compactMap { offset, item in
            guard item.surface == .road else { return nil }
            return UniformGrid.Entry(index: offset, bounds: boundingBox(item.points))
        }
        let roadGrid = UniformGrid(cellSize: 256, entries: roadEntries)

        // Pass 2: features with their spoken forms.
        var features: [StreetFeature] = []
        features.reserveCapacity(placed.count)

        for item in placed {
            let announcement: String
            switch item.surface {
            case .road:
                // Bare street name — the surface itself is conveyed by the haptic.
                announcement = item.name
            case .sidewalk:
                announcement = sidewalkAnnouncement(
                    declaredName: item.name, points: item.points,
                    placed: placed, roadGrid: roadGrid, metrics: metrics)
            case .crosswalk:
                announcement = crosswalkAnnouncement(
                    declaredName: item.name, points: item.points,
                    placed: placed, roadGrid: roadGrid, metrics: metrics)
            }

            let hitRadius: CGFloat
            switch item.surface {
            case .road: hitRadius = max(item.stroke / 2, metrics.roadHitRadius)
            case .sidewalk: hitRadius = max(item.stroke / 2, metrics.sidewalkHitRadius)
            case .crosswalk: hitRadius = max(item.stroke / 2, metrics.crosswalkHitRadius)
            }

            let box = boundingBox(item.points)
            features.append(StreetFeature(
                id: item.id,
                name: item.name,
                surface: item.surface,
                points: item.points,
                strokeWidth: item.stroke,
                hitRadius: hitRadius,
                lanes: item.lanes,
                announcement: announcement,
                touchBounds: box.insetBy(dx: -hitRadius, dy: -hitRadius),
                drawBounds: box.insetBy(dx: -item.stroke, dy: -item.stroke)
            ))
        }

        let entries = features.enumerated().map {
            UniformGrid.Entry(index: $0.offset, bounds: $0.element.touchBounds)
        }
        let labels = buildLabels(features: features, font: labelFont)
        let labelEntries = labels.enumerated().map {
            UniformGrid.Entry(index: $0.offset, bounds: $0.element.bounds)
        }

        var center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        if let requested = extras?.initialCenter {
            center = CGPoint(
                x: CGFloat(requested.x) * scale - origin.x,
                y: CGFloat(requested.y) * scale - origin.y
            )
        }

        return StreetMap(
            features: features,
            labels: labels,
            contentSize: contentSize,
            initialCenter: center,
            hitConfig: .init(velocityDivisor: hitConfig.velocityDivisor,
                             velocityBonusMax: hitConfig.velocityBonusMax,
                             updateThreshold: hitConfig.updateThreshold),
            metrics: metrics,
            index: UniformGrid(cellSize: 128, entries: entries),
            labelIndex: UniformGrid(cellSize: 512, entries: labelEntries)
        )
    }

    private static func surface(for type: TactileElementType) -> StreetSurface? {
        switch type {
        case .road: return .road
        case .street: return .sidewalk
        case .crosswalk: return .crosswalk
        default: return nil
        }
    }

    // MARK: Spoken forms
    //
    // A road says its bare name — the haptic already tells the finger it is a roadway.
    //
    // Sidewalks and crossings are different: this map has hundreds of each, and a name on its
    // own answers the wrong question. So they always *lead with the surface type* and then add
    // the best identifier available — the street they run along, the street they cross, or
    // their own name when OpenStreetMap gives them one (a few are named trails). Hearing
    // "Eastern Promenade Trail" without the word crosswalk tells you nothing about what you
    // are standing on.

    private static func sidewalkAnnouncement(
        declaredName: String,
        points: [CGPoint],
        placed: [PlacedElement],
        roadGrid: UniformGrid,
        metrics: StreetMapSizing.Metrics
    ) -> String {
        // A named path keeps its name, behind the surface type.
        if declaredName != "Sidewalk", !declaredName.isEmpty {
            return "Sidewalk, \(declaredName)"
        }

        let midpoint = polylineMidpoint(points)
        guard let nearest = nearestRoad(to: midpoint, placed: placed, roadGrid: roadGrid,
                                        limit: 40 * metrics.pointsPerMeter)
        else { return "Sidewalk" }

        let onRoad = closestPointOnPolyline(midpoint, placed[nearest].points)
        let side = cardinal(from: onRoad, to: midpoint)
        let name = placed[nearest].name
        guard !side.isEmpty else { return "Sidewalk, \(name)" }
        return "\(side) sidewalk, \(name)"
    }

    private static func crosswalkAnnouncement(
        declaredName: String,
        points: [CGPoint],
        placed: [PlacedElement],
        roadGrid: UniformGrid,
        metrics: StreetMapSizing.Metrics
    ) -> String {
        if declaredName != "Crosswalk", !declaredName.isEmpty {
            return "Crosswalk, \(declaredName)"
        }
        // The street being crossed is the one the crossing actually intersects.
        let midpoint = polylineMidpoint(points)
        if let crossed = crossedRoad(points: points, placed: placed, roadGrid: roadGrid)
            ?? nearestRoad(to: midpoint, placed: placed, roadGrid: roadGrid,
                           limit: 25 * metrics.pointsPerMeter) {
            return "Crosswalk across \(placed[crossed].name)"
        }
        return "Crosswalk"
    }

    private static func nearestRoad(
        to point: CGPoint,
        placed: [PlacedElement],
        roadGrid: UniformGrid,
        limit: CGFloat
    ) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for candidate in roadGrid.candidates(near: point, radius: limit) {
            let distance = distanceToPolyline(point, placed[candidate].points)
            guard distance <= limit else { continue }
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        return best?.index
    }

    private static func crossedRoad(
        points: [CGPoint],
        placed: [PlacedElement],
        roadGrid: UniformGrid
    ) -> Int? {
        let box = boundingBox(points)
        for candidate in roadGrid.candidates(intersecting: box) {
            let roadPoints = placed[candidate].points
            for (a, b) in zip(points, points.dropFirst()) {
                for (c, d) in zip(roadPoints, roadPoints.dropFirst()) {
                    if segmentsIntersect(a, b, c, d) { return candidate }
                }
            }
        }
        return nil
    }

    /// Cardinal direction of `to` relative to `from`, by dominant axis. Screen y grows
    /// south because the document's y does, so a positive dy is south.
    private static func cardinal(from: CGPoint, to: CGPoint) -> String {
        let dx = to.x - from.x
        let dy = to.y - from.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return "" }
        if abs(dx) >= abs(dy) { return dx >= 0 ? "East" : "West" }
        return dy >= 0 ? "South" : "North"
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
        for feature in features where feature.surface == .road {
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

// MARK: - Build-time intermediates

/// An element projected into unshifted content points, before the content origin is known.
nonisolated private struct ProjectedElement {
    let element: MapElement
    let surface: StreetSurface
    let points: [CGPoint]
}

/// An element in final content points, with its stroke resolved but not yet its wording —
/// sidewalks and crossings need every road placed before they can name their street.
nonisolated private struct PlacedElement {
    let id: String
    let name: String
    let surface: StreetSurface
    let points: [CGPoint]
    let lanes: Int
    let stroke: CGFloat
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

nonisolated func polylineLength(_ points: [CGPoint]) -> CGFloat {
    zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
}
