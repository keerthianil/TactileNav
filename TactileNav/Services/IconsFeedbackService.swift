import TactileMapCore
import TactileMapFeedback
import AVFoundation

// MARK: - Auditory Icons Feedback Service
// Condition 3: plays a spatialized sound effect matched to the landmark's category.

@MainActor
final class IconsFeedbackService: FeedbackPolicy {

    private let hapticEngine: HapticEngine = CoreHapticsEngine()
    private let audioEngine: SpatialAudioEngine = AVSpatialAudioEngine()

    private static let categoryToSound: [String: String] = [
        "bathroom":        "toilet_flush",
        "restroom":        "toilet_flush",
        "elevator":        "elevator",
        "stairs":          "stairway",
        "stairway":        "stairway",
        "conference_room": "conference_room",
        "vending_machine": "vending_machine",
        "kitchen":         "kitchen",
        "water_fountain":  "water_running",
        "entrance":        "door_knock",
        "traffic_signal":  "door_knock",
        "post_office":     "door_knock",
        "grocery":         "vending_machine",
        "gas_station":     "elevator",
        "barbershop":      "water_running",
        "restaurant":      "kitchen",
        "pet_shop":        "conference_room"
    ]

    init() {
        // Preload all sound assets into the audio engine
        let registry = SoundRegistry()
        let soundNames = ["toilet_flush", "elevator", "stairway", "door_knock",
                          "vending_machine", "kitchen", "water_running"]
        for name in soundNames {
            registry.register(name: name, resource: name, extension: "mp3", bundle: .main)
        }
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        registry.preloadAll(format: monoFormat)
        for name in soundNames {
            if let buffer = registry.buffer(for: name) {
                audioEngine.registerSound(name: name, buffer: buffer)
            }
        }
    }

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
            let sound = Self.categoryToSound[props.category?.lowercased() ?? ""] ?? "door_knock"
            audioEngine.playSpatialSound(sound, at: positionForSide(props.side), volume: 1.0)

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
