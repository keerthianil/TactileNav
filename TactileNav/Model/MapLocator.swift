//
//  MapLocator.swift
//  TactileNav
//
//  The mark on the map for the place that was asked for.
//

import CoreGraphics
import Foundation

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
