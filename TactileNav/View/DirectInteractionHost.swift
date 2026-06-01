import SwiftUI
import UIKit

/// Hosts arbitrary SwiftUI content inside a UIView that declares the
/// VoiceOver **direct-interaction** trait, so raw touches pass through to the
/// content (needed for one-finger finger-exploration of a tactile map)
/// instead of being intercepted by VoiceOver's navigation gestures.
///
/// No custom multi-finger gesture recognizers are installed — that keeps
/// VoiceOver's own two-/three-finger gestures (Magic Tap, rotor, scroll)
/// working. Back is handled via the two VoiceOver gestures below:
/// - three-finger swipe right (`accessibilityScroll`)
/// - Z-scrub escape (`accessibilityPerformEscape`)
struct DirectInteractionHost<Content: View>: UIViewRepresentable {
    var onBackGesture: (() -> Void)?
    /// Surfaced as VoiceOver custom actions ("Actions" rotor) so the user can
    /// change stage level while focused on the map, without finding buttons.
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> DirectInteractionView {
        let host = DirectInteractionView()
        host.onBackGesture = onBackGesture
        host.onZoomIn = onZoomIn
        host.onZoomOut = onZoomOut

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
        host.onZoomIn = onZoomIn
        host.onZoomOut = onZoomOut
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
    var onZoomIn:  (() -> Void)? { didSet { refreshCustomActions() } }
    var onZoomOut: (() -> Void)? { didSet { refreshCustomActions() } }

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
        accessibilityHint = "Touch and drag to explore. Use the rotor Actions to change zoom level."
    }

    /// Exposes stage-zoom changes as VoiceOver custom actions, reachable from
    /// the rotor's "Actions" while the map is focused.
    private func refreshCustomActions() {
        var actions: [UIAccessibilityCustomAction] = []
        if onZoomIn != nil {
            actions.append(UIAccessibilityCustomAction(name: "Zoom in to more detail") { [weak self] _ in
                self?.onZoomIn?(); return true
            })
        }
        if onZoomOut != nil {
            actions.append(UIAccessibilityCustomAction(name: "Zoom out for overview") { [weak self] _ in
                self?.onZoomOut?(); return true
            })
        }
        accessibilityCustomActions = actions
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
