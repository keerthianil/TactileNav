//
//  RTMPOICategory.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  The list of "kinds of place" a POI can be (restaurant, university, park, …). The
//  category decides which little icon shows inside the red pin (see RTMMapAnnotations)
//  and gives VoiceOver a readable label like "University building".
//

import Foundation

enum RTMPOICategory: String, CaseIterable, Sendable {
    case restaurant
    case cafe
    case hospital
    case pharmacy
    case school
    case university
    case transit
    case park
    case store
    case bank
    case library
    case parking
    case boatLaunch
    /// A named place that doesn't fit a more specific bucket (e.g. a tourist spot).
    case namedPlace
    /// The user's own position. (Not used for pins here, but kept for completeness.)
    case userLocation
    /// Anything named but otherwise unclassified.
    case other

    /// A friendly label VoiceOver can read, e.g. "University building". Also used as
    /// a fallback name if a place somehow has none.
    var displayName: String {
        switch self {
        case .restaurant:   return "Restaurant"
        case .cafe:         return "Café"
        case .hospital:     return "Hospital"
        case .pharmacy:     return "Pharmacy"
        case .school:       return "School"
        case .university:   return "University building"
        case .transit:      return "Transit stop"
        case .park:         return "Park"
        case .store:        return "Shop"
        case .bank:         return "Bank"
        case .library:      return "Library"
        case .parking:      return "Parking"
        case .boatLaunch:   return "Boat launch"
        case .namedPlace:   return "Place"
        case .userLocation: return "Your location"
        case .other:        return "Place"
        }
    }
}
