import Foundation

/// The core protocol for any element displayed on a tactile map.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public protocol TactileMapElement: Identifiable, Sendable {
    /// A unique identifier for this element.
    var id: String { get }

    /// The semantic type of this element (corridor, intersection, landmark, etc.).
    var elementType: TactileElementType { get }

    /// The spatial geometry of this element.
    var geometry: TactileGeometry { get }

    /// The typed properties associated with this element.
    var properties: TactileProperties { get }
}

/// A concrete, Codable implementation of ``TactileMapElement``.
///
/// This struct is the primary value type returned by ``TactileMapDocument`` when
/// parsing JSON map files.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public struct MapElement: TactileMapElement, Codable, Hashable, Sendable {

    public let id: String
    public let elementType: TactileElementType
    public let geometry: TactileGeometry
    public let properties: TactileProperties

    public init(
        id: String,
        elementType: TactileElementType,
        geometry: TactileGeometry,
        properties: TactileProperties
    ) {
        self.id = id
        self.elementType = elementType
        self.geometry = geometry
        self.properties = properties
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case elementType = "element_type"
        case geometry
        case properties
    }

    // MARK: - Custom Decodable

    /// Decodes from either the Nav_Indoor GeoJSON-like format or the new TactileMapDocument format.
    ///
    /// Nav_Indoor format:
    /// ```json
    /// {
    ///   "id": "corridor-1",
    ///   "type": "Feature",
    ///   "geometry": { "type": "LineString", "coordinates": [...] },
    ///   "properties": { "name": "Main Hallway", "category": "hallway", ... }
    /// }
    /// ```
    ///
    /// New format:
    /// ```json
    /// {
    ///   "id": "corridor-1",
    ///   "element_type": "corridor",
    ///   "geometry": { ... },
    ///   "properties": { ... }
    /// }
    /// ```
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)
        self.geometry = try container.decode(TactileGeometry.self, forKey: .geometry)
        self.properties = try container.decode(TactileProperties.self, forKey: .properties)

        // Try new-format "element_type" first, then fall back to deriving from properties/geometry
        if let explicitType = try container.decodeIfPresent(TactileElementType.self, forKey: .elementType) {
            self.elementType = explicitType
        } else {
            // In the Nav_Indoor GeoJSON format, element type is inferred from the
            // properties category or geometry type.
            self.elementType = MapElement.inferElementType(
                category: properties.category,
                geometry: geometry
            )
        }
    }

    // MARK: - Custom Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(elementType, forKey: .elementType)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(properties, forKey: .properties)
    }

    // MARK: - Type inference for legacy format

    /// Infers the ``TactileElementType`` from properties and geometry when not
    /// explicitly provided (Nav_Indoor backward compatibility).
    private static func inferElementType(
        category: String?,
        geometry: TactileGeometry
    ) -> TactileElementType {
        // Use category string if it matches a known type
        if let category = category?.lowercased() {
            switch category {
            case "corridor", "hallway":
                return .corridor
            case "intersection", "junction":
                return .intersection
            case "landmark", "room", "elevator", "stairs", "exit", "entrance",
                 "restroom", "bathroom", "office", "door":
                return .landmark
            default:
                // Create a dynamic type from the category name
                return TactileElementType(rawValue: category)
            }
        }

        // Fall back to geometry-based inference
        switch geometry {
        case .point:
            return .intersection
        case .lineString:
            return .corridor
        case .polygon:
            return .landmark
        }
    }
}
