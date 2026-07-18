import UIKit
import MapKit
import TactileMapCore

/// Selects which rendering backend draws the tactile map.
public enum RenderingMode: Sendable {
    /// SwiftUI Canvas — direct 2D drawing with clean junction rendering
    /// and a built-in touch direction indicator. Default for new projects.
    case canvas

    /// MKMapView with overlays and annotations. Geographic coordinate
    /// system. Use when overlaying tactile features on real-world maps.
    case mapKit
}

/// All visual and behavioral configuration for the tactile map view.
///
/// Dimensions are specified in millimeters and converted to screen points
/// at runtime using ``PhysicalDimensions/mmToPoints(_:)`` so that
/// elements are physically the same size across device form factors.
public struct TactileMapViewConfiguration: Sendable {

    // MARK: - Rendering mode

    /// Which rendering backend to use. Defaults to `.canvas`.
    public var renderingMode: RenderingMode

    // MARK: - Visual

    /// Background color for the map view.
    public var backgroundColor: UIColor

    /// Color used to draw corridor polylines.
    public var corridorColor: UIColor

    /// Width of corridor polylines in millimeters.
    public var corridorLineWidthMM: CGFloat

    /// Color used to draw intersection point annotations.
    public var intersectionColor: UIColor

    /// Diameter of intersection circles in millimeters.
    public var intersectionDiameterMM: CGFloat

    /// Color used to draw landmark annotations.
    public var landmarkColor: UIColor

    /// Width of landmark rectangles in millimeters.
    public var landmarkWidthMM: CGFloat

    /// Height of landmark rectangles in millimeters.
    public var landmarkHeightMM: CGFloat

    /// Color used to draw anchor point annotations.
    public var anchorPointColor: UIColor

    /// Diameter of anchor point circles in millimeters.
    public var anchorPointDiameterMM: CGFloat

    // MARK: - Behavior

    /// Edge padding applied when fitting the map rect to the document bounds.
    public var edgePadding: UIEdgeInsets

    /// Whether the VoiceOver three-finger back gesture is enabled.
    public var isVoiceOverBackGestureEnabled: Bool

    /// Minimum press duration for the long-press gesture recognizer.
    public var longPressMinDuration: TimeInterval

    // MARK: - Canvas-specific options

    /// Whether to draw junction discs at intersections where 2+ corridors
    /// meet. The disc covers the star artifact that appears when thick
    /// lines meet at a point. Only used in `.canvas` mode.
    public var junctionDiscEnabled: Bool

    /// Whether to show a directional touch indicator (yellow ring + arrow)
    /// while the user drags their finger. Only used in `.canvas` mode.
    public var showTouchIndicator: Bool

    /// Padding (in points) around the map content in Canvas mode.
    public var canvasPadding: CGFloat

    // MARK: - Per-type styles

    /// Per-type visual styles for custom (or overridden built-in) element types.
    ///
    /// When a type is present here, it takes precedence over the dedicated
    /// built-in properties (``corridorColor``, ``intersectionColor``, etc.).
    ///
    /// Types not present fall back to built-in properties for the three
    /// standard types, or to a geometry-based default for unknown types.
    ///
    /// ```swift
    /// var config = TactileMapViewConfiguration.default
    /// config.typeStyles[.staircase] = ElementStyle(
    ///     color: .systemGreen,
    ///     sizeMM: 7.0,
    ///     pointShape: .roundedRect(cornerRadius: 3)
    /// )
    /// ```
    public var typeStyles: [TactileElementType: ElementStyle]

    // MARK: - Default

    /// Default configuration.
    public static let `default` = TactileMapViewConfiguration(
        renderingMode: .canvas,
        backgroundColor: .white,
        corridorColor: UIColor.systemBlue.withAlphaComponent(0.9),
        corridorLineWidthMM: 4.0,
        intersectionColor: .systemOrange,
        intersectionDiameterMM: 8.0,
        landmarkColor: .systemRed,
        landmarkWidthMM: 6.0,
        landmarkHeightMM: 4.0,
        anchorPointColor: .systemPurple,
        anchorPointDiameterMM: 8.0,
        edgePadding: UIEdgeInsets(top: 30, left: 40, bottom: 120, right: 40),
        isVoiceOverBackGestureEnabled: true,
        longPressMinDuration: 0.1,
        junctionDiscEnabled: true,
        showTouchIndicator: true,
        canvasPadding: 8,
        typeStyles: [:]
    )

    // MARK: - Initializer

    /// Creates a configuration with all parameters.
    ///
    /// Every parameter has a default value matching ``TactileMapViewConfiguration/default``.
    public init(
        renderingMode: RenderingMode = .canvas,
        backgroundColor: UIColor = .white,
        corridorColor: UIColor = UIColor.systemBlue.withAlphaComponent(0.9),
        corridorLineWidthMM: CGFloat = 4.0,
        intersectionColor: UIColor = .systemOrange,
        intersectionDiameterMM: CGFloat = 8.0,
        landmarkColor: UIColor = .systemRed,
        landmarkWidthMM: CGFloat = 6.0,
        landmarkHeightMM: CGFloat = 4.0,
        anchorPointColor: UIColor = .systemPurple,
        anchorPointDiameterMM: CGFloat = 8.0,
        edgePadding: UIEdgeInsets = UIEdgeInsets(top: 30, left: 40, bottom: 120, right: 40),
        isVoiceOverBackGestureEnabled: Bool = true,
        longPressMinDuration: TimeInterval = 0.1,
        junctionDiscEnabled: Bool = true,
        showTouchIndicator: Bool = true,
        canvasPadding: CGFloat = 8,
        typeStyles: [TactileElementType: ElementStyle] = [:]
    ) {
        self.renderingMode = renderingMode
        self.backgroundColor = backgroundColor
        self.corridorColor = corridorColor
        self.corridorLineWidthMM = corridorLineWidthMM
        self.intersectionColor = intersectionColor
        self.intersectionDiameterMM = intersectionDiameterMM
        self.landmarkColor = landmarkColor
        self.landmarkWidthMM = landmarkWidthMM
        self.landmarkHeightMM = landmarkHeightMM
        self.anchorPointColor = anchorPointColor
        self.anchorPointDiameterMM = anchorPointDiameterMM
        self.edgePadding = edgePadding
        self.isVoiceOverBackGestureEnabled = isVoiceOverBackGestureEnabled
        self.longPressMinDuration = longPressMinDuration
        self.junctionDiscEnabled = junctionDiscEnabled
        self.showTouchIndicator = showTouchIndicator
        self.canvasPadding = canvasPadding
        self.typeStyles = typeStyles
    }

    // MARK: - Style resolution

    /// Resolves the visual style for a given element type and geometry.
    ///
    /// Lookup order:
    /// 1. ``typeStyles`` dictionary (explicit per-type override)
    /// 2. Built-in properties for `.corridor`, `.intersection`, `.landmark`
    /// 3. Geometry-based fallback for unregistered custom types
    public func resolvedStyle(
        for elementType: TactileElementType,
        geometry: TactileGeometry
    ) -> ElementStyle {
        if let custom = typeStyles[elementType] {
            return custom
        }

        switch elementType {
        case .corridor:
            return ElementStyle(color: corridorColor, sizeMM: corridorLineWidthMM)
        case .intersection:
            return ElementStyle(color: intersectionColor, sizeMM: intersectionDiameterMM)
        case .landmark:
            return ElementStyle(
                color: landmarkColor,
                sizeMM: landmarkWidthMM,
                heightMM: landmarkHeightMM,
                pointShape: .roundedRect(cornerRadius: 4),
                showAnchorDot: true
            )
        default:
            switch geometry {
            case .point:
                return ElementStyle(color: .systemGray, sizeMM: 6.0)
            case .lineString:
                return ElementStyle(color: .systemGray, sizeMM: 3.0)
            case .polygon:
                return ElementStyle(color: .systemGray, sizeMM: 2.0)
            }
        }
    }
}
