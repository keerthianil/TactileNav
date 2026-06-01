import SwiftUI
import UIKit

/// Hosts arbitrary SwiftUI content inside a UIView that declares the
/// VoiceOver **direct-interaction** trait, so raw touches pass through to
/// the content (needed for one-finger finger-exploration of a tactile map)
/// instead of being intercepted by VoiceOver's navigation gestures.
///
/// Two-finger **pinch** (zoom) and two-finger **pan** are handled by UIKit
/// gesture recognizers installed on the host, so they never collide with the
/// one-finger exploration drag inside the hosted SwiftUI content.
///
/// Also handles the two VoiceOver "back" gestures:
/// - three-finger swipe right (`accessibilityScroll`)
/// - Z-scrub escape (`accessibilityPerformEscape`)
struct DirectInteractionHost<Content: View>: UIViewRepresentable {
    var onBackGesture: (() -> Void)?
    /// Reports the pinch recognizer's cumulative `scale` and its state.
    var onPinch: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    /// Reports the two-finger pan translation (in points) and its state.
    var onPan: ((CGPoint, UIGestureRecognizer.State) -> Void)?
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

        // Two-finger pinch (zoom).
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        host.addGestureRecognizer(pinch)

        // Two-finger pan only (one finger is reserved for exploration).
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        host.addGestureRecognizer(pan)

        return host
    }

    func updateUIView(_ host: DirectInteractionView, context: Context) {
        host.onBackGesture = onBackGesture
        context.coordinator.onPinch = onPinch
        context.coordinator.onPan = onPan
        context.coordinator.hostingController?.rootView = content()
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.onPinch = onPinch
        c.onPan = onPan
        return c
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var hostingController: UIHostingController<Content>?
        var onPinch: ((CGFloat, UIGestureRecognizer.State) -> Void)?
        var onPan: ((CGPoint, UIGestureRecognizer.State) -> Void)?

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            onPinch?(g.scale, g.state)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            onPan?(CGPoint(x: t.x, y: t.y), g.state)
        }

        // Allow pinch and pan to run together.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
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
        accessibilityHint = "Touch and drag to explore. Pinch to zoom, two fingers to pan."
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
