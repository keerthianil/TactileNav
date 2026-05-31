import Foundation

/// A simple 2D coordinate used in tactile map geometry.
public struct TactileCoordinate: Codable, Sendable, Hashable {

    /// Horizontal position in the map's coordinate space.
    public let x: Double

    /// Vertical position in the map's coordinate space.
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    // MARK: - Codable (decodes from [x, y] JSON array)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        guard values.count >= 2 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "TactileCoordinate expects an array of at least 2 numbers, got \(values.count)"
            )
        }
        self.x = values[0]
        self.y = values[1]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([x, y])
    }
}

/// The geometry of a tactile map element.
public enum TactileGeometry: Sendable, Hashable {
    /// A single point (e.g., a landmark or intersection).
    case point(TactileCoordinate)

    /// An ordered sequence of coordinates forming a polyline (e.g., a corridor).
    case lineString([TactileCoordinate])

    /// An ordered sequence of coordinates forming a closed polygon.
    case polygon([TactileCoordinate])
}

// MARK: - Codable

extension TactileGeometry: Codable {

    private enum GeometryType: String, Codable {
        case point = "Point"
        case lineString = "LineString"
        case polygon = "Polygon"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(GeometryType.self, forKey: .type)

        switch type {
        case .point:
            let coord = try container.decode(TactileCoordinate.self, forKey: .coordinates)
            self = .point(coord)

        case .lineString:
            let coords = try container.decode([TactileCoordinate].self, forKey: .coordinates)
            self = .lineString(coords)

        case .polygon:
            // GeoJSON polygons wrap coordinates in an extra array: [[ [x,y], [x,y], ... ]]
            // We support both the nested form and the flat form for flexibility.
            if let nested = try? container.decode([[TactileCoordinate]].self, forKey: .coordinates),
               let ring = nested.first {
                self = .polygon(ring)
            } else {
                let coords = try container.decode([TactileCoordinate].self, forKey: .coordinates)
                self = .polygon(coords)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .point(let coord):
            try container.encode(GeometryType.point, forKey: .type)
            try container.encode(coord, forKey: .coordinates)

        case .lineString(let coords):
            try container.encode(GeometryType.lineString, forKey: .type)
            try container.encode(coords, forKey: .coordinates)

        case .polygon(let coords):
            try container.encode(GeometryType.polygon, forKey: .type)
            // Encode in GeoJSON nested ring format
            try container.encode([coords], forKey: .coordinates)
        }
    }
}
