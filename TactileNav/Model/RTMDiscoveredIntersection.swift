//
//  RTMDiscoveredIntersection.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  A plain data model for one intersection — a spot where streets meet. The map
//  draws each one as a small orange dot.
//

import Foundation
import CoreLocation

/// One intersection, ready to draw.
struct RTMDiscoveredIntersection: Identifiable, Sendable {
    /// A unique id for this intersection (from the map data).
    let id: String

    /// A name like "Washington Avenue & Bates Street" when we can build one,
    /// otherwise nil.
    let name: String?

    /// Where the intersection is, as a real map coordinate.
    let coordinate: CLLocationCoordinate2D

    /// The ids of the streets that meet here (from the map data).
    let connectedStreetIDs: [String]
}
