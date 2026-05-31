import TactileMapCore
import TactileMapFeedback
import AVFoundation

// MARK: - Spatialized Audio Feedback Service
// Condition 2: speaks the element name from the landmark's spatial direction via HRTF.

@MainActor
final class SpatialFeedbackService: FeedbackPolicy {

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
            audioEngine.speakSpatially(props.name, at: positionForSide(props.side))

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

    private func positionForSide(_ side: String?) -> AVAudio3DPoint {
        switch side?.lowercased() {
        case "left":           return AVAudio3DPoint(x: -5, y: 0, z: 0)
        case "right":          return AVAudio3DPoint(x:  5, y: 0, z: 0)
        case "ahead", "front": return AVAudio3DPoint(x:  0, y: 0, z: -3)
        case "behind", "back": return AVAudio3DPoint(x:  0, y: 0, z:  3)
        default:               return AVAudio3DPoint(x:  0, y: 0, z:  0)
        }
    }
}
