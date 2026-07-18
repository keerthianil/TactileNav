import CoreHaptics

/// A configurable haptic pattern definition that decouples pattern design
/// from engine playback.
///
/// Create patterns from scratch or use one of the built-in presets that
/// reproduce common tactile map feedback patterns:
///
/// ```swift
/// engine.start(pattern: .corridorContinuous)
/// engine.start(pattern: .intersectionPulse)
/// engine.start(pattern: HapticPattern(intensity: 0.6,
///                                      sharpness: 0.3,
///                                      mode: .transient))
/// ```
public struct HapticPattern: Sendable {

    // MARK: - Properties

    /// Haptic intensity in the range 0.0 ... 1.0.
    public let intensity: Float

    /// Haptic sharpness in the range 0.0 ... 1.0.
    public let sharpness: Float

    /// The temporal shape of the pattern.
    public let mode: HapticMode

    // MARK: - Mode

    /// Describes how a haptic pattern is delivered over time.
    public enum HapticMode: Sendable {
        /// A single sustained vibration for the given duration.
        case continuous(duration: TimeInterval)

        /// Repeating on/off pulses.
        ///
        /// - Parameters:
        ///   - onDuration:  How long each pulse lasts (seconds).
        ///   - offDuration: Silent gap between pulses (seconds).
        ///   - count:       Number of pulse events in a single loop iteration.
        case pulsing(onDuration: TimeInterval, offDuration: TimeInterval, count: Int)

        /// A single, instantaneous tap.
        case transient
    }

    // MARK: - Initializer

    /// Creates a custom haptic pattern.
    ///
    /// - Parameters:
    ///   - intensity: Vibration intensity (0.0 ... 1.0).
    ///   - sharpness: Vibration sharpness (0.0 ... 1.0).
    ///   - mode:      Temporal shape of the pattern.
    public init(intensity: Float, sharpness: Float, mode: HapticMode) {
        self.intensity = intensity
        self.sharpness = sharpness
        self.mode = mode
    }

    // MARK: - Built-in presets

    /// Steady continuous vibration for corridors.
    ///
    /// Intensity 1.0, sharpness 0.5, 100-second continuous event.
    public static let corridorContinuous = HapticPattern(
        intensity: 1.0,
        sharpness: 0.5,
        mode: .continuous(duration: 100.0)
    )

    /// Standard pulsing vibration for intersections.
    ///
    /// Intensity 1.0, sharpness 0.5, 0.15 s on / 0.10 s off, 20 pulses per loop.
    public static let intersectionPulse = HapticPattern(
        intensity: 1.0,
        sharpness: 0.5,
        mode: .pulsing(onDuration: 0.15, offDuration: 0.10, count: 20)
    )

    /// Fast pulsing vibration for landmarks.
    ///
    /// Intensity 1.0, sharpness 0.7, 0.08 s on / 0.04 s off, 80 pulses per loop.
    public static let landmarkFastPulse = HapticPattern(
        intensity: 1.0,
        sharpness: 0.7,
        mode: .pulsing(onDuration: 0.08, offDuration: 0.04, count: 80)
    )

    /// A single sharp transient tap.
    ///
    /// Intensity 1.0, sharpness 1.0, transient event.
    public static let singleTap = HapticPattern(
        intensity: 1.0,
        sharpness: 1.0,
        mode: .transient
    )

    // MARK: - Outdoor element presets

    /// Sharp transient tick for crosswalk indicators.
    ///
    /// Intensity 1.0, sharpness 1.0, rapid 0.05 s ticks at 0.17 s intervals.
    public static let crosswalkTick = HapticPattern(
        intensity: 1.0,
        sharpness: 1.0,
        mode: .pulsing(onDuration: 0.05, offDuration: 0.12, count: 50)
    )

    /// Rhythmic pulse for route/path overlays.
    ///
    /// Intensity 1.0, sharpness 0.85, distinct from steady road vibrations.
    public static let routePulse = HapticPattern(
        intensity: 1.0,
        sharpness: 0.85,
        mode: .pulsing(onDuration: 0.12, offDuration: 0.08, count: 50)
    )

    /// Steady continuous vibration for streets and sidewalks.
    ///
    /// Intensity 0.78, sharpness 0.78, softer than road/corridor vibration.
    public static let streetContinuous = HapticPattern(
        intensity: 0.78,
        sharpness: 0.78,
        mode: .continuous(duration: 100.0)
    )

    /// Heavy continuous buzz for major roads.
    ///
    /// Intensity 1.0, sharpness 0.1 (deep rumble), 100-second duration.
    public static let heavyBuzzContinuous = HapticPattern(
        intensity: 1.0,
        sharpness: 0.1,
        mode: .continuous(duration: 100.0)
    )
}
