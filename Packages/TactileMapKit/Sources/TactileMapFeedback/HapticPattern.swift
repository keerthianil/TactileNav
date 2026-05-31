import CoreHaptics

/// A configurable haptic pattern definition that decouples pattern design
/// from engine playback.
///
/// Create patterns from scratch or use one of the built-in presets that
/// reproduce the Nav_Indoor behaviour:
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
    /// Matches Nav_Indoor's `startContinuousVibration()`:
    /// intensity 1.0, sharpness 0.5, 100-second continuous event.
    public static let corridorContinuous = HapticPattern(
        intensity: 1.0,
        sharpness: 0.5,
        mode: .continuous(duration: 100.0)
    )

    /// Standard pulsing vibration for intersections.
    ///
    /// Matches Nav_Indoor's `startPulsingVibration()`:
    /// intensity 1.0, sharpness 0.5, 0.15 s on / 0.10 s off, 20 pulses per loop.
    public static let intersectionPulse = HapticPattern(
        intensity: 1.0,
        sharpness: 0.5,
        mode: .pulsing(onDuration: 0.15, offDuration: 0.10, count: 20)
    )

    /// Fast pulsing vibration for landmarks.
    ///
    /// Matches Nav_Indoor's `startFastPulsingVibration()`:
    /// intensity 1.0, sharpness 0.7, 0.08 s on / 0.04 s off, 80 pulses per loop.
    public static let landmarkFastPulse = HapticPattern(
        intensity: 1.0,
        sharpness: 0.7,
        mode: .pulsing(onDuration: 0.08, offDuration: 0.04, count: 80)
    )

    /// A single sharp transient tap.
    ///
    /// Matches Nav_Indoor's `playSingleTap()`:
    /// intensity 1.0, sharpness 1.0, transient event.
    public static let singleTap = HapticPattern(
        intensity: 1.0,
        sharpness: 1.0,
        mode: .transient
    )
}
