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
    /// Crossing paint. Always drawn on the roadway, so white always shows.
    static let crossingStripe = CGColor(gray: 1, alpha: 1)
    static let background = CGColor(gray: 1, alpha: 1)
}

// MARK: - Canvas

final class IntersectionCanvasView: UIView {

    var scene: IntersectionScene? { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let scene, let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(IntersectionPalette.background)
        ctx.fill(rect)

        // Sidewalk first, then the roadway over it, then the markings painted on the roadway.
        //
        // Pavement does not cross asphalt, so the roadway covering the sidewalk is not a
        // drawing trick — it is what is actually on top. Near a junction, sidewalks belonging
        // to the next street along genuinely run into the roadway's footprint, and drawing
        // them last put grey stripes straight across the blue. This order also keeps crossing
        // paint off the pavement for free: the markings are clipped to the roadway, and the
        // roadway is above the sidewalk, so the only grey left visible is off-road.
        let roads = scene.pieces.filter { $0.surface == .road }
        stroke(scene.pieces.filter { $0.surface == .sidewalk }, IntersectionPalette.sidewalk, in: ctx)
        stroke(roads, IntersectionPalette.road, in: ctx)
        drawCrossings(scene.pieces.filter { $0.surface == .crossing }, over: roads, in: ctx)
    }

    /// Strokes a set of pieces, one pass per width.
    ///
    /// All the pieces of a given width go into a single path and are rasterised together. Doing
    /// them one at a time draws each over the last, and every overlap leaves a seam: the two
    /// antialiased edges blend into a line that is visibly darker than either piece. Around a
    /// junction, where a dozen sidewalk ways run alongside and across each other, that is what
    /// made the grey look lumpy and doubled rather than like one continuous pavement.
    private func stroke(_ pieces: [IntersectionPiece], _ color: CGColor, in ctx: CGContext) {
        guard !pieces.isEmpty else { return }
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let byWidth = Dictionary(grouping: pieces.filter { $0.points.count >= 2 }) { $0.width }
        // Widest first, so a narrow way laid over a wide one stays visible.
        for width in byWidth.keys.sorted(by: >) {
            ctx.setLineWidth(width)
            ctx.beginPath()
            for piece in byWidth[width] ?? [] {
                ctx.move(to: piece.points[0])
                for point in piece.points.dropFirst() { ctx.addLine(to: point) }
            }
            ctx.strokePath()
        }
    }

    /// A crossing: white bars painted across the roadway, and nowhere else.
    ///
    /// Clipped to the roadways so the paint stops exactly at the kerb. That is true of a real
    /// crossing — markings exist on asphalt, not on the pavement or the grass beside it — and
    /// it is also what stops the drawing falling apart. Painting a band along the crossing's
    /// whole length instead put grey over the sidewalks it connects, merged neighbouring
    /// crossings into one blob at the corners, and left bars stranded on the background where
    /// the band happened not to reach.
    ///
    /// The bars run *across* the direction you walk and repeat *along* it, which is what a
    /// zebra is. The other way round gives a solid patch that reads as a notch in the road.
    private func drawCrossings(_ pieces: [IntersectionPiece], over roads: [IntersectionPiece],
                               in ctx: CGContext) {
        guard !pieces.isEmpty, !roads.isEmpty else { return }

        let bar = PhysicalDimensions.mmToPoints(IntersectionScene.crossingBarLengthMM)
        let pitch = PhysicalDimensions.mmToPoints(IntersectionScene.crossingBarPitchMM)
        let barWidth = PhysicalDimensions.mmToPoints(IntersectionScene.crossingWidthMM) * 1.9

        // Clip to the roadways. Overlapping outlines union under the default winding rule, so
        // the junction box itself is inside the region and a crossing may be painted across it.
        let roadway = CGMutablePath()
        for road in roads where road.points.count >= 2 {
            let centreline = CGMutablePath()
            centreline.addLines(between: road.points)
            roadway.addPath(centreline.copy(strokingWithWidth: road.width, lineCap: .round,
                                            lineJoin: .round, miterLimit: 10))
        }

        ctx.saveGState()
        ctx.addPath(roadway)
        ctx.clip()
        ctx.setFillColor(IntersectionPalette.crossingStripe)

        for piece in pieces where piece.points.count >= 2 {
            // Walk the real polyline rather than the line between its endpoints — several
            // crossings here bend, and a straight approximation puts the bars off the road.
            let total = polylineLength(piece.points)
            guard total > pitch else { continue }
            var along = pitch / 2
            while along < total {
                guard let at = pointAlongPolyline(piece.points, distance: along),
                      let ahead = pointAlongPolyline(piece.points, distance: min(along + 1, total))
                else { break }
                ctx.saveGState()
                ctx.translateBy(x: at.x, y: at.y)
                ctx.rotate(by: atan2(ahead.y - at.y, ahead.x - at.x))
                ctx.fill(CGRect(x: -bar / 2, y: -barWidth / 2, width: bar, height: barWidth))
                ctx.restoreGState()
                along += pitch
            }
        }
        ctx.restoreGState()
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

    /// Shared, so leaving the screen can silence it from anywhere.
    ///
    /// The close-up owns its own speech, separate from the street map's. When it was owned by
    /// the view, dismissing the screen left whatever it was saying running on over the map —
    /// SwiftUI tears a representable down whenever it likes, which is not the moment the user
    /// pressed back. One shared instance means `stopAll()` is reachable from the screen's own
    /// dismissal path, which is the moment that actually matters.
    static let shared = IntersectionFeedbackController()

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
    private let feedback = IntersectionFeedbackController.shared

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
