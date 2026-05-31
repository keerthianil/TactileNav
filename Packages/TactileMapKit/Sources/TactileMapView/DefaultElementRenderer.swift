import MapKit
import TactileMapCore

/// Renders map elements on an `MKMapView` matching the Nav_Indoor visual style.
///
/// Uses ``TactileMapViewConfiguration`` to determine colors, sizes, and
/// line widths.  All physical dimensions (millimeters) are converted to
/// screen points via ``PhysicalDimensions/mmToPoints(_:)``.
public class DefaultElementRenderer: NSObject {

    /// The visual configuration used for rendering.
    public let config: TactileMapViewConfiguration

    // MARK: - Initializer

    /// Creates a renderer with the given configuration.
    ///
    /// - Parameter config: Visual configuration.  Defaults to ``TactileMapViewConfiguration/default``.
    public init(config: TactileMapViewConfiguration = .default) {
        self.config = config
        super.init()
    }

    // MARK: - Annotation views

    /// Creates an annotation view for a point-type element.
    ///
    /// - Anchor annotations: solid circle, ``TactileMapViewConfiguration/anchorPointColor``,
    ///   ``TactileMapViewConfiguration/anchorPointDiameterMM``.
    /// - Intersection annotations: circle with white border,
    ///   ``TactileMapViewConfiguration/intersectionColor``,
    ///   ``TactileMapViewConfiguration/intersectionDiameterMM``.
    /// - Landmark annotations: rectangle with white border and name label,
    ///   ``TactileMapViewConfiguration/landmarkColor``,
    ///   ``TactileMapViewConfiguration/landmarkWidthMM`` x ``TactileMapViewConfiguration/landmarkHeightMM``.
    ///
    /// - Parameters:
    ///   - annotation: The annotation to create a view for.
    ///   - mapView: The map view that will display the annotation.
    /// - Returns: A configured `MKAnnotationView`, or `nil` if the annotation is not a recognized type.
    public func annotationView(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        if let anchor = annotation as? AnchorAnnotation {
            return makeAnchorView(for: anchor, in: mapView)
        } else if let feature = annotation as? FeatureAnnotation {
            switch feature.element.elementType {
            case .intersection:
                return makeIntersectionView(for: feature, in: mapView)
            case .landmark:
                return makeLandmarkView(for: feature, in: mapView)
            default:
                return makeDefaultPointView(for: feature, in: mapView)
            }
        }
        return nil
    }

    // MARK: - Overlay renderers

    /// Creates an overlay renderer for corridors and blank background tiles.
    ///
    /// - ``BlankTileOverlay``: renders with ``WhiteTileRenderer``.
    /// - `MKPolyline`: renders as a corridor with
    ///   ``TactileMapViewConfiguration/corridorColor``,
    ///   ``TactileMapViewConfiguration/corridorLineWidthMM``, round cap/join.
    ///
    /// - Parameter overlay: The overlay to render.
    /// - Returns: A configured `MKOverlayRenderer`.
    public func overlayRenderer(for overlay: MKOverlay) -> MKOverlayRenderer {
        if let tileOverlay = overlay as? BlankTileOverlay {
            return WhiteTileRenderer(overlay: tileOverlay)
        }

        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = config.corridorColor
            renderer.lineWidth = PhysicalDimensions.mmToPoints(config.corridorLineWidthMM)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        return MKOverlayRenderer(overlay: overlay)
    }

    // MARK: - Private helpers

    private func makeAnchorView(for anchor: AnchorAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let reuseId = "AnchorAnnotation"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) ?? MKAnnotationView(annotation: anchor, reuseIdentifier: reuseId)
        view.annotation = anchor

        let diameter = PhysicalDimensions.mmToPoints(config.anchorPointDiameterMM)
        let size = CGSize(width: diameter, height: diameter)

        let renderer = UIGraphicsImageRenderer(size: size)
        view.image = renderer.image { ctx in
            config.anchorPointColor.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }

        view.frame.size = size
        view.centerOffset = CGPoint(x: 0, y: 0)
        view.canShowCallout = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = anchor.elementProperties.name

        return view
    }

    private func makeIntersectionView(for feature: FeatureAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let reuseId = "IntersectionAnnotation"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) ?? MKAnnotationView(annotation: feature, reuseIdentifier: reuseId)
        view.annotation = feature

        let diameter = PhysicalDimensions.mmToPoints(config.intersectionDiameterMM)
        let borderWidth: CGFloat = 2.0
        let totalSize = CGSize(width: diameter + borderWidth * 2, height: diameter + borderWidth * 2)

        let renderer = UIGraphicsImageRenderer(size: totalSize)
        view.image = renderer.image { ctx in
            let borderRect = CGRect(origin: .zero, size: totalSize)
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: borderRect)

            let innerRect = borderRect.insetBy(dx: borderWidth, dy: borderWidth)
            config.intersectionColor.setFill()
            ctx.cgContext.fillEllipse(in: innerRect)
        }

        view.frame.size = totalSize
        view.centerOffset = CGPoint(x: 0, y: 0)
        view.canShowCallout = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = feature.element.properties.name

        return view
    }

    private func makeLandmarkView(for feature: FeatureAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let reuseId = "LandmarkAnnotation"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) ?? MKAnnotationView(annotation: feature, reuseIdentifier: reuseId)
        view.annotation = feature

        let width = PhysicalDimensions.mmToPoints(config.landmarkWidthMM)
        let height = PhysicalDimensions.mmToPoints(config.landmarkHeightMM)
        let borderWidth: CGFloat = 2.0
        let labelHeight: CGFloat = 14.0
        let totalWidth = width + borderWidth * 2
        let totalHeight = height + borderWidth * 2 + labelHeight + 2

        let totalSize = CGSize(width: max(totalWidth, 60), height: totalHeight)

        let renderer = UIGraphicsImageRenderer(size: totalSize)
        view.image = renderer.image { ctx in
            let rectX = (totalSize.width - totalWidth) / 2
            let borderRect = CGRect(x: rectX, y: 0, width: totalWidth, height: height + borderWidth * 2)

            UIColor.white.setFill()
            ctx.cgContext.fill(borderRect)

            let innerRect = borderRect.insetBy(dx: borderWidth, dy: borderWidth)
            config.landmarkColor.setFill()
            ctx.cgContext.fill(innerRect)

            // Draw the label below the rectangle.
            let name = feature.element.properties.name
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle
            ]

            let labelRect = CGRect(
                x: 0,
                y: borderRect.maxY + 2,
                width: totalSize.width,
                height: labelHeight
            )
            (name as NSString).draw(in: labelRect, withAttributes: attributes)
        }

        view.frame.size = totalSize
        view.centerOffset = CGPoint(x: 0, y: 0)
        view.canShowCallout = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = feature.element.properties.name

        return view
    }

    private func makeDefaultPointView(for feature: FeatureAnnotation, in mapView: MKMapView) -> MKAnnotationView {
        let reuseId = "DefaultPointAnnotation"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) ?? MKAnnotationView(annotation: feature, reuseIdentifier: reuseId)
        view.annotation = feature

        let diameter: CGFloat = PhysicalDimensions.mmToPoints(6.0)
        let size = CGSize(width: diameter, height: diameter)

        let renderer = UIGraphicsImageRenderer(size: size)
        view.image = renderer.image { ctx in
            UIColor.systemGray.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }

        view.frame.size = size
        view.centerOffset = CGPoint(x: 0, y: 0)
        view.canShowCallout = false
        view.isAccessibilityElement = true
        view.accessibilityLabel = feature.element.properties.name

        return view
    }
}
