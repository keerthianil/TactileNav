//
//  PlaceSearchIndex.swift
//  TactileNav
//
//  Finding a place on the map by typing its name.
//
//  Everything searchable is already in the extract, so this needs no network, no geocoder and
//  no API key: the streets and the junctions come straight out of the loaded `StreetMap`. That
//  is not just convenient. A study session has to be reproducible and has to work in a basement
//  with no signal, and a query that leaves the device is a query that can change its answer
//  between participants.
//
//  **Matching is by token prefix, unordered.** Each word you type has to be the start of some
//  word in the name, and the words may come in any order. That one rule covers the three things
//  people actually type without a table of special cases:
//
//    "cong"            -> Congress Street          (a prefix of one word)
//    "congress st"     -> Congress Street          ("st" starts "Street" — abbreviations fall
//                                                   out for free, no lookup table)
//    "high congress"   -> Congress Street and High Street   (order does not matter)
//
//  A junction query reads naturally as "congress and high", so the joining words are dropped
//  before matching rather than being made to match anything.
//

import CoreGraphics
import Foundation

nonisolated struct PlaceSearchIndex {

    /// Words that join two street names in a junction query and carry no meaning of their own.
    /// Dropped from the query, never from the names.
    private static let connectors: Set<String> = ["and", "at", "amp"]

    /// Below this a query matches most of the map, and the list is noise rather than an answer.
    static let minimumQueryLength = 2

    private struct Entry {
        let result: SearchResult
        /// Lowercased, punctuation-free words of the searchable text.
        let tokens: [String]
        /// Those words joined back up — for scoring an exact or leading match.
        let normalised: String
    }

    private let entries: [Entry]

    /// Number of searchable places. Readable so a test can check the index was actually built.
    var count: Int { entries.count }

    // MARK: Building

    /// Builds the index from a loaded map. Cheap enough to do on the same background pass that
    /// builds the map itself — a few hundred entries of value types.
    init(map: StreetMap) {
        var entries: [Entry] = []
        let centre = map.initialCenter
        let scale = map.metrics.pointsPerMeter

        // MARK: Streets
        //
        // Grouped by name, because a street is one thing to a traveller even though
        // OpenStreetMap splits it into a piece per block. The longest piece is the one worth
        // landing on, and its midpoint is the most "on the street" a single point can be.
        var piecesByName: [String: [StreetFeature]] = [:]
        for feature in map.features where !feature.name.isEmpty {
            piecesByName[feature.name, default: []].append(feature)
        }
        for (name, pieces) in piecesByName {
            guard let longest = pieces.max(by: { polylineLength($0.points) < polylineLength($1.points) })
            else { continue }
            let metres = pieces.reduce(CGFloat.zero) { $0 + polylineLength($1.points) } / scale
            entries.append(Self.entry(
                id: "street:" + name,
                kind: .street,
                name: name,
                detail: "Street · " + Self.distance(metres),
                position: polylineMidpoint(longest.points),
                searchText: name))
        }

        // MARK: Junctions
        //
        // Named by the streets that meet, which is how anyone asks for one. The same pair of
        // names can occur more than once — every ramp junction is "Congress Street and Ramp" —
        // so the detail carries a bearing from the map's home point, which is what tells two
        // otherwise identical rows apart.
        for junction in map.intersections {
            let name = junction.streetNames.joined(separator: " and ")
            guard !name.isEmpty else { continue }
            let dx = junction.position.x - centre.x
            let dy = junction.position.y - centre.y
            let away = hypot(dx, dy)
            var detail = Self.shapeWord(junction.legs.count) + " junction"
            if away > 1 {
                let bearing = atan2(dx, -dy) * 180 / .pi
                detail += " · \(Self.distance(away / scale)) \(IntersectionArm.compassName(for: bearing))"
            }
            entries.append(Self.entry(
                id: "junction:" + junction.id,
                kind: .junction,
                name: name,
                detail: detail,
                position: junction.position,
                searchText: name))
        }

        self.entries = entries
    }

    private static func entry(id: String, kind: SearchResult.Kind, name: String, detail: String,
                              position: CGPoint, searchText: String) -> Entry {
        let tokens = Self.tokens(searchText)
        return Entry(
            result: SearchResult(id: id, kind: kind, name: name, detail: detail, position: position),
            tokens: tokens,
            normalised: tokens.joined(separator: " "))
    }

    // MARK: Searching

    /// The best matches for what has been typed, already ordered.
    func results(for query: String, limit: Int = 40) -> [SearchResult] {
        let raw = Self.tokens(query)
        guard !raw.isEmpty else { return [] }
        let trimmed = raw.filter { !Self.connectors.contains($0) }
        // Unless dropping them leaves nothing — somebody may genuinely be after "Atlantic".
        let queryTokens = trimmed.isEmpty ? raw : trimmed
        let normalisedQuery = queryTokens.joined(separator: " ")
        guard normalisedQuery.count >= Self.minimumQueryLength else { return [] }

        var scored: [(SearchResult, Int)] = []
        for entry in entries {
            guard let score = Self.score(entry, queryTokens, normalisedQuery) else { continue }
            scored.append((entry.result, score))
        }

        scored.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.kind != $1.0.kind { return $0.0.kind < $1.0.kind }
            return $0.0.name < $1.0.name
        }
        return scored.prefix(limit).map(\.0)
    }

    /// How well an entry answers the query, or nil if it does not answer it at all.
    private static func score(_ entry: Entry, _ queryTokens: [String],
                              _ normalisedQuery: String) -> Int? {
        // Every word typed has to start some word of the name, and each name word can only be
        // claimed once — so "high high" does not match a street with one "High" in it.
        var unclaimed = entry.tokens
        for token in queryTokens {
            guard let index = unclaimed.firstIndex(where: { $0.hasPrefix(token) }) else { return nil }
            unclaimed.remove(at: index)
        }

        var score = 100
        if entry.normalised == normalisedQuery {
            score += 900
        } else if entry.normalised.hasPrefix(normalisedQuery) {
            score += 400
        }
        // Fewer words left over means a tighter answer: typing "congress high" should put the
        // junction of those two above a junction of four streets that happens to include them.
        score -= unclaimed.count * 5
        // And among equals, the shorter name is the more specific one.
        score -= min(entry.normalised.count, 60) / 10
        return score
    }

    // MARK: Text

    private static func tokens(_ text: String) -> [String] {
        let cleaned = String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").map(String.init)
    }

    private static func shapeWord(_ legs: Int) -> String {
        switch legs {
        case 2: return "Two-way"
        case 3: return "Three-way"
        case 4: return "Four-way"
        case 5: return "Five-way"
        case 6: return "Six-way"
        default: return "\(legs)-way"
        }
    }

    /// Ground distance, said the way a person would say it.
    private static func distance(_ metres: CGFloat) -> String {
        metres >= 1000
            ? String(format: "%.1f km", metres / 1000)
            : "\(Int((metres / 10).rounded()) * 10) m"
    }
}
