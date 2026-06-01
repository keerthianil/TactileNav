import SwiftUI
import UIKit

/// Hosts SwiftUI content in a UIView that declares the VoiceOver
/// **direct-interaction** trait, so a single finger's touches pass through for
/// tactile exploration instead of being used for VoiceOver navigation.
///
/// Direct interaction swallows the rotor, single-finger swipes, and taps, so
/// the only controls here are the multi-finger gestures VoiceOver still routes
/// to accessibility methods — used for "back". Zoom is handled by ordinary
/// buttons outside this view, which stay fully VoiceOver-accessible.
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
/// VoiceOver back gestures (three-finger swipe right, two-finger Z-scrub).
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
        accessibilityHint = "Touch and drag to explore. "
            + "Use the zoom buttons below the map to change detail. "
            + "Three-finger swipe right, or scrub with two fingers, to go back."
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
