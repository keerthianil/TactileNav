import Foundation

/// An extensible type system for tactile map elements.
///
/// Unlike an enum, this struct-based approach lets teams add new element types
/// without modifying the core module:
/// ```swift
/// extension TactileElementType {
///     static let route = TactileElementType(rawValue: "route")
/// }
/// ```
public struct TactileElementType: RawRepresentable, Hashable, Sendable, Codable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - Built-in types

    /// A walkable corridor segment.
    public static let corridor = TactileElementType(rawValue: "corridor")

    /// A point where two or more corridors meet.
    public static let intersection = TactileElementType(rawValue: "intersection")

    /// A named point of interest (room, elevator, exit, etc.).
    public static let landmark = TactileElementType(rawValue: "landmark")

    // MARK: - Built-in outdoor types

    /// A pedestrian crosswalk.
    public static let crosswalk = TactileElementType(rawValue: "crosswalk")

    /// A navigation route or path overlay.
    public static let route = TactileElementType(rawValue: "route")

    /// A street or sidewalk.
    public static let street = TactileElementType(rawValue: "street")

    /// A major road.
    public static let road = TactileElementType(rawValue: "road")

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension TactileElementType: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}
