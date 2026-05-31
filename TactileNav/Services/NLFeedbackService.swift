import TactileMapCore
import TactileMapFeedback
import AVFoundation

// MARK: - Natural Language Feedback Service
// Condition 1: speaks the element name (+ directional phrase for anchor touches).
// Haptics are identical to DefaultFeedbackPolicy.

@MainActor
final class NLFeedbackService: FeedbackPolicy {

    private let hapticEngine: HapticEngine = CoreHapticsEngine()
    private let audioEngine: SpatialAudioEngine = AVSpatialAudioEngine()

    // MARK: FeedbackPolicy

    func onEnter(element: any TactileMapElement, touchType: TouchType) {
        let props = element.properties
        switch element.elementType {
        case .corridor:
            hapticEngine.start(pattern: .corridorContinuous)

        case .intersection:
            hapticEngine.start(pattern: .intersectionPulse)
            audioEngine.speak(props.name)

        case .landmark:
            hapticEngine.start(pattern: .landmarkFastPulse)
            audioEngine.playClickSound()
            handleLandmark(name: props.name, side: props.side, touchType: touchType)

        default:
            hapticEngine.playSingleTap()
            audioEngine.speak(props.name)
        }
    }

    func onContinue(element: any TactileMapElement, touchType: TouchType) {}

    func onExit(element: any TactileMapElement) {
        hapticEngine.stopAll()
    }

    func onTap(element: any TactileMapElement, touchType: TouchType) {
        hapticEngine.playSingleTap()
        audioEngine.speak(element.properties.name)
    }

    func stopAll() {
        hapticEngine.stopAll()
        audioEngine.stopAll()
    }

    // MARK: Private

    private func handleLandmark(name: String, side: String?, touchType: TouchType) {
        switch touchType {
        case .anchor:
            let dir = directionPhrase(for: side)
            let text = dir.isEmpty ? name : "\(name), \(dir)"
            audioEngine.speak(text)
        case .direct:
            audioEngine.speak(name)
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
