//
//  PortlandMapView.swift
//  TactileNav
//
//  The pannable Congress Square street map.
//
//  Gesture contract, identical with VoiceOver on or off:
//    • one finger, press and drag  → explore (haptics + spoken surface under the finger)
//    • one finger, single tap      → speak the surface under the finger
//    • two fingers, drag           → pan the map, continuously, with momentum
//    • three-finger swipe or drag  → go back
//    • VoiceOver Actions rotor     → pan by half a screen, or recentre
//
//  Panning lives on two fingers because the one-finger channel is the tactile exploration
//  model and cannot be shared. A UIScrollView with `minimumNumberOfTouches = 2` separates
//  the two cleanly and brings momentum, deceleration and rubber-banding with it. Three
//  fingers is not available for panning: VoiceOver reserves it and delivers it as a
//  discrete `accessibilityScroll`, so it stays on back, and the Actions rotor covers users
//  who can't manage a smooth two-finger drag.
//
//  There is deliberately no zoom. Every width on this map is a physical millimetre
//  measurement, and a variable scale would make that untrue.
//

import SwiftUI
import TactileMapCore
import TactileMapLogging
import UIKit

// MARK: - UIKit helpers

extension UIView {
    /// Walk the responder chain to the enclosing navigation controller, so the interactive
    /// edge-swipe pop can be switched off while the map is open. Without that, a one-finger
    /// explore drag started near the left edge navigates back instead of exploring.
    var enclosingNavigationController: UINavigationController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let nav = current as? UINavigationController { return nav }
            if let controller = current as? UIViewController, let nav = controller.navigationController {
                return nav
            }
            responder = current.next
        }
        return nil
    }
}

// MARK: - Touch indicator

/// A follow dot under the finger. Purely a sighted-observer aid — it is never an
/// accessibility element and never affects what is spoken.
final class PortlandTouchIndicatorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer: CGFloat = 16, inner: CGFloat = 5
        ctx.setFillColor(UIColor(red: 1, green: 0.88, blue: 0, alpha: 0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - outer, y: center.y - outer,
                                   width: outer * 2, height: outer * 2))
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: center.x - outer, y: center.y - outer,
                                     width: outer * 2, height: outer * 2))
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner,
                                   width: inner * 2, height: inner * 2))
    }

    func show(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        center = point
        isHidden = false
        CATransaction.commit()
    }

    func hide() { isHidden = true }
}

// MARK: - Scroll view

/// Hosts the canvas and owns the accessibility surface.
///
/// The scroll view rather than the canvas is the accessibility element, because it is the
/// view that stays the size of the screen. `.allowsDirectInteraction` hands raw touches to
/// our recognizers, and `.silentOnTouch` stops VoiceOver speaking on every touch-down —
/// what gets spoken is decided by the exploration logic, not by the touch itself.
final class PortlandStreetScrollView: UIScrollView {

    var onBackGesture: (() -> Void)?
    /// Actions offered on the VoiceOver Actions rotor (swipe up/down, then double-tap).
    var panActions: [(String, () -> Void)] = []
    /// Called whenever the scroll position changes, so the canvas can redraw the new window.
    var onOffsetChange: ((CGPoint) -> Void)?

    /// UIScrollView lays out on every scroll, which makes this a more dependable place to
    /// push the offset than the delegate — it fires for programmatic changes and cannot be
    /// missed if something else takes over as delegate.
    override func layoutSubviews() {
        super.layoutSubviews()
        onOffsetChange?(contentOffset)
    }

    func applyAccessibility() {
        if UIAccessibility.isVoiceOverRunning {
            isAccessibilityElement = true
            accessibilityTraits = [.allowsDirectInteraction]
            accessibilityLabel = "Tactile street map"
            accessibilityHint = "Drag one finger to explore streets. "
                + "Drag two fingers to pan the map. "
                + "Swipe up or down for pan and recentre actions. "
                + "Three finger swipe right to go back."
            if #available(iOS 17.0, *) { accessibilityDirectTouchOptions = .silentOnTouch }
        } else {
            isAccessibilityElement = false
            accessibilityTraits = []
        }
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            panActions.map { name, handler in
                UIAccessibilityCustomAction(name: name) { _ in handler(); return true }
            }
        }
        set {}
    }

    // VoiceOver three-finger swipe right → back. This and the Back button are the only two
    // ways out: nothing a single finger can do navigates away, so exploring anywhere on the
    // map — including hard against the left edge — is always safe.
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if direction == .right {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
            UIAccessibility.post(notification: .announcement, argument: "Going back")
            onBackGesture?()
            return true
        }
        return super.accessibilityScroll(direction)
    }
}

// MARK: - PortlandMapView

/// Container holding the canvas and, above it, the scroll view that drives it.
///
/// The canvas cannot live *inside* the scroll view: at this scale a view the size of the map
/// is far larger than a CALayer can back. So the scroll view scrolls an empty spacer, and the
/// canvas redraws the window that scrolling exposes. The scroll view sits on top and stays
/// transparent, so it receives every touch while the canvas below it is what is seen.
final class PortlandStreetMapContainerView: UIView {
    let canvas = PortlandStreetCanvasView(frame: .zero)
    let scrollView = PortlandStreetScrollView(frame: .zero)
    /// Empty, never drawn, exists only to give the scroll view something the size of the map.
    ///
    /// Non-interactive on purpose. If touches land on it, they belong to "content" as far as
    /// the scroll view is concerned, and the scroll view will not steal them back to start a
    /// pan — the map simply refuses to move.
    let spacer = UIView(frame: .zero)

    /// Fired once the container has a real size, so the viewport can be centred. SwiftUI may
    /// never call `updateUIView` again after the first layout pass, so centring cannot wait
    /// there or the map opens stuck in the corner of the extract.
    var onFirstLayout: (() -> Void)?
    private var hasLaidOut = false

    /// The navigation controller whose swipe-back was switched off, so it can be restored.
    private(set) weak var suppressedPopNavigation: UINavigationController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(cgColor: StreetMapSizing.backgroundColor)
        addSubview(canvas)
        scrollView.backgroundColor = .clear
        spacer.isUserInteractionEnabled = false
        scrollView.addSubview(spacer)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        scrollView.frame = bounds
        suppressSwipeBack()
        guard !hasLaidOut, bounds.width > 0, bounds.height > 0 else { return }
        hasLaidOut = true
        onFirstLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            restoreSwipeBack()
        } else {
            suppressSwipeBack()
        }
    }

    /// Turn off the one-finger swipe-back.
    ///
    /// Done from `didMoveToWindow` and every layout, not from `updateUIView`: the responder
    /// chain only reaches a navigation controller once the view is actually in the hierarchy,
    /// and SwiftUI may never call `updateUIView` again after that happens. Getting this wrong
    /// leaves the swipe live, and a one-finger explore drag walks straight out of the map.
    private func suppressSwipeBack() {
        guard let nav = enclosingNavigationController else { return }
        suppressedPopNavigation = nav
        nav.interactivePopGestureRecognizer?.isEnabled = false
    }

    func restoreSwipeBack() {
        suppressedPopNavigation?.interactivePopGestureRecognizer?.isEnabled = true
        suppressedPopNavigation = nil
    }
}

/// Lets the screen drive the map without owning it — the SwiftUI equivalent of holding a
/// reference to the scroll view.
final class StreetMapCommands {
    var recenter: (() -> Void)?
}

struct PortlandMapView: UIViewRepresentable {

    let map: StreetMap
    var commands: StreetMapCommands?
    var onBackGesture: (() -> Void)?

    func makeUIView(context: Context) -> PortlandStreetMapContainerView {
        makeContainer(coordinator: context.coordinator)
    }

    /// Builds and wires the whole hierarchy.
    ///
    /// Split out from `makeUIView` because `Context` cannot be constructed outside SwiftUI,
    /// and the gesture and scrolling configuration here is exactly the part worth testing.
    func makeContainer(coordinator: Coordinator) -> PortlandStreetMapContainerView {
        let container = PortlandStreetMapContainerView(frame: .zero)
        let scrollView = container.scrollView

        scrollView.delegate = coordinator
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never

        // Fixed scale: physical millimetre sizing is only true at one scale.
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.bouncesZoom = false

        // Two fingers to pan, and never more than two — a three-finger back drag must not
        // also pan the map.
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 2

        // A one-finger explore drag must reach the recognizers immediately, with no delay
        // waiting to see whether a scroll is starting.
        scrollView.delaysContentTouches = false

        container.canvas.map = map
        container.spacer.frame = CGRect(origin: .zero, size: map.contentSize)
        scrollView.contentSize = map.contentSize
        coordinator.container = container
        container.onFirstLayout = { [weak coordinator] in
            coordinator?.centerOnInitialLocationIfNeeded()
        }
        scrollView.onOffsetChange = { [weak container] offset in
            container?.canvas.contentOffset = offset
        }
        commands?.recenter = { [weak coordinator] in coordinator?.recenter() }

        // The indicator rides on the canvas, which does not scroll, so it is positioned in
        // view coordinates and needs no offset correction.
        let indicator = PortlandTouchIndicatorView()
        container.addSubview(indicator)
        coordinator.touchIndicator = indicator

        // --- Gestures. Attached to the scroll view so they see touches regardless of where
        // the canvas has scrolled to; locations are converted to canvas space when used.
        let doubleTap = UITapGestureRecognizer(target: coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = coordinator
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesBegan = false
        doubleTap.delaysTouchesEnded = false
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: coordinator,
                                               action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.delegate = coordinator
        singleTap.cancelsTouchesInView = false
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // 0.1 s press latches exploration; the large allowable movement stops the recognizer
        // cancelling as the finger slides, which turns `.changed` into the drag stream.
        let longPress = UILongPressGestureRecognizer(target: coordinator,
                                                     action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.1
        longPress.allowableMovement = 10_000
        longPress.numberOfTouchesRequired = 1
        longPress.delegate = coordinator
        longPress.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(longPress)

        let backSwipe = UISwipeGestureRecognizer(target: coordinator,
                                                 action: #selector(Coordinator.handleBackGesture))
        backSwipe.numberOfTouchesRequired = 3
        backSwipe.direction = .right
        backSwipe.delegate = coordinator
        scrollView.addGestureRecognizer(backSwipe)

        // Three-finger swipe recognizers are unreliable in practice; a slow drag is not.
        let backPan = UIPanGestureRecognizer(target: coordinator,
                                             action: #selector(Coordinator.handleThreeFingerPan(_:)))
        backPan.minimumNumberOfTouches = 3
        backPan.maximumNumberOfTouches = 3
        backPan.delegate = coordinator
        scrollView.addGestureRecognizer(backPan)

        scrollView.onBackGesture = { [weak coordinator] in coordinator?.triggerBack() }
        scrollView.applyAccessibility()

        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)

        return container
    }

    func updateUIView(_ container: PortlandStreetMapContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        container.scrollView.applyAccessibility()
        container.scrollView.onBackGesture = { [weak coordinator] in coordinator?.triggerBack() }
        container.scrollView.panActions = coordinator.makePanActions()

        coordinator.startLoggingIfNeeded()
        coordinator.centerOnInitialLocationIfNeeded()
    }

    static func dismantleUIView(_ container: PortlandStreetMapContainerView, coordinator: Coordinator) {
        coordinator.feedback.stopAll()
        coordinator.endLogging()
        container.restoreSwipeBack()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {

        var parent: PortlandMapView
        let feedback = StreetFeedbackController.shared

        weak var container: PortlandStreetMapContainerView?
        var touchIndicator: PortlandTouchIndicatorView?

        private var scrollView: PortlandStreetScrollView? { container?.scrollView }

        /// A point in the scroll view's own coordinates → the same point on the map.
        private func contentPoint(_ pointInScrollView: CGPoint) -> CGPoint {
            guard let scrollView else { return pointInScrollView }
            return CGPoint(x: pointInScrollView.x + scrollView.contentOffset.x,
                           y: pointInScrollView.y + scrollView.contentOffset.y)
        }

        private var currentFeatureID: String?
        private var currentFeature: StreetFeature?
        private var lastPoint: CGPoint?
        private var lastMoveTime: CFTimeInterval = 0
        private var lastHitTestTime: CFTimeInterval = 0
        private var isExploring = false
        private var backTriggered = false
        private var hasCentered = false
        private var panSettleWork: DispatchWorkItem?

        // MARK: Logging

        let logger = CSVTouchLogger(fileNameGenerator: { _ in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            return "CongressSquare_\(formatter.string(from: Date()))"
        })
        private var loggingStarted = false
        private var sessionStart = Date()

        init(parent: PortlandMapView) { self.parent = parent }

        func startLoggingIfNeeded() {
            guard !loggingStarted else { return }
            loggingStarted = true
            sessionStart = Date()
            let map = parent.map
            // Recorded so a trace can be interpreted later: the same drag covers a different
            // number of streets on devices with different pixel densities, because the map is
            // sized in physical millimetres rather than points.
            logger.startSession(metadata: [
                "map": "CongressSquare",
                "featureCount": "\(map.features.count)",
                "pointsPerMeter": String(format: "%.3f", map.metrics.pointsPerMeter),
                "laneWidthPoints": String(format: "%.2f", map.metrics.laneWidthPoints),
                "contentSize": "\(Int(map.contentSize.width))x\(Int(map.contentSize.height))",
                "voiceOver": UIAccessibility.isVoiceOverRunning ? "on" : "off",
            ])
        }

        func endLogging() {
            guard loggingStarted else { return }
            loggingStarted = false
            logger.endSession()
        }

        /// Touch events carry the canvas-space point so a trace can be replayed against the
        /// map, plus the surface type so a run can be split by what was under the finger.
        private func logTouch(_ type: TouchEventType, at point: CGPoint, feature: StreetFeature?) {
            guard loggingStarted else { return }
            _ = logger.logEvent(TouchEvent(
                timestamp: Date(),
                sessionElapsed: Date().timeIntervalSince(sessionStart),
                eventType: type,
                elementName: feature?.name ?? "Background",
                elementType: feature?.surface.elementType,
                touchPoint: point,
                custom: ["gesture": "explore"]))
        }

        /// Pan is logged where it settles rather than every frame: what matters for
        /// analysis is which part of the map the user chose to look at.
        private func logPanSettled(center: CGPoint) {
            guard loggingStarted else { return }
            let scale = parent.map.metrics.pointsPerMeter
            _ = logger.logEvent(TouchEvent(
                timestamp: Date(),
                sessionElapsed: Date().timeIntervalSince(sessionStart),
                eventType: .touchUp,
                elementName: parent.map.nearestRoadName(to: center, within: 200) ?? "Background",
                elementType: nil,
                touchPoint: center,
                custom: [
                    "gesture": "pan",
                    "centerMetersX": String(format: "%.1f", center.x / scale),
                    "centerMetersY": String(format: "%.1f", center.y / scale),
                ]))
        }

        // MARK: Viewport

        func centerOnInitialLocationIfNeeded() {
            guard !hasCentered, let scrollView, scrollView.bounds.width > 0 else { return }
            hasCentered = true
            center(on: parent.map.initialCenter, animated: false)
        }

        private func center(on point: CGPoint, animated: Bool) {
            guard let scrollView else { return }
            let size = scrollView.bounds.size
            let offset = CGPoint(
                x: clamp(point.x - size.width / 2, 0, max(0, parent.map.contentSize.width - size.width)),
                y: clamp(point.y - size.height / 2, 0, max(0, parent.map.contentSize.height - size.height))
            )
            scrollView.setContentOffset(offset, animated: animated)
        }

        private var viewportCenter: CGPoint {
            guard let scrollView else { return .zero }
            return CGPoint(x: scrollView.contentOffset.x + scrollView.bounds.width / 2,
                           y: scrollView.contentOffset.y + scrollView.bounds.height / 2)
        }

        private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value, low), high)
        }

        /// Half-screen steps on the Actions rotor, for users who can't make a smooth
        /// two-finger drag. North is up, matching the drawing.
        func makePanActions() -> [(String, () -> Void)] {
            [
                ("Pan north", { [weak self] in self?.step(dx: 0, dy: -0.5) }),
                ("Pan south", { [weak self] in self?.step(dx: 0, dy: 0.5) }),
                ("Pan east", { [weak self] in self?.step(dx: 0.5, dy: 0) }),
                ("Pan west", { [weak self] in self?.step(dx: -0.5, dy: 0) }),
                ("Recenter on Congress Square", { [weak self] in self?.recenter() }),
            ]
        }

        /// Jump back to Congress Square.
        ///
        /// The map is about 67 screens wide, so it is genuinely possible to pan away and lose
        /// the thread of where you are. This is the equivalent of the "back to my location"
        /// button on a visual map: one known place you can always return to.
        func recenter() {
            center(on: parent.map.initialCenter, animated: true)
            feedback.playTap()
            announceViewportCenter(prefix: "Recentered")
        }

        private func step(dx: CGFloat, dy: CGFloat) {
            guard let scrollView else { return }
            let size = scrollView.bounds.size
            center(on: CGPoint(x: viewportCenter.x + size.width * dx,
                               y: viewportCenter.y + size.height * dy), animated: true)
            announceViewportCenter(prefix: nil)
        }

        // MARK: Scroll view delegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.canvas.contentOffset = scrollView.contentOffset
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { schedulePanSettled() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            schedulePanSettled()
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            schedulePanSettled()
        }

        /// Wait for motion to actually stop before saying anything, and stay quiet if a
        /// finger is exploring — an orientation cue must never cut across a street name.
        private func schedulePanSettled() {
            panSettleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.logPanSettled(center: self.viewportCenter)
                guard !self.isExploring else { return }
                self.announceViewportCenter(prefix: nil)
            }
            panSettleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        private func announceViewportCenter(prefix: String?) {
            let name = parent.map.nearestRoadName(to: viewportCenter, within: 260)
            let body = name.map { "Near \($0)" } ?? "No street nearby"
            feedback.announceOrientation([prefix, body].compactMap { $0 }.joined(separator: ". "))
        }

        // MARK: Gesture delegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func voiceOverStatusChanged() {
            scrollView?.applyAccessibility()
        }

        // MARK: Gestures

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let point = contentPoint(gesture.location(in: scrollView))
            if let feature = parent.map.feature(at: point, velocity: 0) {
                feedback.playTap()
                feedback.announceImmediately(feature.announcement)
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            // Nothing to drill into on this map. Consumed so a double tap can't be
            // mistaken for two single taps and speak the same street twice.
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let scrollView else { return }
            let pointInView = gesture.location(in: scrollView)
            let point = contentPoint(pointInView)

            switch gesture.state {
            case .began:
                startLoggingIfNeeded()
                isExploring = true
                panSettleWork?.cancel()
                lastPoint = point
                lastMoveTime = CACurrentMediaTime()
                lastHitTestTime = 0
                currentFeatureID = nil
                updateExploration(at: point, velocity: 0)
                logTouch(.touchDown, at: point, feature: currentFeature)
                touchIndicator?.show(at: pointInView)

            case .changed:
                let now = CACurrentMediaTime()
                let speed = velocity(to: point, now: now)
                lastPoint = point
                lastMoveTime = now
                // Hit-test at a bounded rate; the indicator still follows every frame.
                if now - lastHitTestTime >= parent.map.hitConfig.updateThreshold {
                    lastHitTestTime = now
                    updateExploration(at: point, velocity: speed)
                }
                logTouch(.touchMove, at: point, feature: currentFeature)
                touchIndicator?.show(at: pointInView)

            case .ended, .cancelled, .failed:
                logTouch(.touchUp, at: point, feature: currentFeature)
                isExploring = false
                feedback.stopAll()
                currentFeatureID = nil
                currentFeature = nil
                lastPoint = nil
                touchIndicator?.hide()

            default:
                break
            }
        }

        @objc func handleBackGesture() { triggerBack() }

        @objc func handleThreeFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .changed, gesture.translation(in: view).x > 100 { triggerBack() }
            if gesture.state == .ended || gesture.state == .cancelled { backTriggered = false }
        }

        func triggerBack() {
            guard !backTriggered else { return }
            backTriggered = true
            feedback.stopAll()
            feedback.playTap()
            parent.onBackGesture?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.backTriggered = false
            }
        }

        private func velocity(to point: CGPoint, now: CFTimeInterval) -> CGFloat {
            guard let last = lastPoint else { return 0 }
            let elapsed = max(0.001, now - lastMoveTime)
            return hypot(point.x - last.x, point.y - last.y) / CGFloat(elapsed)
        }

        // MARK: Exploration

        /// Haptics change the instant the surface changes; speech is dwell-gated inside the
        /// feedback controller. That split is what lets a fast sweep feel every surface it
        /// crosses while only naming the one the finger settles on.
        private func updateExploration(at point: CGPoint, velocity: CGFloat) {
            let feature = parent.map.feature(at: point, velocity: velocity)
            currentFeature = feature

            guard feature?.id != currentFeatureID else { return }
            currentFeatureID = feature?.id

            if let feature {
                feedback.enter(surface: feature.surface,
                               identifier: feature.id,
                               announcement: feature.announcement)
            } else {
                // Empty space is silent: no haptic, nothing spoken.
                feedback.leaveAll()
            }
        }
    }
}
