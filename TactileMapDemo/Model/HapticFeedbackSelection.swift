import Foundation

// MARK: - Map Element Types

enum MapElementType: String, CaseIterable, Identifiable {
    case corridor = "Corridor Line"
    case intersection = "Intersection"
    case landmark = "Landmark"

    var id: String { rawValue }
}

// MARK: - Haptic Pattern Types

enum HapticPatternType: Int, CaseIterable, Identifiable {
    case lightContinuous = 1
    case mediumContinuous = 2
    case sharpTransient = 3
    case rhythmicPulse = 4
    case heavyBuzz = 5

    var id: Int { rawValue }
    var label: String { "Pattern \(rawValue)" }

    var shortName: String {
        switch self {
        case .lightContinuous: return "Light"
        case .mediumContinuous: return "Medium"
        case .sharpTransient: return "Sharp"
        case .rhythmicPulse: return "Pulse"
        case .heavyBuzz: return "Buzz"
        }
    }
}

// MARK: - Haptic Feedback Selection

struct HapticFeedbackSelection {
    var selections: [MapElementType: HapticPatternType]

    static let defaults = HapticFeedbackSelection(selections: [
        .corridor: .mediumContinuous,
        .intersection: .rhythmicPulse,
        .landmark: .sharpTransient
    ])

    func pattern(for element: MapElementType) -> HapticPatternType {
        selections[element] ?? .lightContinuous
    }
}
