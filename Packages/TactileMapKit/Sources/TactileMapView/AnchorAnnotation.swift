import MapKit
import TactileMapCore

/// A map annotation representing an anchor point placed on the nearest
/// corridor for a landmark or other point-of-interest element.
///
/// Anchor points provide a tangible, on-corridor touch target that the
/// user can find by tracing along a corridor.  Each anchor is associated
/// with the ``elementId`` of the original element it represents.
///
/// Extracted from Nav_Indoor's `LandmarkAnchorAnnotation`.
public class AnchorAnnotation: NSObject, MKAnnotation {

    /// The geographic coordinate of this anchor point on the corridor.
    public dynamic var coordinate: CLLocationCoordinate2D

    /// The ID of the element this anchor represents (e.g., a landmark).
    public let elementId: String

    /// The properties of the element this anchor represents.
    public let elementProperties: TactileProperties

    // MARK: - Initializer

    /// Creates an anchor annotation.
    ///
    /// - Parameters:
    ///   - coordinate: The geographic position on the nearest corridor.
    ///   - elementId: The unique ID of the source element.
    ///   - properties: The properties of the source element.
    public init(
        coordinate: CLLocationCoordinate2D,
        elementId: String,
        properties: TactileProperties
    ) {
        self.coordinate = coordinate
        self.elementId = elementId
        self.elementProperties = properties
        super.init()
    }
}
