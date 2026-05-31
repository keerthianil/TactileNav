import MapKit

/// A tile overlay that replaces all default map tiles with blank content.
///
/// Used in conjunction with ``WhiteTileRenderer`` to produce a clean
/// white background for the tactile map, removing all default Apple Maps
/// imagery (satellite, terrain, roads, labels, etc.).
public class BlankTileOverlay: MKTileOverlay {

    /// Creates a blank tile overlay that replaces all default map content.
    public override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        self.canReplaceMapContent = true
    }
}

/// A tile overlay renderer that fills every tile with a solid white color.
///
/// Pair this with ``BlankTileOverlay`` to produce a clean white canvas
/// on which tactile map elements are rendered.
public class WhiteTileRenderer: MKTileOverlayRenderer {

    /// Draws a solid white rectangle for every map tile.
    override public func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let rect = self.rect(for: mapRect)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
    }
}
