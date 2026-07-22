//
//  PortlandIntersectionDetailView.swift
//  TactileNav
//
//  Level-2 crossing simulation for a single intersection. Shows the zoomed, direction-
//  faithful crossing (road legs, sidewalks, marked crosswalks) and runs a live signal
//  cycle that a blind user perceives entirely through sound + haptics:
//
//    • DON'T WALK  — slow APS locator tone (helps locate the pushbutton)
//    • WALK        — rapid percussive tick or spoken "Walk sign is on…", plus a
//                    vibrotactile-arrow haptic pulse
//    • countdown   — accelerating beeps as the pedestrian clearance time runs out
//
//  A car (the running example) passes through on a cadence set by the time-of-day traffic
//  level, spatialised with real Doppler by `TrafficAudioEngine`. During WALK a car may
//  turn across the crosswalk — the highest-risk moment for a blind pedestrian.
//

import SwiftUI
import Combine

// MARK: - Signal cycle controller

@MainActor
final class SignalController: ObservableObject {

    enum Phase { case dontWalk, walk, countdown }

    @Published var phase: Phase = .dontWalk
    @Published var countdown: Int = 0
    @Published var vehicleStatus: String = ""

    let aps: PortlandAPS?
    let signalized: Bool
    let trafficLevel: TrafficLevel
    let speedMph: Double

    private let audio = TrafficAudioEngine.shared
    private let feedback = PortlandFeedbackManager.shared
    private var phaseTimer: Timer?
    private var locatorTimer: Timer?
    private var countdownTimer: Timer?
    private var vehicleTimer: Timer?
    private var running = false

    init(aps: PortlandAPS?, signalized: Bool, trafficLevel: TrafficLevel, speedMph: Double) {
        self.aps = aps
        self.signalized = signalized
        self.trafficLevel = trafficLevel
        self.speedMph = speedMph
    }

    func start() {
        guard !running else { return }
        running = true
        audio.activate()
        if signalized { enterDontWalk() } else { vehicleStatus = "Unsignalized — cross with caution" }
        scheduleVehicles()
    }

    func stop() {
        running = false
        phaseTimer?.invalidate(); locatorTimer?.invalidate()
        countdownTimer?.invalidate(); vehicleTimer?.invalidate()
        audio.stopVehiclePass()
        feedback.stopAllFeedback()
    }

    // MARK: Phases

    private func enterDontWalk() {
        guard running else { return }
        phase = .dontWalk
        // Locator tone: a slow ticking beacon so a blind pedestrian can find the pushbutton.
        locatorTimer?.invalidate()
        let hz = Double(aps?.device.locatorToneHz ?? 880)
        locatorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.audio.playBeep(hz: hz, seconds: 0.06, amplitude: 0.25) }
        }
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.enterWalk() }
        }
    }

    private func enterWalk() {
        guard running else { return }
        phase = .walk
        locatorTimer?.invalidate()
        feedback.playSignalTransition(toWalk: true)   // light-state-change cue (distinct)
        // Vibrotactile arrow (raised arrow that pulses during WALK).
        if aps?.device.vibrotactileArrow == true {
            feedback.startFeedback(for: WalkPulseFeature(), trafficLevel: nil)
        }
        // WALK indication: spoken message (speech APS) or rapid percussive tick.
        if aps?.device.walkIndication == "speech", let msg = aps?.device.walkMessage {
            feedback.speak(msg)
        } else {
            feedback.speak("Walk sign is on")
        }
        locatorTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.audio.playBeep(hz: 1046, seconds: 0.05, amplitude: 0.3) }
        }
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.enterCountdown() }
        }
    }

    private func enterCountdown() {
        guard running else { return }
        phase = .countdown
        locatorTimer?.invalidate()
        feedback.stopAllFeedback()
        feedback.playSignalTransition(toWalk: false)   // clearance-starting cue (distinct)
        countdown = min(aps?.device.countdownSeconds ?? 15, 12)
        feedback.speak("Don't walk. \(countdown) seconds to finish crossing.")
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.audio.playBeep(hz: 1318, seconds: 0.06, amplitude: 0.3)
                self.countdown -= 1
                if self.countdown <= 0 {
                    self.countdownTimer?.invalidate()
                    self.enterDontWalk()
                }
            }
        }
    }

    // MARK: Vehicles

    private var vehicleInterval: TimeInterval {
        switch trafficLevel {
        case .veryHeavy: return 2.5
        case .heavy:     return 3.5
        case .moderate:  return 5.5
        case .light:     return 8.0
        case .veryLight: return 12.0
        }
    }

    private func scheduleVehicles() {
        vehicleTimer?.invalidate()
        vehicleTimer = Timer.scheduledTimer(withTimeInterval: vehicleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runVehicle() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor in self?.runVehicle() }
        }
    }

    private func runVehicle() {
        guard running else { return }
        // During WALK, a fraction of vehicles turn across the crosswalk — the danger case.
        let turning = (phase == .walk) && Bool.random() && Bool.random()
        var cfg = TrafficAudioEngine.PassConfig()
        cfg.type = .car
        cfg.speedMph = speedMph
        cfg.turning = turning
        cfg.curbDistanceM = 4
        audio.startVehiclePass(cfg, onProgress: { [weak self] _, closing, _ in
            Task { @MainActor in
                self?.vehicleStatus = turning
                    ? (closing ? "Car turning across your crosswalk — approaching" : "Car turning — passing")
                    : (closing ? "Car approaching from the left" : "Car passing to the right")
            }
        }, onComplete: { [weak self] in
            Task { @MainActor in self?.vehicleStatus = "" }
        })
    }
}

/// A tiny feature used only to drive the WALK vibrotactile-arrow pulse through the
/// existing feedback path (landmark fast-pulse pattern).
private final class WalkPulseFeature: PortlandMapFeature {
    let featureId = "walk-pulse"
    let featureType: PortlandFeatureType = .landmark
    let featureName = "Walk"
    let level = 2
    func announcement() -> String { "Walk" }
}

// MARK: - Detail view

struct PortlandIntersectionDetailView: View {

    let intersection: PortlandIntersection
    let allCorridors: [PortlandCorridor]
    let trafficSegments: [PortlandTrafficSegment]
    let apsLocations: [PortlandAPS]
    let trafficState: TrafficState

    @Environment(\.dismiss) private var dismiss
    @StateObject private var signal: SignalController
    @State private var detailFeatures: [PortlandMapFeature] = []

    private let aps: PortlandAPS?

    init(intersection: PortlandIntersection,
         allCorridors: [PortlandCorridor],
         trafficSegments: [PortlandTrafficSegment],
         apsLocations: [PortlandAPS],
         trafficState: TrafficState) {
        self.intersection = intersection
        self.allCorridors = allCorridors
        self.trafficSegments = trafficSegments
        self.apsLocations = apsLocations
        self.trafficState = trafficState

        let foundAPS = apsLocations.first { $0.intersectionId == intersection.featureId }
        self.aps = foundAPS

        // Traffic level on the busiest street at this intersection (prefer Congress St).
        let seg = trafficSegments.first { intersection.streets.contains($0.name) && $0.name == "Congress Street" }
            ?? trafficSegments.first { intersection.streets.contains($0.name) }
        let level = seg?.level(for: trafficState) ?? .moderate
        let speed = Double(seg?.speedLimitMph ?? 25)
        _signal = StateObject(wrappedValue: SignalController(
            aps: foundAPS, signalized: intersection.signalized, trafficLevel: level, speedMph: speed))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PortlandMapView(
                    features: detailFeatures,
                    onDoubleTapIntersection: nil,
                    onBackGesture: { dismiss() },
                    trafficSegments: trafficSegments,
                    trafficIntersections: [],
                    apsLocations: apsLocations,
                    trafficState: trafficState,
                    level: 2
                )
                .ignoresSafeArea(edges: .top)

                Button(action: { dismiss() }) {
                    Label("Back", systemImage: "chevron.left")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.top, 8).padding(.leading, 12)
                .accessibilityHint("Returns to the Congress Square map")
            }

            statusPanel
        }
        .onAppear {
            detailFeatures = PortlandMapLoader.generateIntersectionDetail(
                for: intersection, allCorridors: allCorridors, segments: trafficSegments)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                PortlandFeedbackManager.shared.speak(onAppearSummary)
                signal.start()
            }
        }
        .onDisappear { signal.stop() }
    }

    // MARK: Status panel

    private var statusPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(intersection.featureName).font(.title3).bold()

                signalCard
                if let aps { apsCard(aps) }
                trafficCard
                if !signal.vehicleStatus.isEmpty {
                    Label(signal.vehicleStatus, systemImage: "car.fill")
                        .font(.subheadline).foregroundColor(.orange)
                        .accessibilityLabel(signal.vehicleStatus)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        .background(Color(.systemBackground))
    }

    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(signalColor).frame(width: 14, height: 14)
                Text(signalText).font(.headline)
                if signal.phase == .countdown {
                    Text("\(signal.countdown)s").font(.headline).monospacedDigit()
                }
            }
            Text(signal.signalized
                 ? "Traffic signal with pedestrian phase. Listen for the crossing cues."
                 : "Unsignalized crossing — no pedestrian phase.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signal status: \(signalText)\(signal.phase == .countdown ? ", \(signal.countdown) seconds" : "")")
    }

    private func apsCard(_ aps: PortlandAPS) -> some View {
        let d = aps.device
        let walk: String = d.walkIndication == "speech" ? "spoken message" : "rapid ticking"
        let arrow: String = d.vibrotactileArrow ? "Vibrotactile arrow present. " : ""
        let corners: String = d.pushbuttonCorners.joined(separator: " and ")
        let plural: String = d.pushbuttonCorners.count > 1 ? "s." : "."
        let text: String = "Locator tone at \(d.locatorToneHz) Hz. WALK indication: \(walk). "
            + "\(arrow)Pushbutton on \(corners) corner\(plural) "
            + "Pedestrian clearance \(d.countdownSeconds) seconds."
        return VStack(alignment: .leading, spacing: 4) {
            Label("Accessible Pedestrian Signal", systemImage: "figure.walk").font(.subheadline).bold()
            Text(text).font(.caption).foregroundColor(.secondary)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var trafficCard: some View {
        let seg = trafficSegments.first { intersection.streets.contains($0.name) && $0.name == "Congress Street" }
            ?? trafficSegments.first { intersection.streets.contains($0.name) }
        let level = seg?.level(for: trafficState) ?? .moderate
        let name: String = seg?.name ?? "Main street"
        let lanes: Int = seg?.lanes ?? 2
        let meters: Int = Int((seg?.crossingDistanceM ?? 9).rounded())
        let advice: String = (level == .heavy || level == .veryHeavy)
            ? "Continuous flow — wait for the walk signal."
            : "Gaps in traffic are detectable."
        let body: String = "\(name): \(level.spoken) traffic, \(lanes) lanes, about \(meters) meters to cross. \(advice)"
        return VStack(alignment: .leading, spacing: 4) {
            Label("Traffic — \(trafficState.label.lowercased()) hours", systemImage: "waveform.path")
                .font(.subheadline).bold()
            Text(body).font(.caption).foregroundColor(.secondary)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var signalColor: Color {
        switch signal.phase {
        case .walk: return .green
        case .countdown: return .orange
        case .dontWalk: return .red
        }
    }
    private var signalText: String {
        guard signal.signalized else { return "No signal" }
        switch signal.phase {
        case .walk: return "WALK"
        case .countdown: return "Don't walk (clearance)"
        case .dontWalk: return "Don't walk"
        }
    }

    private var onAppearSummary: String {
        var s = "\(intersection.featureName). "
        s += intersection.signalized ? "Signalized crossing. " : "Unsignalized crossing. "
        if aps != nil { s += "Accessible pedestrian signal present. " }
        s += "Drag to explore the road legs, sidewalks, and crosswalks. "
        s += "Three finger swipe right, or two finger scrub, to go back."
        return s
    }
}
