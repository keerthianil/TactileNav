//
//  RTMMapOverlays.swift
//  TactileNav  (RouxTactileMap)
//
//  THIS FILE IS
//  The "things drawn over the map" and how streets are styled:
//   • RTMWhiteTileOverlay / RTMWhiteTileRenderer — paint the whole map plain white so
//     Apple's normal streets/labels disappear and only our lines show.
//   • RTMStreetPolyline — a map line that also remembers what kind of street it is.
//   • RTMRoadType.renderStyle — picks each street's color, thickness, and dash style.
//

import MapKit
import UIKit

// MARK: - Blank white base

/// A tile overlay that replaces Apple's map tiles. Set `canReplaceMapContent = true`
/// on the instance so MapKit skips its own tiles. Rendered by ``RTMWhiteTileRenderer``.
final class RTMWhiteTileOverlay: MKTileOverlay {
    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = 0
        maximumZ = 30
    }
}

/// Fills each tile with the system background synchronously. Drawing here (rather
/// than loading an async tile image) keeps the base from flickering over the streets.
final class RTMWhiteTileRenderer: MKTileOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.setFillColor(UIColor.systemBackground.cgColor)
        context.fill(rect(for: mapRect))
    }
}

// MARK: - Streets

/// An MKPolyline that remembers its OSM road type so the renderer can style it.
final class RTMStreetPolyline: MKPolyline {
    var roadType: RTMRoadType = .residential
}

// MARK: - Road-type styling

extension RTMRoadType {

    struct RenderStyle {
        let color: UIColor
        /// Width in real-world METERS. The renderer converts this to screen points for
        /// the current zoom, so lines scale with the map like real roads and stay
        /// clearly separated whether zoomed in or out.
        let groundWidthMeters: CGFloat
        let dashPattern: [NSNumber]?
    }

    /// Roads + footpaths share one bold width; trails, bike paths, and steps are
    /// narrower and dashed/dotted. Footpaths are solid green (most useful for a BLV
    /// pedestrian); roads solid blue.
    var renderStyle: RenderStyle {
        switch self {
        case .primary:
            return RenderStyle(color: .systemBlue, groundWidthMeters: 14, dashPattern: nil)
        case .residential, .service:
            return RenderStyle(color: .systemBlue, groundWidthMeters: 11, dashPattern: nil)
        case .footway:
            return RenderStyle(color: .systemGreen, groundWidthMeters: 11, dashPattern: nil)
        case .path:
            return RenderStyle(color: .systemGreen, groundWidthMeters: 7, dashPattern: [10, 8])
        case .cycleway:
            return RenderStyle(color: .systemTeal, groundWidthMeters: 7, dashPattern: [10, 8])
        case .steps:
            return RenderStyle(color: .brown, groundWidthMeters: 5, dashPattern: [2, 6])
        }
    }
}
