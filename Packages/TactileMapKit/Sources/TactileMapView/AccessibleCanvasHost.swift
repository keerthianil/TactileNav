import UIKit

/// A `UIView` subclass that intercepts VoiceOver accessibility gestures
/// for the Canvas-based tactile map.
///
/// This is the Canvas-mode equivalent of ``AccessibleMapView``. It
/// provides the same VoiceOver gesture support:
///
/// - Three-finger swipe right triggers ``onBackGesture``.
/// - Z-scrub (two-finger Z) escape triggers ``onBackGesture``.
///
/// Both gestures provide haptic feedback via `UIImpactFeedbackGenerator`
/// and post a VoiceOver announcement to confirm the action.
class AccessibleCanvasHost: UIView {

    /// Closure called when the user performs a VoiceOver back gesture
    /// (three-finger swipe right or Z-scrub escape).
    var onBackGesture: (() -> Void)?

    /// Whether VoiceOver back gestures are enabled.
    var isBackGestureEnabled: Bool = true

    // MARK: - Setup

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityLabel = "Tactile map"
        accessibilityHint = "Touch to explore"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityLabel = "Tactile map"
        accessibilityHint = "Touch to explore"
    }

    // MARK: - VoiceOver scroll gesture

    /// Handles the VoiceOver three-finger swipe gesture.
    ///
    /// A swipe right (`.right`) is interpreted as a "go back" action.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard isBackGestureEnabled else { return super.accessibilityScroll(direction) }

        if direction == .right {
            performBackGesture()
            return true
        }
        return super.accessibilityScroll(direction)
    }

    // MARK: - VoiceOver escape (Z-scrub)

    /// Handles the VoiceOver Z-scrub escape gesture.
    override func accessibilityPerformEscape() -> Bool {
        guard isBackGestureEnabled else { return false }
        performBackGesture()
        return true
    }

    // MARK: - Private

    private func performBackGesture() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare()
        impact.impactOccurred()

        UIAccessibility.post(
            notification: .announcement,
            argument: "Going back"
        )

        onBackGesture?()
    }
}
