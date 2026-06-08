//
//  RTMEdgeDirection.swift
//  TactileNav  (RouxTactileMap)
//
//  Cardinal directions for page-turn panning at screen edges.
//

import Foundation

enum RTMEdgeDirection: String, CaseIterable, Sendable, Equatable {
    case north, south, east, west

    var announcement: String { rawValue }

    var opposite: RTMEdgeDirection {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }

    /// Screen-edge label for orientation anchors ("left", "right", "top", "bottom").
    var orientationEdgeLabel: String {
        switch self {
        case .north: return "top"
        case .south: return "bottom"
        case .east: return "right"
        case .west: return "left"
        }
    }
}

extension RTMPanDirection {
    var asEdgeDirection: RTMEdgeDirection {
        switch self {
        case .north: return .north
        case .south: return .south
        case .east: return .east
        case .west: return .west
        }
    }
}
