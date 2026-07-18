import Foundation

// MARK: - Supporting types

/// The spatial bounds (width x height) of the map's coordinate space.
public struct TactileMapBounds: Codable, Sendable, Hashable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The unit used for map coordinates.
///
/// When specified in metadata, this tells consumers that coordinate values
/// represent real-world measurements (e.g. feet or meters).
public enum CoordinateUnit: String, Codable, Sendable, Hashable {
    case feet
    case meters
    /// Unitless / arbitrary coordinate space (default).
    case arbitrary
}

/// Optional metadata describing the map document.
public struct TactileMapMetadata: Codable, Sendable, Hashable {
    public let name: String?
    public let buildingName: String?
    public let floor: Int?
    /// Human-readable scale description (e.g. "1 unit = 1 foot").
    public let scale: String?
    /// The real-world unit each coordinate value represents.
    /// When set to `.feet` or `.meters`, distance calculations on
    /// ``CoordinateTransform`` produce real-world distances.
    public let coordinateUnit: CoordinateUnit?
    public let coordinateOrigin: String?
    public let author: String?
    public let created: String?

    public init(
        name: String? = nil,
        buildingName: String? = nil,
        floor: Int? = nil,
        scale: String? = nil,
        coordinateUnit: CoordinateUnit? = nil,
        coordinateOrigin: String? = nil,
        author: String? = nil,
        created: String? = nil
    ) {
        self.name = name
        self.buildingName = buildingName
        self.floor = floor
        self.scale = scale
        self.coordinateUnit = coordinateUnit
        self.coordinateOrigin = coordinateOrigin
        self.author = author
        self.created = created
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case buildingName = "building_name"
        case floor
        case scale
        case coordinateUnit = "coordinate_unit"
        case coordinateOrigin = "coordinate_origin"
        case author
        case created
    }
}

// MARK: - TactileMapDocument

/// Top-level container for a tactile map JSON file.
///
/// Supports two JSON formats:
///
/// **GeoJSON-like FeatureCollection:**
/// ```json
/// {
///   "type": "FeatureCollection",
///   "features": [ ... ],
///   "bounds": { "width": 1000, "height": 1000 }
/// }
/// ```
///
/// **New format:**
/// ```json
/// {
///   "type": "TactileMapDocument",
///   "version": "1.0",
///   "metadata": { ... },
///   "bounds": { "width": 1000, "height": 1000 },
///   "features": [ ... ]
/// }
/// ```
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public struct TactileMapDocument: Codable, Sendable {

    /// Document format version (nil for legacy FeatureCollection files).
    public let version: String?

    /// Coordinate-space bounds of the map.
    public let bounds: TactileMapBounds

    /// All map elements (corridors, intersections, landmarks, etc.).
    public let features: [MapElement]

    /// Optional metadata about the building / floor / author.
    public let metadata: TactileMapMetadata?

    // MARK: - Memberwise initializer

    public init(
        version: String? = nil,
        bounds: TactileMapBounds,
        features: [MapElement],
        metadata: TactileMapMetadata? = nil
    ) {
        self.version = version
        self.bounds = bounds
        self.features = features
        self.metadata = metadata
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case type
        case version
        case bounds
        case features
        case metadata
    }

    // MARK: - Custom Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        _ = try container.decodeIfPresent(String.self, forKey: .type)

        self.version = try container.decodeIfPresent(String.self, forKey: .version)
        self.metadata = try container.decodeIfPresent(TactileMapMetadata.self, forKey: .metadata)

        // Bounds: required in both formats
        if let explicitBounds = try container.decodeIfPresent(TactileMapBounds.self, forKey: .bounds) {
            self.bounds = explicitBounds
        } else {
            // If bounds are missing, compute them from feature coordinates
            let tempFeatures = try container.decode([MapElement].self, forKey: .features)
            self.bounds = TactileMapDocument.computeBounds(from: tempFeatures)
            self.features = tempFeatures
            return
        }

        self.features = try container.decode([MapElement].self, forKey: .features)
    }

    // MARK: - Custom Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("TactileMapDocument", forKey: .type)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encode(bounds, forKey: .bounds)
        try container.encode(features, forKey: .features)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }

    // MARK: - Load from bundle

    /// Loads a ``TactileMapDocument`` from a JSON file in the specified bundle.
    ///
    /// - Parameters:
    ///   - filename: The name of the JSON file (without the `.json` extension).
    ///   - bundle: The bundle containing the file. Defaults to `.main`.
    /// - Returns: A parsed ``TactileMapDocument``.
    /// - Throws: An error if the file cannot be found, read, or decoded.
    public static func load(from filename: String, bundle: Bundle = .main) throws -> TactileMapDocument {
        guard let url = bundle.url(forResource: filename, withExtension: "json") else {
            throw TactileMapDocumentError.fileNotFound(filename)
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(TactileMapDocument.self, from: data)
    }

    // MARK: - Bounds computation

    /// Computes bounding box from all feature coordinates when bounds are not
    /// explicitly specified in the JSON.
    private static func computeBounds(from features: [MapElement]) -> TactileMapBounds {
        var maxX: Double = 0
        var maxY: Double = 0

        for feature in features {
            let coords: [TactileCoordinate]
            switch feature.geometry {
            case .point(let c):
                coords = [c]
            case .lineString(let cs):
                coords = cs
            case .polygon(let cs):
                coords = cs
            }
            for c in coords {
                maxX = max(maxX, c.x)
                maxY = max(maxY, c.y)
            }
        }

        return TactileMapBounds(width: maxX, height: maxY)
    }
}

// MARK: - Errors

/// Errors that can occur when loading a ``TactileMapDocument``.
public enum TactileMapDocumentError: LocalizedError {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "Tactile map file '\(name).json' not found in bundle."
        }
    }
}
