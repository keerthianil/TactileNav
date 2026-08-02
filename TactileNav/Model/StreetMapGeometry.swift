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

        // Roads only. The extract also carries sidewalks and crossings; they are dropped here
        // rather than filtered later so nothing downstream has to know they ever existed.
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
