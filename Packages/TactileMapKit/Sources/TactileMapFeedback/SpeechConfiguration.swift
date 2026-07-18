import AVFoundation
import QuartzCore

/// Configurable speech settings for TTS announcements.
///
/// Pass to ``SpatialAudioEngine`` methods or use with `AVSpeechUtterance`
/// directly to control voice, rate, and volume.
///
/// ```swift
/// let config = SpeechConfiguration(rate: 0.55, volume: 1.0, language: "en-US")
/// audioEngine.speak("Crosswalk ahead", configuration: config)
/// ```
public struct SpeechConfiguration: Sendable {

    /// Speech rate (0.0 ... 1.0). Default uses the system default rate.
    public var rate: Float

    /// Speech volume (0.0 ... 1.0).
    public var volume: Float

    /// BCP-47 language tag (e.g. "en-US").
    public var language: String

    /// Pitch multiplier (0.5 ... 2.0). 1.0 is the default pitch.
    public var pitchMultiplier: Float

    public init(
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        volume: Float = 1.0,
        language: String = "en-US",
        pitchMultiplier: Float = 1.0
    ) {
        self.rate = rate
        self.volume = volume
        self.language = language
        self.pitchMultiplier = pitchMultiplier
    }

    /// Default configuration matching standard system TTS settings.
    public static let `default` = SpeechConfiguration()

    /// Applies this configuration to an `AVSpeechUtterance`.
    public func apply(to utterance: AVSpeechUtterance) {
        utterance.rate = rate
        utterance.volume = volume
        utterance.pitchMultiplier = pitchMultiplier
        utterance.voice = AVSpeechSynthesisVoice(language: language)
    }
}

/// Prevents the same announcement from being repeated within a configurable
/// time window.
///
/// ```swift
/// let cache = SpeechCache(cooldown: 2.0)
/// if cache.shouldSpeak("Main Street") {
///     audioEngine.speak("Main Street")
/// }
/// ```
public final class SpeechCache: @unchecked Sendable {

    private var lastSpoken: [String: CFTimeInterval] = [:]
    private let cooldown: TimeInterval
    private let lock = NSLock()

    /// Creates a cache with the given cooldown between repeated announcements.
    ///
    /// - Parameter cooldown: Minimum seconds before the same text is spoken
    ///   again. Default is 3 seconds.
    public init(cooldown: TimeInterval = 3.0) {
        self.cooldown = cooldown
    }

    /// Returns `true` if the text has not been spoken within the cooldown window.
    /// Records the current time if returning `true`.
    public func shouldSpeak(_ text: String) -> Bool {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }

        if let last = lastSpoken[text], now - last < cooldown {
            return false
        }
        lastSpoken[text] = now
        return true
    }

    /// Clears all cached entries (e.g. when switching documents).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastSpoken.removeAll()
    }
}
