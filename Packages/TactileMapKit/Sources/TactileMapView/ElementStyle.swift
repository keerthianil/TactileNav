import UIKit

/// Visual style descriptor for a tactile element type.
///
/// Register styles for custom element types via
/// ``TactileMapViewConfiguration/typeStyles``:
/// ```swift
/// extension TactileElementType {
///     static let staircase = TactileElementType(rawValue: "staircase")
/// }
///
/// var config = TactileMapViewConfiguration.default
/// config.typeStyles[.staircase] = ElementStyle(
///     color: .systemGreen,
///     sizeMM: 7.0,
///     pointShape: .roundedRect(cornerRadius: 3)
/// )
/// ```
public struct ElementStyle: Sendable {

    /// The fill/stroke color for this element type.
    public var color: UIColor

    /// Primary size in millimeters.
    /// - Point geometry: circle diameter or rectangle width
    /// - LineString geometry: stroke width
    /// - Polygon geometry: stroke width (fill uses ``color``)
    public var sizeMM: CGFloat

    /// Optional height in millimeters for rectangular point shapes.
    /// When `nil`, point geometry uses ``sizeMM`` as diameter for circles,
    /// or as both width and height for rounded rectangles.
    public var heightMM: CGFloat?

    /// Shape used when rendering point-geometry elements of this type.
    public var pointShape: PointShape

    /// Whether to display an offset anchor dot for this element type.
    /// Anchor dots provide a larger touch target adjacent to the element,
    /// placed on the nearest corridor.
    public var showAnchorDot: Bool

    /// Shape options for point-geometry elements.
    public enum PointShape: Sendable {
        /// Rendered as a filled circle with a thin border.
        case circle
        /// Rendered as a filled rounded rectangle with a semi-transparent border.
        case roundedRect(cornerRadius: CGFloat)
    }

    public init(
        color: UIColor,
        sizeMM: CGFloat,
        heightMM: CGFloat? = nil,
        pointShape: PointShape = .circle,
        showAnchorDot: Bool = false
    ) {
        self.color = color
        self.sizeMM = sizeMM
        self.heightMM = heightMM
        self.pointShape = pointShape
        self.showAnchorDot = showAnchorDot
    }
}
