//
//  SearchResult.swift
//  TactileNav
//
//  One thing a search can find and take you to.
//
//  Deliberately a plain value with a position already in content points. The search screen
//  never talks to the map, and the map never talks to the search: the only thing that passes
//  between them is a place on the grid and a name for it.
//

import CoreGraphics
import Foundation

nonisolated struct SearchResult: Identifiable, Hashable {

    /// What kind of thing was found. The search screen groups by this, in this order — a
    /// junction is the more useful answer to "where is Congress and High", and it is also the
    /// thing a traveller plans around.
    enum Kind: Int, CaseIterable, Comparable {
        case junction
        case street

        /// Section heading on the search screen.
        var heading: String {
            switch self {
            case .junction: return "Junctions"
            case .street: return "Streets"
            }
        }

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let kind: Kind
    /// "Congress Street and High Street"
    let name: String
    /// "Four-way junction" — what it is, not where it is.
    let detail: String
    /// Where to centre the map, in content points.
    let position: CGPoint

    /// One sentence for VoiceOver, so a result is one swipe rather than two.
    var spokenLabel: String { detail.isEmpty ? name : "\(name). \(detail)" }
}

// MARK: - The place the map was sent to

/// A marker dropped on the map at a searched place.
///
/// The reference app calls this a target dot and prints one at the address you asked for; it is
/// the answer to "did it hear me", and the thing you go back to when a finger has wandered.
nonisolated struct MapLocator: Equatable {
    /// In content points, the same space the roads are in.
    let position: CGPoint
    /// Spoken when a finger lands on it.
    let name: String
}
