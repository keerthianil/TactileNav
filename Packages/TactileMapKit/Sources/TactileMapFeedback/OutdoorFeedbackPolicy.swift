import TactileMapCore

// MARK: - OutdoorFeedbackPolicy

/// A feedback policy for outdoor navigation, mapping the built-in outdoor
/// element types to the outdoor haptic presets:
///
/// | Element    | Enter                              |
/// |-----------|------------------------------------|
/// | Crosswalk  | sharp tick haptic + speak name     |
/// | Route      | rhythmic pulse haptic              |
/// | Street     | soft continuous haptic             |
/// | Road       | heavy continuous buzz              |
///
/// Everything else (corridors, intersections, landmarks, unknown types, and
/// all non-`onEnter` behavior) falls through to ``DefaultFeedbackPolicy``, so
/// mixed indoor/outdoor documents keep working.  Subclass to customise, exactly
/// like the indoor default:
///
/// ```swift
/// class MyOutdoorPolicy: OutdoorFeedbackPolicy {
///     override func onEnter(element: any TactileMapElement, touchType: TouchType) {
///         if element.elementType == .crosswalk {
///             audioEngine.speak("Crosswalk: \(element.properties.name)")
///             hapticEngine.start(pattern: .crosswalkTick)
///         } else {
///             super.onEnter(element: element, touchType: touchType)
///         }
///     }
/// }
/// ```
@MainActor
open class OutdoorFeedbackPolicy: DefaultFeedbackPolicy {

    open override func onEnter(element: any TactileMapElement, touchType: TouchType) {
        switch element.elementType {
        case .crosswalk:
            hapticEngine.start(pattern: .crosswalkTick)
            audioEngine.speak(element.properties.name)

        case .route:
            hapticEngine.start(pattern: .routePulse)

        case .street:
            hapticEngine.start(pattern: .streetContinuous)

        case .road:
            hapticEngine.start(pattern: .heavyBuzzContinuous)

        default:
            super.onEnter(element: element, touchType: touchType)
        }
    }
}
