//
//  SwipeBackSuppression.swift
//  TactileNav
//
//  Switching off the one-finger swipe-back, for screens where one finger means something else.
//
//  Every tactile screen in this app spends the one-finger channel on exploration: a slow drag
//  across the glass is how you read the map. That is the same gesture the navigation
//  controller uses to go back, so on these screens the swipe-back has to be off entirely.
//  Back is the Back button, the three-finger swipe, and nothing else.
//
//  Two things make this harder than it sounds, and both were learned the hard way:
//
//    • **There are two pop gestures, not one.** The familiar `interactivePopGestureRecognizer`
//      only fires from the left edge. iOS 18 added a second recognizer that pops from a swipe
//      anywhere on the view, and it has no public API. That second one is the one that
//      matters here — an explore drag in the middle of the screen is exactly a full-screen
//      swipe — so blocking only the edge gesture leaves the screen walking away mid-drag.
//
//    • **`isEnabled = false` does not hold.** SwiftUI re-enables the recognizer on its own as
//      the navigation stack updates, and the swipe quietly comes back. Owning the delegate and
//      refusing to let the gesture begin is what survives, so that is the mechanism, and the
//      recognizers are deliberately left enabled — a disabled one is something the system
//      feels entitled to switch back on.
//

import SwiftUI
import UIKit

// MARK: - Finding the navigation controller

extension UIView {
    /// Walk the responder chain to the enclosing navigation controller.
    ///
    /// Falls back to the window's controller tree. SwiftUI attaches a representable's view to
    /// the hierarchy slightly before the navigation controller is reachable through it, so on
    /// the first layout pass the responder walk can come up empty.
    var enclosingNavigationController: UINavigationController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let nav = current as? UINavigationController { return nav }
            if let controller = current as? UIViewController, let nav = controller.navigationController {
                return nav
            }
            responder = current.next
        }
        return window?.rootViewController.flatMap(Self.navigationController(under:))
    }

    private static func navigationController(under controller: UIViewController) -> UINavigationController? {
        if let nav = controller as? UINavigationController { return nav }
        for child in controller.children {
            if let nav = navigationController(under: child) { return nav }
        }
        return controller.presentedViewController.flatMap(navigationController(under:))
    }
}

// MARK: - The delegate that says no

/// Refuses to let a navigation controller's swipe-back gestures start.
final class SwipeBackBlocker: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool { false }

    /// Every pop gesture a navigation controller has — see the note at the top of the file on
    /// why there are two. Reached by selector behind a `responds(to:)` check, so this degrades
    /// to the edge gesture alone anywhere the second one does not exist.
    static func popGestures(of navigation: UINavigationController) -> [UIGestureRecognizer] {
        var gestures: [UIGestureRecognizer] = []
        if let edge = navigation.interactivePopGestureRecognizer {
            gestures.append(edge)
        }
        let selector = NSSelectorFromString("interactiveContentPopGestureRecognizer")
        if navigation.responds(to: selector),
           let fullScreen = navigation.perform(selector)?.takeUnretainedValue()
            as? UIGestureRecognizer {
            gestures.append(fullScreen)
        }
        return gestures
    }
}

// MARK: - Applying and undoing it

/// Holds the swipe-back off for one screen, and hands it back when the screen goes away.
///
/// Re-applying is cheap and idempotent, so callers should do it from every layout pass rather
/// than trying to work out when SwiftUI last touched the recognizers.
final class SwipeBackSuppression {

    private let blocker = SwipeBackBlocker()
    private var originalDelegates: [(UIGestureRecognizer, UIGestureRecognizerDelegate?)] = []

    /// The navigation controller currently suppressed, if any.
    private(set) weak var navigation: UINavigationController?

    func apply(from view: UIView) {
        guard let nav = view.enclosingNavigationController else { return }
        let gestures = SwipeBackBlocker.popGestures(of: nav)
        guard !gestures.isEmpty else { return }

        if navigation !== nav {
            navigation = nav
            originalDelegates = gestures.map { ($0, $0.delegate) }
        }
        for gesture in gestures where !(gesture.delegate is SwipeBackBlocker) {
            gesture.delegate = blocker
        }
    }

    func restore() {
        for (gesture, delegate) in originalDelegates {
            gesture.delegate = delegate
        }
        originalDelegates = []
        navigation = nil
    }
}

// MARK: - SwiftUI

extension View {
    /// Switches off the one-finger swipe-back while this view is on screen.
    ///
    /// For screens where a one-finger drag is exploration rather than navigation.
    func disablesSwipeBack() -> some View {
        overlay(SwipeBackSuppressor().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

/// A zero-size, non-interactive view whose only job is to reach the navigation controller.
///
/// A view rather than a controller, because the responder chain from a plain view is what
/// actually reaches the SwiftUI hosting controller sitting in the navigation stack.
private struct SwipeBackSuppressor: UIViewRepresentable {

    final class HostView: UIView {
        let suppression = SwipeBackSuppression()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                suppression.restore()
            } else {
                suppression.apply(from: self)
                // SwiftUI finishes attaching the navigation controller after this callback,
                // so the first attempt can find nothing to switch off.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil else { return }
                    self.suppression.apply(from: self)
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            suppression.apply(from: self)
        }
    }

    func makeUIView(context: Context) -> HostView { HostView(frame: .zero) }

    func updateUIView(_ view: HostView, context: Context) {
        view.suppression.apply(from: view)
    }

    static func dismantleUIView(_ view: HostView, coordinator: ()) {
        view.suppression.restore()
    }
}
