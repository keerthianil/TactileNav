import TactileMapCore
import AVFoundation

// MARK: - TouchType

/// Describes how the user's finger relates to the element that
/// triggered feedback.
public enum TouchType: Sendable {
    /// The finger is directly on the element's geometry.
    case direct

    /// The finger is on an anchor point adjacent to the element.
    case anchor
}

// MARK: - FeedbackPolicy protocol

/// A policy object that decides what haptic, audio, and speech feedback
/// to deliver for each map element interaction.
///
/// Consuming apps implement this protocol to customise feedback.  The
/// framework ships ``DefaultFeedbackPolicy`` which reproduces the
/// Nav_Indoor behaviour.
@MainActor
public protocol FeedbackPolicy: AnyObject {

    /// Called once when the user's finger first enters an element.
    func onEnter(element: any TactileMapElement, touchType: TouchType)

    /// Called repeatedly while the finger remains on the same element.
    func onContinue(element: any TactileMapElement, touchType: TouchType)

    /// Called when the finger leaves an element (or moves to a different one).
    func onExit(element: any TactileMapElement)

    /// Called when the user taps (discrete gesture) on an element.
    func onTap(element: any TactileMapElement, touchType: TouchType)

    /// Immediately silence all feedback channels.
    func stopAll()
}

// MARK: - DefaultFeedbackPolicy

/// The default feedback policy that reproduces Nav_Indoor behaviour:
///
/// | Element      | Enter                                       | Exit           | Tap                      |
/// |-------------|---------------------------------------------|----------------|--------------------------|
/// | Corridor     | continuous haptic                            | stop haptics   | single tap + speak name  |
/// | Intersection | pulsing haptic + speak name                  | stop haptics   | single tap + speak name  |
/// | Landmark     | fast pulsing haptic + click + speak name     | stop haptics   | single tap + speak name  |
@MainActor
public final class DefaultFeedbackPolicy: FeedbackPolicy {

    // MARK: - Dependencies

    private let hapticEngine: HapticEngine
    private let audioEngine: SpatialAudioEngine

    // MARK: - Initializers

    /// Creates a policy with the provided engines.
    ///
    /// Use this initializer when you want to share engines across
    /// multiple objects or inject test doubles.
    public init(hapticEngine: HapticEngine, audioEngine: SpatialAudioEngine) {
        self.hapticEngine = hapticEngine
        self.audioEngine = audioEngine
    }

    /// Convenience initializer that creates its own
    /// ``CoreHapticsEngine`` and ``AVSpatialAudioEngine``.
    public convenience init() {
        self.init(
            hapticEngine: CoreHapticsEngine(),
            audioEngine: AVSpatialAudioEngine()
        )
    }

    // MARK: - FeedbackPolicy

    public func onEnter(element: any TactileMapElement, touchType: TouchType) {
        let name = element.properties.name

        switch element.elementType {
        case .corridor:
            hapticEngine.start(pattern: .corridorContinuous)

        case .intersection:
            hapticEngine.start(pattern: .intersectionPulse)
            audioEngine.speak(name)

        case .landmark:
            hapticEngine.start(pattern: .landmarkFastPulse)
            audioEngine.playClickSound()
            audioEngine.speak(name)

        default:
            // Unknown element type -- provide basic tap + speech.
            hapticEngine.playSingleTap()
            audioEngine.speak(name)
        }
    }

    public func onContinue(element: any TactileMapElement, touchType: TouchType) {
        // The default policy does not change feedback while the finger
        // remains on the same element.  Subclass or provide a custom
        // policy to add progressive feedback.
    }

    public func onExit(element: any TactileMapElement) {
        hapticEngine.stopAll()
    }

    public func onTap(element: any TactileMapElement, touchType: TouchType) {
        hapticEngine.playSingleTap()
        audioEngine.speak(element.properties.name)
    }

    public func stopAll() {
        hapticEngine.stopAll()
        audioEngine.stopAll()
    }
}
