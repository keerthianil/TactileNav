import Foundation

/// Configuration for touch hit testing against map elements.
///
/// All radii are in screen points.  ``velocityBonusMax`` and
/// ``velocityDivisor`` control the velocity-adaptive corridor hit
/// radius: `effectiveRadius = corridorBaseRadiusPts + min(velocity / velocityDivisor, velocityBonusMax)`.
public struct HitDetectionConfig: Sendable {

    /// Hit radius (pts) for anchor point annotations.
    public var anchorHitRadiusPts: CGFloat

    /// Hit radius (pts) for point-type elements (landmarks, intersections).
    public var pointHitRadiusPts: CGFloat

    /// Base hit radius (pts) for corridor line segments.
    public var corridorBaseRadiusPts: CGFloat

    /// Maximum additional radius added from touch velocity.
    public var velocityBonusMax: CGFloat

    /// Divisor applied to raw velocity before clamping to ``velocityBonusMax``.
    public var velocityDivisor: CGFloat

    /// Minimum time interval between element-change updates during a drag.
    public var updateThreshold: TimeInterval

    // MARK: - Default

    /// Default hit detection configuration.
    public static let `default` = HitDetectionConfig(
        anchorHitRadiusPts: 20,
        pointHitRadiusPts: 25,
        corridorBaseRadiusPts: 20,
        velocityBonusMax: 30,
        velocityDivisor: 30,
        updateThreshold: 0.1
    )

    // MARK: - Initializer

    /// Creates a hit detection configuration with all parameters.
    public init(
        anchorHitRadiusPts: CGFloat = 20,
        pointHitRadiusPts: CGFloat = 25,
        corridorBaseRadiusPts: CGFloat = 20,
        velocityBonusMax: CGFloat = 30,
        velocityDivisor: CGFloat = 30,
        updateThreshold: TimeInterval = 0.1
    ) {
        self.anchorHitRadiusPts = anchorHitRadiusPts
        self.pointHitRadiusPts = pointHitRadiusPts
        self.corridorBaseRadiusPts = corridorBaseRadiusPts
        self.velocityBonusMax = velocityBonusMax
        self.velocityDivisor = velocityDivisor
        self.updateThreshold = updateThreshold
    }
}
