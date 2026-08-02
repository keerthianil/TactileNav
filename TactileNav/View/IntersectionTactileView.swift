//
//  IntersectionTactileView.swift
//  TactileNav
//
//  The intersection you can put a finger on.
//
//  Four surfaces, four signatures, so a finger can tell where it is standing without being
//  told:
//
//    roadway    heavy continuous buzz    1.00 / 0.10   deep, unmistakable, and the one place
//                                                      you must not be
//    sidewalk   softer continuous buzz   0.78 / 0.78   same shape, different texture
//    crossing   sharp transient ticks    1.00 / 1.00   discrete taps read as painted markings
//                                                      rather than smearing into the roadway
//                                                      buzz right beside them
//    kerb ramp  silence, then one tap                  the only element that goes quiet first;
//                                                      a landmark you notice by the gap
//
//  Roadway versus sidewalk is the distinction that matters, and it is carried by sharpness
//  rather than by intensity — a low-sharpness rumble and a high-sharpness vibration feel like
//  different materials, where loud and quiet just feels like the same thing further away.
//
//  Exploration runs on raw touches, not a gesture recognizer: inside a direct-interaction
//  accessibility element VoiceOver hands touches to the responder chain, and recognizers on
//  that view do not fire dependably.
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
    /// The paved band a crossing is painted on. Darker than the sidewalk so the two are not
    /// mistaken for each other where they meet at a corner.
    static let crossingSurface = CGColor(gray: 0.42, alpha: 1)
    static let crossingStripe = CGColor(gray: 1, alpha: 1)
    static let kerbRamp = CGColor(red: 0xE5 / 255, green: 0x1D / 255, blue: 0x4B / 255, alpha: 1)
    static let dotBorder = CGColor(gray: 1, alpha: 1)
    static let background = CGColor(gray: 1, alpha: 1)
}

// MARK: - Canvas

final class IntersectionCanvasView: UIView {

    var layout: IntersectionLayout? { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let layout, let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setFillColor(IntersectionPalette.background)
        ctx.fill(rect)

        // Order matters, and it is the order paint goes down in the real world: roadway,
        // then the sidewalk beside it, then the markings painted on the roadway, then the
        // ramps that sit at the ends of those markings.
        stroke(layout.bands.filter { $0.surface == .road }, IntersectionPalette.road, in: ctx)
        stroke(layout.bands.filter { $0.surface == .sidewalk }, IntersectionPalette.sidewalk, in: ctx)
        drawCrossings(layout.bands.filter { $0.surface == .crossing }, in: ctx)
        drawRamps(layout.dots, in: ctx)
    }

    private func stroke(_ bands: [IntersectionBand], _ color: CGColor, in ctx: CGContext) {
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        for band in bands {
            ctx.setLineWidth(band.width)
            ctx.beginPath()
            ctx.move(to: band.from)
            ctx.addLine(to: band.to)
            ctx.strokePath()
        }
    }

    /// A crossing: a paved band from kerb to kerb with white bars painted across it.
    ///
    /// The band underneath is not decoration. Half of a crossing here lies over the roadway
    /// and half over the space beside it, and white paint is invisible against the white
    /// background — so bars alone would make a crossing appear and disappear along its own
    /// length. Real crossings are white on asphalt for exactly the same reason.
    ///
    /// The bars run *across* the direction you walk and repeat *along* it, which is what a
    /// zebra is. Getting it the other way round gives a solid patch that reads as a notch cut
    /// out of the road.
    private func drawCrossings(_ bands: [IntersectionBand], in ctx: CGContext) {
        let stripe = PhysicalDimensions.mmToPoints(IntersectionLayout.crossingStripeWidthMM)
        let count = IntersectionLayout.crossingStripeCount

        for band in bands {
            let dx = band.to.x - band.from.x
            let dy = band.to.y - band.from.y
            let length = max(hypot(dx, dy), 0.001)
            let mid = CGPoint(x: (band.from.x + band.to.x) / 2, y: (band.from.y + band.to.y) / 2)

            ctx.saveGState()
            ctx.translateBy(x: mid.x, y: mid.y)
            ctx.rotate(by: atan2(dy, dx))

            ctx.setFillColor(IntersectionPalette.crossingSurface)
            ctx.fill(CGRect(x: -length / 2, y: -band.width / 2, width: length, height: band.width))

            ctx.setFillColor(IntersectionPalette.crossingStripe)
            // Bars evenly spaced along the walk, inset so none sits half off the end.
            let pitch = length / CGFloat(count + 1)
            for index in 1...count {
                let along = -length / 2 + pitch * CGFloat(index)
                ctx.fill(CGRect(x: along - stripe / 2, y: -band.width / 2,
                                width: stripe, height: band.width))
            }
            ctx.restoreGState()
        }
    }

    private func drawRamps(_ dots: [IntersectionDot], in ctx: CGContext) {
        for dot in dots {
            let radius = dot.diameter / 2
            let box = CGRect(x: dot.center.x - radius, y: dot.center.y - radius,
                             width: dot.diameter, height: dot.diameter)
            ctx.setFillColor(IntersectionPalette.kerbRamp)
            ctx.fillEllipse(in: box)
            // A white ring, so a ramp still reads as a ramp where it sits on the roadway.
            ctx.setStrokeColor(IntersectionPalette.dotBorder)
            ctx.setLineWidth(max(PhysicalDimensions.mmToPoints(0.5), 1))
            ctx.strokeEllipse(in: box)
        }
    }
}

// MARK: - Feedback

/// Haptics and speech for the intersection.
///
/// Separate from the street map's controller because the two screens have different
/// vocabularies, and because this one has to be silent by default: it sits on a screen whose
/// whole point is listening to traffic, so it must never speak over the thing being judged.
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

    func enter(id: String, surface: IntersectionSurface, name: String, speaking: Bool) {
        guard id != activeID else { return }
        activeID = id
        haptics.stopAll()

        switch surface {
        case .road: haptics.start(pattern: .heavyBuzzContinuous)
        case .sidewalk: haptics.start(pattern: .streetContinuous)
        case .crossing: haptics.start(pattern: Self.crossingTick)
        case .kerbRamp:
            // Deliberately no continuous pattern. Everything stops and a single tap fires, so
            // a ramp is found by the silence as much as by the tap.
            haptics.playSingleTap()
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

    private var layout: IntersectionLayout?
    private var trackingTouch: UITouch?

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

    var streetNames: (along: String, across: String) = ("", "") {
        didSet { rebuild() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0, !streetNames.along.isEmpty else { return }
        let built = IntersectionLayout.build(size: bounds.size,
                                             alongName: streetNames.along,
                                             acrossName: streetNames.across)
        layout = built
        canvas.layout = built
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
        accessibilityLabel = "Intersection diagram"
        accessibilityHint = "Drag one finger to feel the roadway, sidewalks, crossings "
            + "and kerb ramps."
        if #available(iOS 17.0, *) { accessibilityDirectTouchOptions = .silentOnTouch }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        trackingTouch = touch
        update(at: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }
        update(at: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTracking()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTracking()
    }

    private func endTracking() {
        trackingTouch = nil
        feedback.leave()
    }

    private func update(at point: CGPoint) {
        guard let layout else { return }
        guard let hit = layout.hit(point) else {
            // Between things. Silence is the right answer: it is how a gap reads as a gap.
            feedback.leave()
            return
        }
        feedback.enter(id: hit.id, surface: hit.surface, name: hit.name, speaking: speaks)
    }

    func stopFeedback() { feedback.stopAll() }
}

// MARK: - SwiftUI wrapper

struct IntersectionTactileView: UIViewRepresentable {

    let alongName: String
    let acrossName: String
    /// Silenced while traffic is playing — see `IntersectionTouchView.speaks`.
    var speaks: Bool

    func makeUIView(context: Context) -> IntersectionTouchView {
        let view = IntersectionTouchView(frame: .zero)
        view.streetNames = (alongName, acrossName)
        view.speaks = speaks
        return view
    }

    func updateUIView(_ view: IntersectionTouchView, context: Context) {
        view.streetNames = (alongName, acrossName)
        view.speaks = speaks
    }

    static func dismantleUIView(_ view: IntersectionTouchView, coordinator: ()) {
        view.stopFeedback()
    }
}
