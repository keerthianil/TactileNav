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

    // MARK: Exploration touches
    //
    // Exploration is driven from raw touches rather than a gesture recognizer. Inside a
    // direct-interaction accessibility element, VoiceOver delivers touches straight to the
    // responder chain, and gesture recognizers on that view do not fire dependably — so a
    // recognizer-based explore works with VoiceOver off and goes completely dead with it on,
    // which is the worst possible failure for this app. Raw touches behave the same either way.
    //
    // **Every point below is already in map content coordinates.** A scroll view scrolls by
    // moving its own `bounds.origin`, and `contentOffset` *is* that origin, so a point in the
    // scroll view's coordinate space has the scroll position baked into it. Adding
    // `contentOffset` on top — the obvious-looking conversion — puts the finger tens of
    // thousands of points off the map, and nothing is ever under it.

    var onExploreBegan: ((CGPoint) -> Void)?
    var onExploreMoved: ((CGPoint) -> Void)?
    var onExploreEnded: (() -> Void)?
    var onExploreTapped: ((CGPoint) -> Void)?

    private var exploreTouch: UITouch?
    private var exploreStartedAt: CFTimeInterval = 0
    private var exploreStartPoint: CGPoint = .zero

    /// A touch this brief and this still is a tap, not a drag.
    private let tapMaxDuration: TimeInterval = 0.45
    private let tapMaxDisplacement: CGFloat = 28

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)

        // A second finger means the user is panning, not exploring.
        let activeCount = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count
            ?? touches.count
        guard activeCount == 1, !isDragging, !isDecelerating, let touch = touches.first else {
            endExplore(cancelled: true)
            return
        }

        exploreTouch = touch
        exploreStartedAt = CACurrentMediaTime()
        exploreStartPoint = touch.location(in: self)
        onExploreBegan?(exploreStartPoint)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = exploreTouch, touches.contains(touch) else { return }
        onExploreMoved?(touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = exploreTouch, touches.contains(touch) else { return }

        let point = touch.location(in: self)
        let travelled = hypot(point.x - exploreStartPoint.x, point.y - exploreStartPoint.y)
        let elapsed = CACurrentMediaTime() - exploreStartedAt
        endExplore(cancelled: false)

        if elapsed <= tapMaxDuration, travelled <= tapMaxDisplacement {
            onExploreTapped?(point)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        endExplore(cancelled: true)
    }

    private func endExplore(cancelled: Bool) {
        guard exploreTouch != nil else { return }
        exploreTouch = nil
        onExploreEnded?()
    }

    /// UIScrollView lays out on every scroll, which makes this a more dependable place to
    /// push the offset than the delegate — it fires for programmatic changes and cannot be
    /// missed if something else takes over as delegate.
    override func layoutSubviews() {
        super.layoutSubviews()
        onOffsetChange?(contentOffset)
    }

    /// What VoiceOver says when focus lands on the map. Leads with the map's name.
    var mapDescription = "Tactile street map"

    func applyAccessibility() {
        if UIAccessibility.isVoiceOverRunning {
            isAccessibilityElement = true
            accessibilityTraits = [.allowsDirectInteraction]
            accessibilityLabel = mapDescription
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

    /// Move VoiceOver focus onto the map and have it read the map's name.
    ///
    /// This is why the name is the *element's own label* rather than a detached string posted
    /// as a `.screenChanged` announcement. A bare string is read into the void: focus still
    /// lands wherever iOS decides, the string competes with the push transition and with the
    /// navigation title, and it is routinely dropped — which is what made the map open without
    /// ever saying which map it was. Focusing the element makes the name what VoiceOver reads,
    /// and leaves the user on the thing they came to explore.
    func announceAsScreenChange() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        applyAccessibility()
        UIAccessibility.post(notification: .screenChanged, argument: self)
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

    /// Holds the one-finger swipe-back off while the map is open.
    let swipeBack = SwipeBackSuppression()

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
            // SwiftUI finishes attaching the navigation controller after this callback, so
            // the first attempt can find nothing to switch off. One more pass on the next
            // runloop turn catches it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.suppressSwipeBack()
            }
        }
    }

    /// Runs from `didMoveToWindow` and `layoutSubviews`, never from `updateUIView`: the
    /// responder chain only reaches a navigation controller once the view is in the hierarchy,
    /// and SwiftUI may never call `updateUIView` again after that point.
    private func suppressSwipeBack() {
        swipeBack.apply(from: self)
    }

    /// Hand the swipe back when the map goes away, so the rest of the app behaves normally.
    func restoreSwipeBack() {
        swipeBack.restore()
    }
}

/// Lets the screen drive the map without owning it — the SwiftUI equivalent of holding a
/// reference to the scroll view.
final class StreetMapCommands {
    var recenter: (() -> Void)?
}

struct PortlandMapView: UIViewRepresentable {

    let map: StreetMap
    /// What VoiceOver reads when focus lands on the map — the map's name first.
    var description = "Tactile street map"
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
            coordinator?.announceArrival()
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

        // --- Exploration runs on raw touches (see the scroll view). Only the back
        // gestures need recognizers, because they are multi-touch.
        coordinator.bindExplorationTouches(on: scrollView)

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
        scrollView.mapDescription = description
        scrollView.applyAccessibility()

        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)

        return container
    }

    func updateUIView(_ container: PortlandStreetMapContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        container.scrollView.mapDescription = description
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

        /// A point on the map → where it currently sits on screen.
        ///
        /// The only conversion needed anywhere in exploration, and it runs this way round:
        /// touches arrive in content coordinates already (see the scroll view), and the follow
        /// dot rides on the canvas, which does not scroll.
        private func viewPoint(_ contentPoint: CGPoint) -> CGPoint {
            guard let scrollView else { return contentPoint }
            return CGPoint(x: contentPoint.x - scrollView.contentOffset.x,
                           y: contentPoint.y - scrollView.contentOffset.y)
        }

        private var currentProbeID: String?
        /// What is under the finger — a junction, a road, or nothing. Readable so a test can
        /// drive the real touch path and check what it resolved to, rather than re-deriving it.
        private(set) var currentProbe: MapProbe?
        /// The road under the finger, when it is on a road rather than a junction.
        var currentFeature: StreetFeature? {
            if case .road(let road) = currentProbe { return road }
            return nil
        }
        private var lastPoint: CGPoint?
        private var lastMoveTime: CFTimeInterval = 0
        private var lastHitTestTime: CFTimeInterval = 0
        private var isExploring = false
        private var backTriggered = false
        private var hasCentered = false
        private var hasAnnouncedArrival = false
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
            // Everything a trace needs to be interpreted after the fact.
            //
            // The two sizing numbers are recorded separately and both matter. Points per metre
            // is what converts a logged position back to ground distance. Lane width is the
            // physical width of the line the finger was following, and it is *not* derived
            // from the scale — so the same drag covers a different number of streets on
            // devices of different pixel density, and a trace cannot be read without both.
            logger.startSession(metadata: [
                "map": "CongressSquare",
                "surfaces": "roads",
                "streetCount": "\(map.features.count)",
                "pointsPerMeter": String(format: "%.3f", map.metrics.pointsPerMeter),
                "laneWidthPoints": String(format: "%.2f", map.metrics.laneWidthPoints),
                "laneWidthMM": String(format: "%.1f", StreetMapSizing.laneWidthMM),
                "blockSpacingMM": String(format: "%.1f", StreetMapSizing.blockSpacingMM),
                "contentSize": "\(Int(map.contentSize.width))x\(Int(map.contentSize.height))",
                "voiceOver": UIAccessibility.isVoiceOverRunning ? "on" : "off",
            ])
        }

        func endLogging() {
            guard loggingStarted else { return }
            loggingStarted = false
            logger.endSession()
        }

        /// Touch events carry the content-space point, so a trace can be replayed against the
        /// map, and what the finger was on — a street, a junction, or `Background` for the
        /// space between them, which is what makes on-street time measurable from a trace.
        ///
        /// The point is in content coordinates, not screen coordinates: the map is far larger
        /// than the screen, so a screen point means nothing once the map has been panned.
        private func logTouch(_ type: TouchEventType, at point: CGPoint, probe: MapProbe?) {
            guard loggingStarted else { return }
            let scale = parent.map.metrics.pointsPerMeter

            let name: String
            let elementType: TactileElementType?
            let kind: String
            switch probe {
            case .intersection(let junction):
                name = junction.streetNames.joined(separator: " and ")
                elementType = .intersection
                kind = "intersection"
            case .road(let road):
                name = road.name
                elementType = .road
                kind = "road"
            case nil:
                name = "Background"
                elementType = nil
                kind = "background"
            }

            _ = logger.logEvent(TouchEvent(
                timestamp: Date(),
                sessionElapsed: Date().timeIntervalSince(sessionStart),
                eventType: type,
                elementName: name,
                elementType: elementType,
                touchPoint: point,
                custom: [
                    "gesture": "explore",
                    "on": kind,
                    // Metres from the map's north-west corner, so a trace can be compared
                    // across devices — the point scale differs with pixel density.
                    "metersX": String(format: "%.1f", point.x / scale),
                    "metersY": String(format: "%.1f", point.y / scale),
                ]))
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

        /// Hand VoiceOver the map once it is on screen and laid out.
        ///
        /// Deliberately late and deliberately delayed. Posting at the moment the map finishes
        /// loading lands in the middle of the navigation push, and iOS drops screen-change
        /// posts made during a transition — so the announcement simply never happened.
        func announceArrival() {
            guard !hasAnnouncedArrival else { return }
            hasAnnouncedArrival = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.scrollView?.announceAsScreenChange()
            }
        }

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




        // MARK: Exploration

        /// Wire the scroll view's raw touch stream to exploration.
        func bindExplorationTouches(on scrollView: PortlandStreetScrollView) {
            scrollView.onExploreBegan = { [weak self] point in self?.exploreBegan(at: point) }
            scrollView.onExploreMoved = { [weak self] point in self?.exploreMoved(to: point) }
            scrollView.onExploreEnded = { [weak self] in self?.exploreEnded() }
            scrollView.onExploreTapped = { [weak self] point in self?.exploreTapped(at: point) }
        }

        private func exploreBegan(at point: CGPoint) {
            startLoggingIfNeeded()
            isExploring = true
            panSettleWork?.cancel()
            // A finger on the glass outranks the entry summary still playing over it.
            feedback.beginExploring()
            lastPoint = point
            lastMoveTime = CACurrentMediaTime()
            lastHitTestTime = 0
            currentProbeID = nil

            updateExploration(at: point, velocity: 0)
            logTouch(.touchDown, at: point, probe: currentProbe)
            touchIndicator?.show(at: viewPoint(point))
        }

        private func exploreMoved(to point: CGPoint) {
            let now = CACurrentMediaTime()
            let speed = velocity(to: point, now: now)
            lastPoint = point
            lastMoveTime = now

            // Hit-test at a bounded rate; the indicator still follows every frame.
            if now - lastHitTestTime >= parent.map.hitConfig.updateThreshold {
                lastHitTestTime = now
                updateExploration(at: point, velocity: speed)
            }
            logTouch(.touchMove, at: point, probe: currentProbe)
            touchIndicator?.show(at: viewPoint(point))
        }

        private func exploreEnded() {
            if let last = lastPoint {
                logTouch(.touchUp, at: last, probe: currentProbe)
            }
            isExploring = false
            feedback.stopAll()
            currentProbeID = nil
            currentProbe = nil
            lastPoint = nil
            touchIndicator?.hide()
        }

        /// A quick, still touch speaks what is under it straight away, without waiting for the
        /// dwell a drag uses — the user has already committed. A junction still outranks the
        /// road it sits on, the same as during a drag.
        private func exploreTapped(at point: CGPoint) {
            let announcement: String
            switch parent.map.probe(at: point, velocity: 0) {
            case .intersection(let junction): announcement = junction.announcement
            case .road(let road): announcement = road.announcement
            case nil: return
            }
            feedback.playTap()
            feedback.announceImmediately(announcement)
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

        /// Haptics change the instant the thing under the finger changes; speech is dwell-gated
        /// inside the feedback controller. That split is what lets a fast sweep feel every
        /// street and junction it crosses while only naming the one the finger settles on.
        private func updateExploration(at point: CGPoint, velocity: CGFloat) {
            let probe = parent.map.probe(at: point, velocity: velocity)
            currentProbe = probe

            guard probe?.id != currentProbeID else { return }
            currentProbeID = probe?.id

            switch probe {
            case .intersection(let junction):
                feedback.enterIntersection(identifier: junction.id, announcement: junction.announcement)
            case .road(let road):
                feedback.enter(identifier: road.id, announcement: road.announcement)
            case nil:
                // Empty space is silent: no haptic, nothing spoken.
                feedback.leaveAll()
            }
        }
    }
}
