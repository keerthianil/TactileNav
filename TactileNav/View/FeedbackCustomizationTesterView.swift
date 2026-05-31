import SwiftUI
import Combine
import CoreHaptics
import TactileMapCore
import TactileMapFeedback
import TactileMapView

// MARK: - Customizable Feedback Policy

@MainActor
final class CustomizableFeedbackPolicy: FeedbackPolicy, ObservableObject {

    var selection: HapticFeedbackSelection = .defaults
    private let hapticEngine: HapticEngine = CoreHapticsEngine()
    private let audioEngine: SpatialAudioEngine = AVSpatialAudioEngine()

    func onEnter(element: any TactileMapElement, touchType: TouchType) {
        let mapType: MapElementType
        switch element.elementType {
        case .corridor:     mapType = .corridor
        case .intersection: mapType = .intersection
        case .landmark:     mapType = .landmark
        default:
            hapticEngine.playSingleTap()
            audioEngine.speak(element.properties.name)
            return
        }
        let pattern = hapticPattern(for: selection.pattern(for: mapType))
        hapticEngine.start(pattern: pattern)
        if element.elementType != .corridor {
            audioEngine.speak(element.properties.name)
        }
    }

    func onContinue(element: any TactileMapElement, touchType: TouchType) {}

    func onExit(element: any TactileMapElement) { hapticEngine.stopAll() }

    func onTap(element: any TactileMapElement, touchType: TouchType) {
        hapticEngine.playSingleTap()
        audioEngine.speak(element.properties.name)
    }

    func stopAll() { hapticEngine.stopAll(); audioEngine.stopAll() }

    private func hapticPattern(for type: HapticPatternType) -> HapticPattern {
        switch type {
        case .lightContinuous:  return HapticPattern(intensity: 0.3, sharpness: 0.2, mode: .continuous(duration: 60))
        case .mediumContinuous: return .corridorContinuous
        case .sharpTransient:   return .singleTap
        case .rhythmicPulse:    return .intersectionPulse
        case .heavyBuzz:        return HapticPattern(intensity: 1.0, sharpness: 0.1, mode: .continuous(duration: 60))
        }
    }
}

// MARK: - Haptic Previewer (short previews for pattern picker buttons)

@MainActor
final class HapticPreviewer: ObservableObject {
    private var engine: CHHapticEngine?

    init() { setupEngine() }

    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        try? engine?.start()
        engine?.resetHandler = { [weak self] in
            try? self?.engine?.start()
        }
    }

    func preview(_ type: HapticPatternType) {
        guard let engine else { return }
        guard let pattern = try? buildPattern(for: type) else { return }
        if let player = try? engine.makePlayer(with: pattern) {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }

    private func buildPattern(for type: HapticPatternType) throws -> CHHapticPattern {
        switch type {
        case .lightContinuous:
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.3),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2)
                ], relativeTime: 0, duration: 1.2)
            ], parameters: [])

        case .mediumContinuous:
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ], relativeTime: 0, duration: 1.2)
            ], parameters: [])

        case .sharpTransient:
            let events = (0..<3).map { i in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                ], relativeTime: TimeInterval(i) * 0.15)
            }
            return try CHHapticPattern(events: events, parameters: [])

        case .rhythmicPulse:
            let events = (0..<8).map { i in
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ], relativeTime: TimeInterval(i) * 0.2, duration: 0.1)
            }
            return try CHHapticPattern(events: events, parameters: [])

        case .heavyBuzz:
            return try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
                ], relativeTime: 0, duration: 1.2)
            ], parameters: [])
        }
    }
}

// MARK: - Feedback Customization Tester View

struct FeedbackCustomizationTesterView: View {
    @State private var selection = HapticFeedbackSelection.defaults
    @StateObject private var previewer = HapticPreviewer()
    @StateObject private var policy = CustomizableFeedbackPolicy()

    var body: some View {
        List {
            patternSection(for: .corridor,     title: "Corridor")
            patternSection(for: .intersection, title: "Intersection")
            patternSection(for: .landmark,     title: "Landmark")

            Section {
                NavigationLink("Open Demo Map") {
                    CustomizableMapView(policy: policy)
                }
                .font(.headline)
            }
        }
        .navigationTitle("Haptic Tester")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection.selections) { _ in
            policy.selection = selection
        }
    }

    @ViewBuilder
    private func patternSection(for element: MapElementType, title: String) -> some View {
        Section(header: Text(title)) {
            ForEach(HapticPatternType.allCases) { type in
                let isSelected = selection.pattern(for: element) == type
                Button {
                    selection.selections[element] = type
                    previewer.preview(type)
                } label: {
                    HStack {
                        Text(type.shortName)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark").foregroundColor(.blue)
                        }
                    }
                }
                .foregroundColor(.primary)
            }
        }
    }
}

// MARK: - Customizable Map View

struct CustomizableMapView: View {
    @ObservedObject var policy: CustomizableFeedbackPolicy
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let doc = try! TactileMapDocument.load(from: "demo_building", bundle: .main)
        TactileMapView(
            document: doc,
            feedbackPolicy: policy,
            onBackGesture: { dismiss() }
        )
        .ignoresSafeArea()
        .onDisappear { policy.stopAll() }
    }
}
