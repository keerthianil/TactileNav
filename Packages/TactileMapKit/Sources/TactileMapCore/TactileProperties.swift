import Foundation

/// A typed property bag for tactile map elements, replacing untyped `[String: Any]`.
///
/// Uses `CodingKeys` so the JSON wire format can use snake_case
/// (e.g., `"connected_corridors"`) while Swift code uses camelCase.
public struct TactileProperties: Sendable, Codable, Hashable {

    /// Human-readable name of this element (e.g., "Main Hallway").
    public let name: String

    /// Semantic category (e.g., "hallway", "room", "elevator").
    public let category: String?

    /// Spatial orientation hint: "left", "right", "center", etc.
    public let side: String?

    /// Floor / level number within the building.
    public let level: Int?

    /// Whether this element is wheelchair-accessible. Defaults to `true`.
    public let isAccessible: Bool

    /// IDs of corridors connected to this element (useful for intersections).
    public let connectedCorridors: [String]?

    /// Extensible key-value pairs for properties not covered by the typed fields.
    public let custom: [String: String]

    // MARK: - Memberwise initializer

    public init(
        name: String,
        category: String? = nil,
        side: String? = nil,
        level: Int? = nil,
        isAccessible: Bool = true,
        connectedCorridors: [String]? = nil,
        custom: [String: String] = [:]
    ) {
        self.name = name
        self.category = category
        self.side = side
        self.level = level
        self.isAccessible = isAccessible
        self.connectedCorridors = connectedCorridors
        self.custom = custom
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case name
        case category
        case side
        case level
        case isAccessible = "is_accessible"
        case connectedCorridors = "connected_corridors"
        case custom
    }

    // MARK: - Custom Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try container.decode(String.self, forKey: .name)
        self.category = try container.decodeIfPresent(String.self, forKey: .category)
        self.side = try container.decodeIfPresent(String.self, forKey: .side)
        self.level = try container.decodeIfPresent(Int.self, forKey: .level)
        self.isAccessible = try container.decodeIfPresent(Bool.self, forKey: .isAccessible) ?? true
        self.connectedCorridors = try container.decodeIfPresent([String].self, forKey: .connectedCorridors)
        self.custom = try container.decodeIfPresent([String: String].self, forKey: .custom) ?? [:]
    }
}
