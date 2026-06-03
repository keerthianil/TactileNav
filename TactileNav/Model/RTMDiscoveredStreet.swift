//
//  RTMDiscoveredStreet.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  A plain data model for one street (or footpath / trail) on the map. The adapter
//  fills these in from the JSON, and the map draws one blue/green line per street.
//  "Discovered" just means "a thing we found in the map data".
//

import Foundation
import CoreLocation

/// What kind of street this is. We use it to pick the line's color/thickness/dash
/// (see RTMMapOverlays) and how strong the buzz feels (see RTMMapFeedbackController).
enum RTMRoadType: String, Sendable {
    case primary        // big main roads
    case residential    // normal neighborhood streets
    case service        // small service roads / alleys
    case footway        // sidewalks / walking paths
    case path           // trails
    case cycleway       // bike paths
    case steps          // stairs
}

/// One street, ready to draw and to feel.
struct RTMDiscoveredStreet: Identifiable, Sendable {
    /// A unique id for this street (comes straight from the map data).
    let id: String

    /// The street's name, or nil if the data didn't give it one.
    let name: String?

    /// The list of points that make up the line, in order, as real map coordinates.
    let coordinates: [CLLocationCoordinate2D]

    /// Which kind of street this is (drives how it looks and feels).
    let roadType: RTMRoadType
}
