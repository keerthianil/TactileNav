import TactileMapCore
import TactileMapFeedback
import AVFoundation
import Foundation

// MARK: - Natural Language Feedback Service
// Speaks the element name (+ directional phrase for anchor touches).
// Speech/clicks are debounced so dragging across nearby elements doesn't
// fire a burst of overlapping audio (matches Nav_Indoor's 0.5s rule).

@MainActor
final class NLFeedbackService: FeedbackPolicy {

    private let hapticEngine: HapticEngine = CoreHapticsEngine()
    private let audioEngine: SpatialAudioEngine = AVSpatialAudioEngine()

    // Debounce: skip re-announcing the same thing within this window.
    private var lastAnnouncedKey: String?
    private var lastAnnouncedAt: Date = .distantPast
    private let minRepeatInterval: TimeInterval = 0.5

    // MARK: FeedbackPolicy

    func onEnter(element: any TactileMapElement, touchType: TouchType) {
        let props = element.properties
        switch element.elementType {
        case .corridor:
            hapticEngine.start(pattern: .corridorContinuous)

        case .intersection:
            hapticEngine.start(pattern: .intersectionPulse)
            if shouldAnnounce("ix:\(props.name)") {
                audioEngine.speak(props.name)
            }

        case .landmark:
            hapticEngine.start(pattern: .landmarkFastPulse)
            let text = landmarkText(name: props.name, side: props.side, touchType: touchType)
            if shouldAnnounce("lm:\(props.name):\(touchType)") {
                audioEngine.playClickSound()
                audioEngine.speak(text)
            }

        default:
            hapticEngine.playSingleTap()
            if shouldAnnounce("x:\(props.name)") {
                audioEngine.speak(props.name)
            }
        }
    }

    func onContinue(element: any TactileMapElement, touchType: TouchType) {}

    func onExit(element: any TactileMapElement) {
        hapticEngine.stopAll()
    }

    func onTap(element: any TactileMapElement, touchType: TouchType) {
        hapticEngine.playSingleTap()
        audioEngine.speak(element.properties.name)   // explicit tap always speaks
    }

    func stopAll() {
        hapticEngine.stopAll()
        audioEngine.stopAll()
    }

    // MARK: Private

    /// Returns true if this announcement should play now. Suppresses an
    /// identical announcement repeated within `minRepeatInterval`, but lets
    /// a *different* element through immediately.
    private func shouldAnnounce(_ key: String) -> Bool {
        let now = Date()
        if key == lastAnnouncedKey, now.timeIntervalSince(lastAnnouncedAt) < minRepeatInterval {
            return false
        }
        lastAnnouncedKey = key
        lastAnnouncedAt = now
        return true
    }

    private func landmarkText(name: String, side: String?, touchType: TouchType) -> String {
        switch touchType {
        case .anchor:
            let dir = directionPhrase(for: side)
            return dir.isEmpty ? name : "\(name), \(dir)"
        case .direct:
            return name
        }
    }

    private func directionPhrase(for side: String?) -> String {
        switch side?.lowercased() {
        case "left":           return "on your left"
        case "right":          return "on your right"
        case "ahead", "front": return "ahead"
        case "behind", "back": return "behind you"
        default:               return ""
        }
    }
}
