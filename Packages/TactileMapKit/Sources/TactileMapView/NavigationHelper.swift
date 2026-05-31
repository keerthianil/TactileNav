import SwiftUI
import UIKit

// MARK: - NavigationControllerModifier

/// A `UIViewRepresentable` that accesses the hosting `UINavigationController`
/// and disables its interactive pop gesture recognizer (edge swipe).
///
/// This prevents the system edge-swipe-to-go-back gesture from
/// interfering with the tactile map's touch gestures.
public struct NavigationControllerModifier: UIViewRepresentable {

    public init() {}

    public func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false

        DispatchQueue.main.async {
            if let navigationController = view.findViewController()?.navigationController {
                navigationController.interactivePopGestureRecognizer?.isEnabled = false
            }
        }

        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        // No updates needed.
    }
}

// MARK: - UIView extension

extension UIView {
    /// Walks the responder chain to find the nearest `UIViewController`
    /// that contains this view.
    public func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
}

// MARK: - View extension

extension View {
    /// Disables the interactive edge swipe pop gesture on the hosting
    /// navigation controller.
    ///
    /// Use this modifier on screens where the tactile map needs full
    /// control of touch gestures near the screen edges.
    public func disableEdgeSwipeGesture() -> some View {
        self.background(NavigationControllerModifier())
    }
}
