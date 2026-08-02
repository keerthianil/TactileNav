import SwiftUI
import Combine
import CoreHaptics
import TactileMapCore
import TactileMapFeedback

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

    var body: some View {
        List {
            Section {
                Text("Tap a pattern to feel it. Needs a device — the simulator has no haptics.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            patternSection(for: .corridor,     title: "Corridor")
            patternSection(for: .intersection, title: "Intersection")
            patternSection(for: .landmark,     title: "Landmark")
        }
        .navigationTitle("Haptic Tester")
        .navigationBarTitleDisplayMode(.inline)
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
