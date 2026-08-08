//
//  IntersectionTactileView.swift
//  TactileNav
//
//  The intersection you can put a finger on, drawn from the real geometry of that junction.
//
//  Three surfaces, three signatures, so a finger can tell where it is standing without being
//  told:
//
//    roadway    heavy continuous buzz    1.00 / 0.10   deep, unmistakable, and the one place
//                                                      you must not be
//    sidewalk   softer continuous buzz   0.78 / 0.78   same shape, different texture
//    crossing   sharp transient ticks    1.00 / 1.00   discrete taps read as painted markings
//                                                      rather than smearing into the roadway
//                                                      buzz right beside them
//    elsewhere  nothing                                silence is how a gap reads as a gap
//
//  Roadway versus sidewalk is the distinction that matters, and it is carried by sharpness
//  rather than by intensity — a low-sharpness rumble and a high-sharpness vibration feel like
//  different materials, where loud and quiet just feels like the same thing further away.
//
//  **This works with VoiceOver off as well as on, and both need testing.** Exploration runs on
//  raw touches rather than a gesture recognizer, which is what makes the two paths identical:
//  inside a direct-interaction accessibility element VoiceOver hands touches straight to the
//  responder chain, and recognizers on that view do not fire dependably. A recognizer-based
//  version works with VoiceOver off and goes completely dead with it on, so a pass with
//  VoiceOver off proves nothing on its own — and neither does a pass with it on.
//

import AVFoundation
import SwiftUI
import TactileMapCore
import TactileMapFeedback
import UIKit

// MARK: - Palette

nonisolated enum IntersectionPalette {
    static let road = CGColor(red: 0x02 / 255, green: 0x3E / 255, blue: 0x8A / 255, alpha: 1)
    static let sidewalk = CGColor(red: 0x9E / 255, green: 0x9E / 255, blue: 0x9E / 255, alpha: 1)
    static let crossingStripe = CGColor(gray: 1, alpha: 1)
    /// The band a crossing's bars are painted on. Dark enough that white paint shows against
    /// it whether the crossing lies over the roadway or over the background beside it.
    static let crossingSurface = CGColor(gray: 0.42, alpha: 1)
    static let background = CGColor(gray: 1, alpha: 1)
}

// MARK: - Canvas

final class IntersectionCanvasView: UIView {

    var scene: IntersectionScene? { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let scene, let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(IntersectionPalette.background)
        ctx.fill(rect)

        // Paint goes down in the order it does on the ground: roadway, the sidewalk beside it,
        // then the markings painted on top.
        stroke(scene.pieces.filter { $0.surface == .road }, IntersectionPalette.road, in: ctx)
        stroke(scene.pieces.filter { $0.surface == .sidewalk }, IntersectionPalette.sidewalk, in: ctx)
        drawCrossings(scene.pieces.filter { $0.surface == .crossing }, in: ctx)
    }

    private func stroke(_ pieces: [IntersectionPiece], _ color: CGColor, in ctx: CGContext) {
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for piece in pieces where piece.points.count >= 2 {
            ctx.setLineWidth(piece.width)
            ctx.beginPath()
            ctx.move(to: piece.points[0])
            for point in piece.points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
    }

    /// A crossing: a paved band with white bars painted across it.
    ///
    /// The band matters. A real crossing here runs from kerb to kerb, so part of it lies over
    /// the roadway and part over the ground beside it — white bars alone would appear and
    /// disappear along the crossing's own length against the white background. Real crossings
    /// are white on asphalt for exactly the same reason.
    ///
    /// The bars run *across* the direction you walk and repeat *along* it, which is what a
    /// zebra is. The other way round gives a solid patch that reads as a notch in the road.
    private func drawCrossings(_ pieces: [IntersectionPiece], in ctx: CGContext) {
        let bar = PhysicalDimensions.mmToPoints(IntersectionScene.crossingBarLengthMM)
        let bandWidth = PhysicalDimensions.mmToPoints(IntersectionScene.crossingWidthMM) * 1.6
        let count = IntersectionScene.crossingBarCount

        for piece in pieces where piece.points.count >= 2 {
            // Stroke the real polyline rather than a rectangle between its endpoints — a
            // crossing that bends, and several here do, would otherwise be drawn in the wrong
            // place at the wrong angle.
            ctx.setStrokeColor(IntersectionPalette.crossingSurface)
            ctx.setLineWidth(bandWidth)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            ctx.move(to: piece.points[0])
            for point in piece.points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()

            // Bars across the walking direction, evenly spaced along the crossing's length.
            let total = polylineLength(piece.points)
            guard total > 0 else { continue }
            ctx.setFillColor(IntersectionPalette.crossingStripe)
            for index in 1...count {
                let along = total * CGFloat(index) / CGFloat(count + 1)
                guard let at = pointAlongPolyline(piece.points, distance: along),
                      let ahead = pointAlongPolyline(piece.points, distance: min(along + 1, total))
                else { continue }
                let angle = atan2(ahead.y - at.y, ahead.x - at.x)
                ctx.saveGState()
                ctx.translateBy(x: at.x, y: at.y)
                ctx.rotate(by: angle)
                ctx.fill(CGRect(x: -bar / 2, y: -bandWidth / 2, width: bar, height: bandWidth))
                ctx.restoreGState()
            }
        }
    }
}

// MARK: - Feedback

/// Haptics and speech for the close-up.
///
/// Separate from the street map's controller because the two screens have different
/// vocabularies, and because this one has to be able to go quiet: it also sits on the screen
/// whose whole point is listening to traffic, where it must never speak over the thing being
/// judged.
@MainActor
final class IntersectionFeedbackController {

    private let haptics = CoreHapticsEngine()
    private let speech = AVSpeechSynthesizer()
    private var activeID: String?

    /// A sharp tap every 0.17 s. Transient rather than a short continuous pulse: a tap reads
    /// as a discrete marking, where a pulse blurs into the roadway buzz beside it.
    private static let crossingTick = HapticPattern(
        intensity: 1.0, sharpness: 1.0,
        mode: .burst(pulseCount: 1, onDuration: 0.05, offDuration: 0.12))

    /// What the finger is on, or nil between things. Readable so a test can drive the touch
    /// path and check what it resolved to.
    private(set) var currentSurface: IntersectionSurface?

    func enter(id: String, surface: IntersectionSurface, name: String, speaking: Bool) {
        guard id != activeID else { return }
        activeID = id
        haptics.stopAll()

        currentSurface = surface
        switch surface {
        case .road: haptics.start(pattern: .heavyBuzzContinuous)
        case .sidewalk: haptics.start(pattern: .streetContinuous)
        case .crossing: haptics.start(pattern: Self.crossingTick)
        }

        guard speaking else { return }
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: announcement(name))
        } else {
            let utterance = AVSpeechUtterance(string: name)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            speech.speak(utterance)
        }
    }

    /// High priority, so a new name replaces the previous one outright rather than layering
    /// over it. Without this, two names sweeping past each other overlap into noise.
    private func announcement(_ text: String) -> Any {
        if #available(iOS 17.0, *) {
            return NSAttributedString(
                string: text,
                attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.high])
        }
        return text
    }

    func leave() {
        activeID = nil
        currentSurface = nil
        haptics.stopAll()
    }

    func stopAll() {
        leave()
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
    }
}

// MARK: - Touch surface

final class IntersectionTouchView: UIView {

    let canvas = IntersectionCanvasView()
    private let feedback = IntersectionFeedbackController()

    /// Whether entering a surface says its name.
    ///
    /// Off while the traffic simulation is running: the exercise is judging a signal by ear,
    /// and a spoken street name over the top of it is the one thing that makes that
    /// impossible. Haptics stay on either way — they do not compete with listening.
    var speaks = true

    /// Set by the owner. Rebuilding the scene needs both this and a laid-out frame.
    var source: (junction: Intersection, map: StreetMap)? {
        didSet { rebuild() }
    }

    /// Double tap anywhere: go back. Same gesture that opened the screen.
    var onDoubleTap: (() -> Void)?

    private(set) var scene: IntersectionScene?
    private var trackingTouch: UITouch?
    private var touchStartedAt: CFTimeInterval = 0
    private var touchStartPoint: CGPoint = .zero
    private var lastTapTime: CFTimeInterval = 0
    private var lastTapPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(cgColor: IntersectionPalette.background)
        canvas.isUserInteractionEnabled = false
        canvas.isAccessibilityElement = false
        canvas.backgroundColor = .clear
        addSubview(canvas)
        applyAccessibility()

        NotificationCenter.default.addObserver(
            self, selector: #selector(voiceOverChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0, let source else { return }
        let built = IntersectionScene.build(junction: source.junction, map: source.map,
                                            size: bounds.size)
        scene = built
        canvas.scene = built
        applyAccessibility()
    }

    // MARK: Accessibility

    @objc private func voiceOverChanged() { applyAccessibility() }

    /// One direct-interaction element, exactly as the street map does it.
    ///
    /// `.silentOnTouch` stops VoiceOver speaking on every touch-down — what gets said is
    /// decided by what is under the finger, not by the fact that a finger arrived.
    private func applyAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityLabel = scene?.title ?? "Intersection diagram"
        accessibilityHint = "Drag one finger to feel the roadway, the sidewalks and the "
            + "crossings."
        if #available(iOS 17.0, *) { accessibilityDirectTouchOptions = .silentOnTouch }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        trackingTouch = touch
        touchStartedAt = CACurrentMediaTime()
        touchStartPoint = touch.location(in: self)
        explore(at: touchStartPoint)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }
        explore(at: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let point = trackingTouch?.location(in: self) ?? touchStartPoint
        let elapsed = CACurrentMediaTime() - touchStartedAt
        let travelled = hypot(point.x - touchStartPoint.x, point.y - touchStartPoint.y)
        endTracking()

        // Same tap window as the street map, so the two screens feel the same.
        guard elapsed <= 0.45, travelled <= 28 else {
            lastTapTime = 0
            return
        }
        let now = CACurrentMediaTime()
        if now - lastTapTime <= 0.45,
           hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y) <= 48 {
            lastTapTime = 0
            onDoubleTap?()
            return
        }
        lastTapTime = now
        lastTapPoint = point
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTracking()
    }

    private func endTracking() {
        trackingTouch = nil
        feedback.leave()
    }

    /// The surface currently under the finger. Exposed so a test can drive `explore(at:)` and
    /// check the result, with VoiceOver off as well as on.
    var currentSurface: IntersectionSurface? { feedback.currentSurface }

    /// Resolve and act on a point, in this view's coordinates.
    ///
    /// Called straight from the raw touch handlers, and directly from tests — there is no
    /// gesture recognizer in between, which is exactly why the behaviour is identical with
    /// VoiceOver on and off.
    func explore(at point: CGPoint) {
        guard let scene else { return }
        guard let piece = scene.piece(at: point) else {
            // Between things. Silence is the right answer: it is how a gap reads as a gap.
            feedback.leave()
            return
        }
        feedback.enter(id: piece.id, surface: piece.surface, name: piece.name, speaking: speaks)
    }

    func stopFeedback() { feedback.stopAll() }
}

// MARK: - SwiftUI wrapper

struct IntersectionTactileView: UIViewRepresentable {

    let junction: Intersection
    let map: StreetMap
    /// Silenced while traffic is playing — see `IntersectionTouchView.speaks`.
    var speaks: Bool = true
    var onDoubleTap: (() -> Void)?

    func makeUIView(context: Context) -> IntersectionTouchView {
        let view = IntersectionTouchView(frame: .zero)
        view.source = (junction, map)
        view.speaks = speaks
        view.onDoubleTap = onDoubleTap
        return view
    }

    func updateUIView(_ view: IntersectionTouchView, context: Context) {
        if view.source?.junction.id != junction.id {
            view.source = (junction, map)
        }
        view.speaks = speaks
        view.onDoubleTap = onDoubleTap
    }

    static func dismantleUIView(_ view: IntersectionTouchView, coordinator: ()) {
        view.stopFeedback()
    }
}
