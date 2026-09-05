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
//  One more thing is named rather than felt: the centre, where the crossing roads overlap. It
//  gets the roadway's own buzz, because that is still true — but it is also the one point in the
//  whole junction that says "Center" out loud, so a traveller can find the middle on purpose
//  rather than only ever discovering an edge.
//
//  When a study route runs through this junction, the stretch of roadway it follows gets the
//  route's own rhythmic pulse instead of the plain road buzz — cut from the very same real
//  geometry the city map's route overlay uses, not a second line drawn to match. Where the
//  route actually begins or ends, a yellow dot sits at the junction's centre and speaks its own
//  arrival: "Your location. Route to X." to start, "End of route" to finish.
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
import TactileMapLogging
import UIKit

// MARK: - Palette

nonisolated enum IntersectionPalette {
    static let road = CGColor(red: 0x02 / 255, green: 0x3E / 255, blue: 0x8A / 255, alpha: 1)
    static let sidewalk = CGColor(red: 0x9E / 255, green: 0x9E / 255, blue: 0x9E / 255, alpha: 1)
    /// Crossing paint. Always drawn on the roadway, so white always shows.
    static let crossingStripe = CGColor(gray: 1, alpha: 1)
    static let background = CGColor(gray: 1, alpha: 1)
    /// The kerb dot at each end of a crossing — the reference app's pink (`systemPink`).
    static let crossingEnd = CGColor(red: 1, green: 0x2D / 255, blue: 0x55 / 255, alpha: 1)
    /// White ring, so the dot reads against the grey pavement and the blue roadway alike.
    static let crossingEndBorder = CGColor(gray: 1, alpha: 1)
    /// The study route overlay — the same cyan as the city map's.
    static let route = CGColor(red: 0x48 / 255, green: 0xCA / 255, blue: 0xE4 / 255, alpha: 1)
    /// The route's start and end dot — the reference app's yellow.
    static let routeEndpoint = CGColor(red: 1, green: 0xD7 / 255, blue: 0, alpha: 1)
    static let routeEndpointBorder = CGColor(gray: 1, alpha: 1)

    /// The turn dot — the reference app's orange (#ff8c00), deliberately not the ends' yellow.
    static let routeTurn = CGColor(red: 1, green: 0x8C / 255, blue: 0, alpha: 1)
    static let routeTurnBorder = CGColor(gray: 1, alpha: 1)
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
        // The route sits above the road it runs on — same order as the city map's overlay —
        // and under the crossing markings, which stay painted on the asphalt regardless of
        // whether the route happens to cross it.
        stroke(scene.pieces.filter { $0.surface == .route }, IntersectionPalette.route, in: ctx)
        drawCrossings(scene.pieces.filter { $0.surface == .crossing }, over: roads, in: ctx)
        // Kerb dots, clipped to nothing: a kerb dot marks where a crossing meets the pavement,
        // which is by definition the one place it is *not* on the roadway.
        drawCrossingEnds(scene.pieces.filter { $0.surface == .crossingEnd }, in: ctx)
        // Last of all: the route's own landmarks, which outrank even a kerb dot and so are
        // never drawn underneath one. Turns first, then the ends over them — on the rare
        // corner that is both, "this is where the walk stops" is the more important of the two.
        drawRouteTurns(scene.pieces.filter { $0.surface == .routeTurn }, in: ctx)
        drawRouteEndpoints(scene.pieces.filter { $0.surface == .routeEndpoint }, in: ctx)
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
        guard !pieces.isEmpty else { return }

        let bar = PhysicalDimensions.mmToPoints(IntersectionScene.crossingBarLengthMM)
        let pitch = PhysicalDimensions.mmToPoints(IntersectionScene.crossingBarPitchMM)
        // The paint's own width, not a fattened version of it — the reference app strokes its
        // stripes at exactly the crossing's width, and widening them here only made a zebra
        // read as a solid patch.
        let barWidth = PhysicalDimensions.mmToPoints(IntersectionScene.crossingWidthMM)

        // Painted the whole way across, pavement to pavement, and no longer clipped to the
        // roadway.
        //
        // Clipping was right when a crossing was whatever length the mapper drew: the paint had
        // to be held to the asphalt or it smeared over the pavements and merged into blobs at
        // the corners. The piece is now cut to exactly the stretch between the two pavements —
        // see `crossingSpanningThePavements` — so there is nothing left to clip away, and
        // clipping actively hurt: the last stripe stopped at the kerb, leaving the crossing
        // visibly detached from the pavement it is the whole point of reaching.
        ctx.saveGState()
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

    /// The kerb dots: one at each end of every crossing.
    ///
    /// They answer the question a line of ticks cannot. A crossing under a finger is a run of
    /// identical taps, so there is no way to tell how far along it you are, and in particular
    /// no way to tell that you have reached the far kerb rather than simply lost the line. The
    /// dots put a discrete landmark at each end — the two places a pedestrian actually stands.
    private func drawCrossingEnds(_ pieces: [IntersectionPiece], in ctx: CGContext) {
        guard !pieces.isEmpty else { return }
        let border = PhysicalDimensions.mmToPoints(IntersectionScene.crossingEndBorderMM)
        ctx.setFillColor(IntersectionPalette.crossingEnd)
        ctx.setStrokeColor(IntersectionPalette.crossingEndBorder)
        ctx.setLineWidth(border)

        for piece in pieces {
            guard let centre = piece.points.first else { continue }
            let radius = piece.width / 2
            let box = CGRect(x: centre.x - radius, y: centre.y - radius,
                             width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box)
        }
    }

    /// The route's start or end — a single yellow dot, at most one per screen.
    private func drawRouteEndpoints(_ pieces: [IntersectionPiece], in ctx: CGContext) {
        drawDots(pieces, fill: IntersectionPalette.routeEndpoint,
                 stroke: IntersectionPalette.routeEndpointBorder,
                 borderMM: IntersectionScene.routeEndpointBorderMM, in: ctx)
    }

    /// Every place the route turns, in orange — a different colour from its ends on purpose:
    /// one means "do something here", the other means "this is where the walk stops".
    private func drawRouteTurns(_ pieces: [IntersectionPiece], in ctx: CGContext) {
        drawDots(pieces, fill: IntersectionPalette.routeTurn,
                 stroke: IntersectionPalette.routeTurnBorder,
                 borderMM: IntersectionScene.routeTurnBorderMM, in: ctx)
    }

    private func drawDots(_ pieces: [IntersectionPiece], fill: CGColor, stroke: CGColor,
                          borderMM: CGFloat, in ctx: CGContext) {
        guard !pieces.isEmpty else { return }
        ctx.setFillColor(fill)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(PhysicalDimensions.mmToPoints(borderMM))

        for piece in pieces {
            guard let centre = piece.points.first else { continue }
            let radius = piece.width / 2
            let box = CGRect(x: centre.x - radius, y: centre.y - radius,
                             width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box)
        }
    }
}

// MARK: - Feedback

/// Haptics and audio for the close-up.
///
/// Separate from the street map's controller because the two screens have different
/// vocabularies, and because this one has to be able to go quiet: it also sits on the screen
/// whose whole point is listening to traffic, where it must never speak over the thing being
/// judged.
///
/// Speech itself is *not* separate. It goes through the one channel the whole app shares, so
/// a name started here is stopped by anything that speaks next, wherever that happens — see
/// `TactileSpeechChannel`. A second synthesizer living here is exactly what left the close-up
/// naming a crossing over the top of the map the user had gone back to.
@MainActor
final class IntersectionFeedbackController {

    /// Shared, so leaving the screen can silence it from anywhere.
    ///
    /// When the controller was owned by the view, dismissing the screen left whatever it was
    /// saying running on over the map — SwiftUI tears a representable down whenever it likes,
    /// which is not the moment the user pressed back. One shared instance means `stopAll()` is
    /// reachable from the screen's own dismissal path, which is the moment that actually
    /// matters.
    static let shared = IntersectionFeedbackController()

    private let haptics = CoreHapticsEngine()
    private let speech = TactileSpeechChannel.shared
    private var activeID: String?

    /// The kerb ding. Built on the first dot a finger actually finds, so the audio session is
    /// configured before its engine starts, and so a screen that never reaches a crossing
    /// never spins up an audio engine at all.
    private var tone: ToneGenerator?
    private var isDinging = false
    /// Drives the tap that goes with each turn ding — the tone generator repeats the sound on
    /// its own, but nothing repeats a haptic tap.
    private var turnTapper: Timer?

    /// A sharp tap every 0.17 s. Transient rather than a short continuous pulse: a tap reads
    /// as a discrete marking, where a pulse blurs into the roadway buzz beside it.
    private static let crossingTick = HapticPattern(
        intensity: 1.0, sharpness: 1.0,
        mode: .burst(pulseCount: 1, onDuration: 0.05, offDuration: 0.12))

    /// What the finger is on, or nil between things. Readable so a test can drive the touch
    /// path and check what it resolved to.
    private(set) var currentSurface: IntersectionSurface?

    private init() {
        // Core Haptics tears its engine down when the app backgrounds and nothing restarts it
        // on the way back, so without this the close-up is silently dead to the touch for the
        // rest of the session after the first time the user switches away.
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopAll()
                self?.haptics.handleAppBackground()
                self?.tone?.handleAppBackground()
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.haptics.handleAppForeground()
                self?.tone?.handleAppForeground()
            }
        }
    }

    /// A finger has arrived on a new surface. Called only on an actual change, so a buzz is
    /// never restarted while the finger stays on one thing.
    ///
    /// `audible` is off while traffic is playing: that exercise is judging a signal by ear, and
    /// a spoken street name or a kerb ding over the top of it is the one thing that makes it
    /// impossible. Haptics stay on either way — they do not compete with listening.
    func enter(id: String, surface: IntersectionSurface, name: String, audible: Bool) {
        guard id != activeID else { return }
        activeID = id
        haptics.stopAll()
        stopSound()

        currentSurface = surface
        switch surface {
        // Still the roadway underfoot — the centre changes what is said, not what is felt.
        case .road, .center: haptics.start(pattern: .heavyBuzzContinuous)
        case .sidewalk: haptics.start(pattern: .streetContinuous)
        case .crossing:
            haptics.start(pattern: Self.crossingTick)
            // Painted markings get a sound of their own as well as a texture — a run of short
            // clicks, which reads as a row of discrete marks rather than as one more vibration
            // to tell apart from the three continuous surfaces around it.
            if audible { startCrossingClicks() }
        case .route: haptics.start(pattern: .routePulse)
        // Faster and sharper than the route line it sits on, so arriving at an end is
        // something the finger notices without waiting to be told.
        case .routeEndpoint: haptics.start(pattern: .landmarkFastPulse)
        // The turn: no continuous texture at all, just a repeating tap and ding, the way a
        // kerb dot is a ding rather than a fourth surface.
        case .routeTurn:
            speech.cancelPending()
            if audible { startTurnDing() }
            speech.speak(name)
            return
        case .crossingEnd:
            // No haptic at all, on purpose. The kerb dot is a landmark rather than a surface,
            // and a ding on its own is unmistakable next to three continuous textures — where
            // a fourth vibration would just be a fourth thing to tell apart.
            speech.cancelPending()
            if audible { playKerbDing() }
            return
        }

        guard audible else {
            speech.cancelPending()
            return
        }
        // Dwell-gated, exactly as the street map is. Haptics change the instant the surface
        // does; the name waits until the finger settles. Without this, crossing a lane, a
        // crossing and a lane again in half a second queued three utterances, and the crossing
        // was still being read out after the finger was back on the lane.
        speech.speak(name)
    }

    /// The finger is between things, or has lifted. Haptics and any sound stop at once;
    /// whatever is mid-sentence is allowed to finish.
    func leave() {
        activeID = nil
        currentSurface = nil
        haptics.stopAll()
        stopSound()
        speech.cancelPending()
    }

    /// Leaving the screen. Everything stops, including a sentence already in flight.
    func stopAll() {
        leave()
        speech.stopAll()
    }

    // MARK: Sound

    /// The one generator all three sounds share. Built on the first one a finger actually
    /// reaches, so the audio session is configured before its engine starts and a screen that
    /// never finds a crossing never spins an audio engine up at all. One is enough: a finger
    /// is on exactly one surface at a time.
    private func soundGenerator() -> ToneGenerator {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        let generator = tone ?? ToneGenerator()
        tone = generator
        isDinging = true
        return generator
    }

    /// 440 Hz for 0.16 s, once per dot — the same tone the street map uses for a junction, so
    /// one sound means "a named place, not a stretch of something" everywhere it plays.
    private func playKerbDing() {
        soundGenerator().playTone(frequency: 440, duration: 0.16, amplitude: 0.88)
    }

    /// The crossing's own click train — the reference app's crosswalk sound, matched: a 12 ms
    /// two-part tick every 0.17 s for as long as the finger stays on the markings.
    private func startCrossingClicks() {
        soundGenerator().playRepeatingClick()
    }

    /// The turn: the junction ding repeating every 0.4 s, each one paired with a tap, so a turn
    /// is both heard and felt without borrowing any of the four surface textures.
    private func startTurnDing() {
        soundGenerator().playRepeatingTone(frequency: 1120, duration: 0.16, interval: 0.4,
                                           count: 0, amplitude: 0.88)
        turnTapper?.invalidate()
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare()
        impact.impactOccurred(intensity: 0.9)
        turnTapper = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { impact.impactOccurred(intensity: 0.9) }
        }
    }

    /// Guarded on having actually made a sound, so the common path — a finger crossing surfaces
    /// that are silent — never builds an audio engine just to switch it off again.
    private func stopSound() {
        turnTapper?.invalidate()
        turnTapper = nil
        guard isDinging else { return }
        isDinging = false
        tone?.stop()
    }
}

// MARK: - Touch surface

final class IntersectionTouchView: UIView {

    let canvas = IntersectionCanvasView()

    /// The follow dot. Same one the street map uses, for the same reason — a sighted observer
    /// watching a session needs to know where the finger was when something was said.
    let touchIndicator = TouchIndicatorView()

    private let feedback = IntersectionFeedbackController.shared

    /// Whether entering a surface makes any sound — its name, or a kerb ding.
    ///
    /// Off while the traffic simulation is running: the exercise is judging a signal by ear,
    /// and a street name or a ding over the top of it is the one thing that makes that
    /// impossible. Haptics stay on either way — they do not compete with listening.
    var isAudible = true

    /// Set by the owner. Rebuilding the scene needs both this and a laid-out frame.
    var source: (junction: Intersection, map: StreetMap)? {
        didSet { rebuild() }
    }

    /// The study route, if one is showing on the screen this close-up was opened from. `nil`
    /// for a junction with no route, or for this screen used from the crossing-audio demo.
    var route: RouteScene? {
        didSet { rebuild() }
    }

    /// Double tap anywhere: go back. Same gesture that opened the screen.
    var onDoubleTap: (() -> Void)?

    private(set) var scene: IntersectionScene?

    // MARK: Logging
    //
    // The close-up recorded nothing at all, so every trace stopped at the moment a junction was
    // opened — which is the moment the interesting part starts. It writes its own session
    // rather than sharing the map's: the two are different coordinate spaces at different
    // scales, and a row that does not say which is which cannot be read back.

    private let logger = CSVTouchLogger(fileNameGenerator: { _ in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "Intersection_\(formatter.string(from: Date()))"
    })
    private var loggingStarted = false
    private var sessionStart = Date()

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
        // Above the canvas, so the dot is never buried under a road or a crossing stripe.
        addSubview(touchIndicator)
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
                                            size: bounds.size, route: route)
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
    ///
    /// The label is the junction's name and nothing else. VoiceOver reads it in its own voice
    /// when focus lands here and no app can cut that short, so the arms and the instructions
    /// live in the spoken introduction instead, where they can be stopped — see
    /// `TactileSpeechChannel.speakArrival`.
    private func applyAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = [.allowsDirectInteraction]
        // "Intersection view" first, then the junction. With VoiceOver on this label is the
        // only thing that announces the change of screen — `entryAnnouncement` deliberately
        // does not run in that case, to avoid saying the junction's name twice in two voices.
        let place = source?.junction.announcement ?? scene?.title
        accessibilityLabel = place.map { "Intersection view. \($0)" } ?? "Intersection diagram"
        accessibilityHint = "Drag one finger to explore."
        if #available(iOS 17.0, *) { accessibilityDirectTouchOptions = .silentOnTouch }
    }

    /// Say where we have landed, once the screen is actually on screen.
    ///
    /// With VoiceOver on, focus is handed to this element so it reads the junction's name — a
    /// detached string posted as an announcement is read into the void, and goes into a queue
    /// nothing can empty. The arms and the instruction follow in the app's own voice, timed to
    /// start after VoiceOver has finished with the name so the two never overlap.
    func announceArrival() {
        guard let source else { return }
        if UIAccessibility.isVoiceOverRunning {
            applyAccessibility()
            UIAccessibility.post(notification: .screenChanged, argument: self)
            // VoiceOver has just said the junction's name, so this picks up from there rather
            // than saying it a second time in a second voice.
            TactileSpeechChannel.shared.speakArrival(
                IntersectionScene.armsAnnouncement(for: source.junction))
        } else {
            TactileSpeechChannel.shared.speakArrival(
                IntersectionScene.entryAnnouncement(for: source.junction))
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        trackingTouch = touch
        touchStartedAt = CACurrentMediaTime()
        touchStartPoint = touch.location(in: self)
        startLoggingIfNeeded()
        // A finger on the glass replaces the introduction rather than playing under it.
        TactileSpeechChannel.shared.endSuppression()
        log(.touchDown, at: touchStartPoint, piece: explore(at: touchStartPoint))
        touchIndicator.show(at: touchStartPoint)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        log(.touchMove, at: point, piece: explore(at: point))
        touchIndicator.show(at: point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let point = trackingTouch?.location(in: self) ?? touchStartPoint
        log(.touchUp, at: point, piece: scene?.piece(at: point))
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
        touchIndicator.hide()
    }

    /// The surface currently under the finger. Exposed so a test can drive `explore(at:)` and
    /// check the result, with VoiceOver off as well as on.
    var currentSurface: IntersectionSurface? { feedback.currentSurface }

    /// Resolve and act on a point, in this view's coordinates.
    ///
    /// Called straight from the raw touch handlers, and directly from tests — there is no
    /// gesture recognizer in between, which is exactly why the behaviour is identical with
    /// VoiceOver on and off.
    @discardableResult
    func explore(at point: CGPoint) -> IntersectionPiece? {
        guard let scene else { return nil }
        guard let piece = scene.piece(at: point) else {
            // Between things. Silence is the right answer: it is how a gap reads as a gap.
            feedback.leave()
            return nil
        }
        feedback.enter(id: piece.id, surface: piece.surface, name: piece.name, audible: isAudible)
        return piece
    }

    func stopFeedback() {
        feedback.stopAll()
        endLogging()
        // The follow dot goes with it. A screen that has stopped responding must not still be
        // showing a finger resting on it — to an observer that reads as a live touch.
        touchIndicator.hide()
    }

    // MARK: Logging

    /// Opens a session the first time a finger arrives, recording everything needed to read a
    /// trace back afterwards: which junction, at what scale, and what was drawn on it.
    private func startLoggingIfNeeded() {
        guard !loggingStarted, let scene else { return }
        loggingStarted = true
        sessionStart = Date()

        func count(_ surface: IntersectionSurface) -> Int {
            scene.pieces.filter { $0.surface == surface }.count
        }
        logger.startSession(metadata: [
            "map": "CongressSquare",
            "screen": "IntersectionCloseUp",
            "junction": scene.junction.id,
            "junctionName": scene.junction.announcement,
            "streets": scene.junction.streetNames.joined(separator: "|"),
            "legs": "\(scene.junction.legs.count)",
            // Everything drawn, so a trace says what was reachable as well as what was reached.
            "roads": "\(count(.road))",
            "sidewalks": "\(count(.sidewalk))",
            "crossings": "\(count(.crossing))",
            "kerbDots": "\(count(.crossingEnd))",
            "centerZones": "\(count(.center))",
            // The two numbers a position has to be read through.
            "pointsPerMeter": String(format: "%.3f", scene.scale),
            "radiusMeters": String(format: "%.1f", IntersectionScene.radiusMeters),
            "viewSize": "\(Int(scene.size.width))x\(Int(scene.size.height))",
            "audible": isAudible ? "yes" : "no",
            "voiceOver": UIAccessibility.isVoiceOverRunning ? "on" : "off",
        ])
    }

    private func endLogging() {
        guard loggingStarted else { return }
        loggingStarted = false
        logger.endSession()
    }

    /// One touch sample, with what it landed on.
    ///
    /// Positions are recorded twice: in view points, so a trace can be replayed against the
    /// drawing, and in metres from the junction centre, so it can be compared across devices —
    /// the point scale differs with pixel density, and this view's scale differs from the
    /// city map's again.
    private func log(_ type: TouchEventType, at point: CGPoint, piece: IntersectionPiece?) {
        guard loggingStarted, let scene else { return }
        let name: String
        let kind: String
        switch piece?.surface {
        case .road: name = piece!.name; kind = "road"
        case .sidewalk: name = piece!.name; kind = "sidewalk"
        case .crossing: name = piece!.name; kind = "crossing"
        case .crossingEnd: name = piece!.name; kind = "kerbDot"
        case .center: name = piece!.name; kind = "center"
        case .route: name = piece!.name; kind = "route"
        case .routeEndpoint: name = piece!.name; kind = "routeEndpoint"
        case .routeTurn: name = piece!.name; kind = "routeTurn"
        case nil: name = "Background"; kind = "background"
        }
        _ = logger.logEvent(TouchEvent(
            timestamp: Date(),
            sessionElapsed: Date().timeIntervalSince(sessionStart),
            eventType: type,
            elementName: name,
            elementType: piece?.surface.elementType,
            touchPoint: point,
            custom: [
                "gesture": "explore",
                "on": kind,
                "pieceID": piece?.id ?? "",
                "junction": scene.junction.id,
                "metersX": String(format: "%.2f", (point.x - scene.center.x) / scene.scale),
                "metersY": String(format: "%.2f", (point.y - scene.center.y) / scene.scale),
            ]))
    }
}

// MARK: - SwiftUI wrapper

/// Lets the screen drive the close-up without owning it — the SwiftUI equivalent of holding
/// a reference to the view, and the same arrangement the street map uses.
final class IntersectionViewCommands {
    var announceArrival: (() -> Void)?
}

struct IntersectionTactileView: UIViewRepresentable {

    let junction: Intersection
    let map: StreetMap
    /// The study route, if this junction sits on one. See `IntersectionTouchView.route`.
    var route: RouteScene?
    /// Silenced while traffic is playing — see `IntersectionTouchView.isAudible`.
    var isAudible: Bool = true
    var commands: IntersectionViewCommands?
    var onDoubleTap: (() -> Void)?

    func makeUIView(context: Context) -> IntersectionTouchView {
        let view = IntersectionTouchView(frame: .zero)
        view.source = (junction, map)
        view.route = route
        view.isAudible = isAudible
        view.onDoubleTap = onDoubleTap
        commands?.announceArrival = { [weak view] in view?.announceArrival() }
        return view
    }

    func updateUIView(_ view: IntersectionTouchView, context: Context) {
        if view.source?.junction.id != junction.id {
            view.source = (junction, map)
        }
        view.route = route
        view.isAudible = isAudible
        view.onDoubleTap = onDoubleTap
        commands?.announceArrival = { [weak view] in view?.announceArrival() }
    }

    static func dismantleUIView(_ view: IntersectionTouchView, coordinator: ()) {
        view.stopFeedback()
    }
}
