//
//  RTMFunctionalZoomLevel.swift
//  TactileNav  (RouxTactileMap)
//
//  Three functional zoom levels (UAHCI 2016): each level reveals more map content
//  while keeping primary roads visible at every level as orientation anchors.
//

import CoreGraphics
import CoreLocation
import Foundation

/// Functional zoom level — controls camera distance AND which features are visible.
enum RTMFunctionalZoomLevel: Int, CaseIterable, Sendable, Equatable {
    case overview = 1   // Level 1 — main roads only
    case streets = 2    // Level 2 — all streets + intersections
    case detail = 3     // Level 3 — full map with places

    var cameraDistance: CLLocationDistance {
        switch self {
        case .overview: return 1000
        case .streets: return 300
        case .detail: return 120
        }
    }

    var announcement: String {
        switch self {
        case .overview:
            return "Overview. Main roads."
        case .streets:
            return "Streets. All roads and intersections."
        case .detail:
            return "Detail. Full map with places."
        }
    }

    var shortLabel: String {
        switch self {
        case .overview: return "1 · Overview"
        case .streets: return "2 · Streets"
        case .detail: return "3 · Detail"
        }
    }

    /// Short name read by VoiceOver when the zoom level changes.
    var voiceOverLabel: String {
        switch self {
        case .overview: return "Overview level"
        case .streets: return "Street level"
        case .detail: return "Detail level"
        }
    }

    func isStreetVisible(_ roadType: RTMRoadType) -> Bool {
        switch self {
        case .overview: return roadType == .primary
        case .streets, .detail: return true
        }
    }

    var showIntersections: Bool {
        switch self {
        case .overview: return false
        case .streets, .detail: return true
        }
    }

    var showPOIs: Bool {
        self == .detail
    }

    /// How much to shrink street widths at this zoom level (1.0 = full width).
    var streetWidthScale: CGFloat {
        switch self {
        case .detail: return 1.0
        case .streets: return 0.45
        case .overview: return 0.65
        }
    }

    /// Nearest functional level for a raw camera distance (used after pinch).
    static func nearest(to distance: CLLocationDistance) -> RTMFunctionalZoomLevel {
        allCases.min(by: { abs($0.cameraDistance - distance) < abs($1.cameraDistance - distance) }) ?? .streets
    }
}

/// Cardinal directions for VoiceOver / menu panning.
enum RTMPanDirection: Sendable {
    case north, south, east, west

    var announcement: String {
        switch self {
        case .north: return "north"
        case .south: return "south"
        case .east: return "east"
        case .west: return "west"
        }
    }
}
