import SwiftUI
import UIKit

/// Hosts arbitrary SwiftUI content inside a UIView that declares the
/// VoiceOver **direct-interaction** trait, so raw touches pass through to
/// the content (needed for finger-exploration of a tactile map) instead of
/// being intercepted by VoiceOver's navigation gestures.
///
/// Also handles the two VoiceOver "back" gestures:
/// - three-finger swipe right (`accessibilityScroll`)
/// - Z-scrub escape (`accessibilityPerformEscape`)
struct DirectInteractionHost<Content: View>: UIViewRepresentable {
    var onBackGesture: (() -> Void)?
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> DirectInteractionView {
        let host = DirectInteractionView()
        host.onBackGesture = onBackGesture

        let hc = UIHostingController(rootView: content())
        hc.view.backgroundColor = .clear
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.topAnchor.constraint(equalTo: host.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            hc.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        context.coordinator.hostingController = hc
        return host
    }

    func updateUIView(_ host: DirectInteractionView, context: Context) {
        host.onBackGesture = onBackGesture
        context.coordinator.hostingController?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hostingController: UIHostingController<Content>?
    }
}

/// The backing UIView that carries the direct-interaction trait and the
/// VoiceOver back gestures.
final class DirectInteractionView: UIView {
    var onBackGesture: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    private func configureAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityLabel = "Tactile map"
        accessibilityHint = "Touch and drag to explore"
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if direction == .right {
            triggerBack()
            return true
        }
        return super.accessibilityScroll(direction)
    }

    override func accessibilityPerformEscape() -> Bool {
        triggerBack()
        return true
    }

    private func triggerBack() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare()
        impact.impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "Going back")
        onBackGesture?()
    }
}
