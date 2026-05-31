import MapKit
import TactileMapCore

/// A generic `MKAnnotation` wrapper for point-type map elements
/// (landmarks, intersections, or any element with `.point` geometry).
///
/// The annotation's ``title`` is derived from the element's
/// `properties.name` for automatic VoiceOver labeling in MapKit.
public class FeatureAnnotation: NSObject, MKAnnotation {

    /// The geographic coordinate of the element.
    public dynamic var coordinate: CLLocationCoordinate2D

    /// The source map element this annotation represents.
    public let element: MapElement

    // MARK: - Initializer

    /// Creates a feature annotation for a map element.
    ///
    /// - Parameters:
    ///   - element: The ``MapElement`` from the ``TactileMapDocument``.
    ///   - coordinate: The geographic position (already converted via ``CoordinateTransform``).
    public init(element: MapElement, coordinate: CLLocationCoordinate2D) {
        self.element = element
        self.coordinate = coordinate
        super.init()
    }

    // MARK: - MKAnnotation

    /// The human-readable name of the element, used by MapKit for
    /// callouts and VoiceOver labels.
    public var title: String? {
        element.properties.name
    }
}
