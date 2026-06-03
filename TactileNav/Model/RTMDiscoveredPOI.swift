//
//  RTMDiscoveredPOI.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  A plain data model for one "place" — a Point Of Interest (POI), like a restaurant
//  or the Roux Institute building. The map draws each one as a red pin and speaks its
//  name when you reach it.
//

import Foundation
import CoreLocation

/// One place, ready to draw and announce.
struct RTMDiscoveredPOI: Identifiable, Sendable {
    /// A unique id for this place (from the map data).
    let id: String

    /// The place's name — always set (places with no name are skipped, since there'd
    /// be nothing to say out loud).
    let name: String

    /// Where the place is, as a real map coordinate.
    let coordinate: CLLocationCoordinate2D

    /// What kind of place it is (restaurant, university, …) — picks its pin icon.
    let category: RTMPOICategory

    /// A street address if we have one. Usually nil for this map.
    let address: String?
}
