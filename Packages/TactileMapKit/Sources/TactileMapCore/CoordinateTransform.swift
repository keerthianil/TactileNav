import Foundation
import CoreLocation
import MapKit
#if canImport(UIKit)
import UIKit
#endif

/// Converts raw JSON coordinates (in the map's pixel/unit coordinate space)
/// to geographic `CLLocationCoordinate2D` values for rendering on MapKit.
///
/// The transform applies a vertical stretch around `centerY` and then divides
/// by `scaleFactor` to produce latitude/longitude values.
public struct CoordinateTransform: Sendable {

    /// Divisor applied to both axes after stretching. Default: 100,000.
    public let scaleFactor: Double

    /// Horizontal stretch multiplier (applied to x). Default: 1.0.
    public let stretchFactorX: Double

    /// Vertical stretch multiplier (applied around `centerY`). Default: 2.6.
    public let stretchFactorY: Double

    /// The y-coordinate that serves as the vertical stretch origin. Default: 500.0.
    public let centerY: Double

    /// The default transform matching the Nav_Indoor coordinate system.
    public static let `default` = CoordinateTransform(
        scaleFactor: 100_000,
        stretchFactorX: 1.0,
        stretchFactorY: 2.6,
        centerY: 500.0
    )

    // MARK: - Initializer

    public init(
        scaleFactor: Double = 100_000,
        stretchFactorX: Double = 1.0,
        stretchFactorY: Double = 2.6,
        centerY: Double = 500.0
    ) {
        self.scaleFactor = scaleFactor
        self.stretchFactorX = stretchFactorX
        self.stretchFactorY = stretchFactorY
        self.centerY = centerY
    }

    // MARK: - Single coordinate

    /// Converts a ``TactileCoordinate`` to a `CLLocationCoordinate2D`.
    ///
    /// The transform applies the stretch first, then divides by the scale factor:
    /// ```
    /// stretchedX = x * stretchFactorX
    /// stretchedY = centerY + (y - centerY) * stretchFactorY
    /// latitude  = stretchedY / scaleFactor
    /// longitude = stretchedX / scaleFactor
    /// ```
    public func toCLCoordinate(_ coord: TactileCoordinate) -> CLLocationCoordinate2D {
        let stretchedX = coord.x * stretchFactorX
        let stretchedY = centerY + (coord.y - centerY) * stretchFactorY
        let latitude = stretchedY / scaleFactor
        let longitude = stretchedX / scaleFactor
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: - Batch conversion

    /// Converts an array of ``TactileCoordinate`` values to `CLLocationCoordinate2D`.
    public func toCLCoordinates(_ coords: [TactileCoordinate]) -> [CLLocationCoordinate2D] {
        coords.map { toCLCoordinate($0) }
    }

    // MARK: - Distance calculations

    /// Returns the Euclidean distance between two coordinates in the
    /// map's raw coordinate space (before any transform).
    ///
    /// When coordinates use real-world units (feet or meters), this
    /// returns the distance in those units.
    public static func distance(from a: TactileCoordinate, to b: TactileCoordinate) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Returns the total length of a polyline (e.g., a corridor).
    ///
    /// When coordinates use real-world units (feet or meters), this
    /// returns the length in those units.
    public static func polylineLength(_ coords: [TactileCoordinate]) -> Double {
        guard coords.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 1..<coords.count {
            total += distance(from: coords[i - 1], to: coords[i])
        }
        return total
    }

    // MARK: - Map rect

    #if canImport(UIKit)
    /// Computes the `MKMapRect` that fits all features in a document, with optional padding.
    ///
    /// - Parameters:
    ///   - document: The ``TactileMapDocument`` whose features define the extent.
    ///   - edgePadding: Insets (in points) to add around the computed rect.
    /// - Returns: An `MKMapRect` that encloses all feature coordinates plus padding.
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    public func mapRect(for document: TactileMapDocument, edgePadding: UIEdgeInsets = .zero) -> MKMapRect {
        var allCoordinates: [CLLocationCoordinate2D] = []

        for feature in document.features {
            switch feature.geometry {
            case .point(let coord):
                allCoordinates.append(toCLCoordinate(coord))
            case .lineString(let coords):
                allCoordinates.append(contentsOf: toCLCoordinates(coords))
            case .polygon(let coords):
                allCoordinates.append(contentsOf: toCLCoordinates(coords))
            }
        }

        guard !allCoordinates.isEmpty else {
            return MKMapRect.null
        }

        // Start with the first point and expand
        let firstPoint = MKMapPoint(allCoordinates[0])
        var minX = firstPoint.x
        var maxX = firstPoint.x
        var minY = firstPoint.y
        var maxY = firstPoint.y

        for coord in allCoordinates.dropFirst() {
            let point = MKMapPoint(coord)
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        // Apply edge padding by expanding the rect
        // Convert point-based padding to MKMapPoint-based padding using
        // an approximate points-per-mapPoint ratio at this zoom level
        let rawRect = MKMapRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )

        // Padding: convert UIEdgeInsets (in screen points) to proportional
        // expansion of the map rect. We estimate by using the ratio of padding
        // to a nominal screen size (375pt wide, 812pt tall).
        let nominalScreenWidth: Double = 375.0
        let nominalScreenHeight: Double = 812.0

        let leftFraction = Double(edgePadding.left) / nominalScreenWidth
        let rightFraction = Double(edgePadding.right) / nominalScreenWidth
        let topFraction = Double(edgePadding.top) / nominalScreenHeight
        let bottomFraction = Double(edgePadding.bottom) / nominalScreenHeight

        let paddedX = rawRect.origin.x - rawRect.size.width * leftFraction
        let paddedY = rawRect.origin.y - rawRect.size.height * topFraction
        let paddedWidth = rawRect.size.width * (1.0 + leftFraction + rightFraction)
        let paddedHeight = rawRect.size.height * (1.0 + topFraction + bottomFraction)

        return MKMapRect(
            x: paddedX,
            y: paddedY,
            width: paddedWidth,
            height: paddedHeight
        )
    }
    #else
    /// Computes the `MKMapRect` that fits all features in a document, with optional padding.
    ///
    /// - Parameters:
    ///   - document: The ``TactileMapDocument`` whose features define the extent.
    ///   - top: Top padding in points.
    ///   - left: Left padding in points.
    ///   - bottom: Bottom padding in points.
    ///   - right: Right padding in points.
    /// - Returns: An `MKMapRect` that encloses all feature coordinates plus padding.
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    public func mapRect(
        for document: TactileMapDocument,
        top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0
    ) -> MKMapRect {
        var allCoordinates: [CLLocationCoordinate2D] = []

        for feature in document.features {
            switch feature.geometry {
            case .point(let coord):
                allCoordinates.append(toCLCoordinate(coord))
            case .lineString(let coords):
                allCoordinates.append(contentsOf: toCLCoordinates(coords))
            case .polygon(let coords):
                allCoordinates.append(contentsOf: toCLCoordinates(coords))
            }
        }

        guard !allCoordinates.isEmpty else {
            return MKMapRect.null
        }

        let firstPoint = MKMapPoint(allCoordinates[0])
        var minX = firstPoint.x
        var maxX = firstPoint.x
        var minY = firstPoint.y
        var maxY = firstPoint.y

        for coord in allCoordinates.dropFirst() {
            let point = MKMapPoint(coord)
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let rawRect = MKMapRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )

        let nominalScreenWidth: Double = 375.0
        let nominalScreenHeight: Double = 812.0

        let leftFraction = left / nominalScreenWidth
        let rightFraction = right / nominalScreenWidth
        let topFraction = top / nominalScreenHeight
        let bottomFraction = bottom / nominalScreenHeight

        let paddedX = rawRect.origin.x - rawRect.size.width * leftFraction
        let paddedY = rawRect.origin.y - rawRect.size.height * topFraction
        let paddedWidth = rawRect.size.width * (1.0 + leftFraction + rightFraction)
        let paddedHeight = rawRect.size.height * (1.0 + topFraction + bottomFraction)

        return MKMapRect(
            x: paddedX,
            y: paddedY,
            width: paddedWidth,
            height: paddedHeight
        )
    }
    #endif
}
