//
//  SpatialAudioSimulationView.swift
//  TactileNav
//
//  Street Crossing Audio — a four-way intersection you judge by ear.
//
//  The technique being practised is the one blind travellers are actually taught: you do not
//  cross when it goes quiet, you cross with the **parallel surge** — the moment the traffic
//  beside you, running the way you want to walk, pulls away from the line.
//
//  That only works if you know which way you are facing, so the screen says so in as many
//  words. Where you are standing, which way you are pointed, which street is in front of you
//  and which is beside you are all stated up front and available to VoiceOver as one sentence,
//  because "sound is coming from the left" means nothing until you know what is on your left.
//
//  What is deliberately *not* said is which street currently has the green. That is the thing
//  being worked out. It is available on demand behind a button so a listener can check
//  themselves.
//

import SwiftUI

struct SpatialAudioSimulationView: View {

    private let audio = TrafficAudioEngine.shared
    @State private var model = IntersectionCrossingModel()

    @State private var running = false
    @State private var fleet: IntersectionCrossingModel.Fleet = .gasoline
    @State private var pace: IntersectionCrossingModel.Pace = .normal
    @State private var phaseRevealed = false
    @State private var isWalkPhase = false
    @State private var nearestCents: Double = 0
    @State private var ticker: Timer?
    @State private var lastTick = CACurrentMediaTime()
    /// When the readout was last republished. The audio runs at 60 Hz; the *view* must not.
    @State private var lastReadoutTick = CACurrentMediaTime()
    /// Vehicles as the diagram draws them. Republished a few times a second, not every frame.
    @State private var shownVehicles: [SimulatedVehicle] = []
    @State private var lastDiagramTick = CACurrentMediaTime()

    /// One screen, no scrolling.
    ///
    /// The exercise is listening, and the controls have to be reachable without hunting: a
    /// screen you have to scroll puts Start below the fold exactly when a listener wants it,
    /// and asks a VoiceOver user to swipe past the whole diagram to reach it. So everything
    /// below the diagram is fixed height and the diagram takes whatever is left — it is square,
    /// so it simply gets smaller on a smaller phone rather than pushing anything off.
    var body: some View {
        VStack(spacing: 10) {
            CrossingOrientationDiagram(vehicles: shownVehicles)
                .frame(maxHeight: .infinity)
            whereYouAre
            statusView
            controls
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .navigationTitle("Street Crossing Audio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { audio.activate() }
        .onDisappear { stop() }
    }

    // MARK: - Where you are

    /// Orientation, stated plainly.
    ///
    /// Without this the exercise is unfair rather than hard: a listener hears traffic sweeping
    /// left to right and has no way to know whether that is the street they are about to step
    /// into or the one running along beside them.
    /// Orientation in two lines rather than a labelled table.
    ///
    /// The four-row version said the same things at four times the height, and the height is
    /// what pushed the controls off the screen. Nothing is lost for VoiceOver: it reads the
    /// whole thing as one sentence either way, and always did.
    private var whereYouAre: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("On \(DemoIntersection.listenerCornerDescription), facing "
                 + "\(DemoIntersection.listenerFacingDescription).")
                .font(.subheadline)
            Text("Crossing \(DemoIntersection.alongStreet). "
                 + "\(DemoIntersection.acrossStreet) beside you.")
                .font(.subheadline)
            Text("Cross with the surge beside you, not the quiet.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        // One sentence rather than several fragments — this is a single piece of orientation,
        // and swiping through it line by line is slower than hearing it said.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DemoIntersection.orientationSentence)
    }

    // MARK: - Status and the on-demand answer

    private var statusView: some View {
        HStack(spacing: 8) {
            Image(systemName: running ? "waveform" : "pause.circle")
            if phaseRevealed {
                Text(isWalkPhase
                     ? "\(DemoIntersection.acrossStreet) green — cross"
                     : "\(DemoIntersection.alongStreet) green — wait")
                    .font(.subheadline)
                    .foregroundColor(isWalkPhase ? .green : .red)
            } else {
                Text(running ? "Which street has the green?" : "Stopped")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if running {
                Text(String(format: "%+.0f", nearestCents))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    // Hidden from VoiceOver on purpose. It is a sighted readout of a number
                    // that changes several times a second, and the exercise is to judge the
                    // traffic by ear — a voice reading out pitch shifts is both a distraction
                    // and a partial answer.
                    .accessibilityHidden(true)
            }
            Button(phaseRevealed ? "Hide" : "Reveal") { phaseRevealed.toggle() }
                .font(.subheadline)
                .accessibilityLabel(phaseRevealed ? "Hide answer" : "Reveal phase")
                .accessibilityHint(phaseRevealed
                    ? "Stops showing which street has the green"
                    : "Shows which street has the green, so you can check your judgement")
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The captions that used to sit under each picker are now hints. They explain the
            // choice rather than name it, which is what a hint is for — and they were four
            // lines of the height that pushed Start off the bottom of the screen.
            Picker("Traffic", selection: $fleet) {
                ForEach(IntersectionCrossingModel.Fleet.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Traffic type")
            .accessibilityHint(fleet.detail)
            .onChange(of: fleet) { _, newValue in model.fleet = newValue }

            Picker("Speed", selection: $pace) {
                ForEach(IntersectionCrossingModel.Pace.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Traffic speed")
            .accessibilityHint(pace.detail)
            .onChange(of: pace) { _, newValue in model.pace = newValue }

            Label("Headphones needed.", systemImage: "headphones")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHint("The direction traffic comes from is the whole cue.")

            Button(action: toggle) {
                Label(running ? "Stop" : "Start listening",
                      systemImage: running ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(running ? Color.red : Color.blue, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Run loop

    private func toggle() { running ? stop() : start() }

    private func start() {
        audio.activate()
        model.reset()
        model.fleet = fleet
        model.pace = pace
        running = true
        lastTick = CACurrentMediaTime()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        running = false
        audio.releaseAllVoices()
        model.reset()
        shownVehicles = []
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = min(now - lastTick, 0.1)
        lastTick = now

        for vehicle in model.advance(by: delta) {
            if let voice = vehicle.voice { audio.releaseVoice(voice) }
        }

        var nearestDistance = Double.greatestFiniteMagnitude
        var nearestShift: Double = 0

        model.updateEachVehicle { vehicle in
            if vehicle.voice == nil {
                vehicle.voice = audio.acquireVoice(type: vehicle.type)
            }
            guard let voice = vehicle.voice else { return }

            let position = vehicle.position(legLength: IntersectionCrossingModel.legLengthM)
            let distance = max(0.8, hypot(Double(position.x), Double(position.y)))

            // Doppler from the radial closing speed: difference the distance over one frame.
            let step = 1.0 / 60.0
            var ahead = vehicle
            ahead.age += step
            let aheadPosition = ahead.position(legLength: IntersectionCrossingModel.legLengthM)
            let closing = (distance - max(0.8, hypot(Double(aheadPosition.x), Double(aheadPosition.y)))) / step
            let cents = max(-400, min(400, 1_200 * log2(343.0 / max(1.0, 343.0 - closing))))

            // Pan is where the vehicle sits left to right; volume falls off with distance.
            let pan = Float(max(-1, min(1, Double(position.x) / max(distance, 1))))
            var volume = Float(6.0 / distance)
            volume = min(volume, 1.0) * vehicle.type.loudness

            // Brightness closes down with distance as well as level — see `updateVoice`.
            let brightness = Float(max(0, min(1, 12.0 / distance)))

            audio.updateVoice(voice,
                              pan: pan,
                              volume: max(vehicle.type.isEV ? 0.015 : 0.04, volume),
                              cents: Float(cents),
                              brightness: brightness)

            if distance < nearestDistance {
                nearestDistance = distance
                nearestShift = cents
            }
        }

        // Republish the readout a few times a second rather than every frame. SwiftUI
        // rebuilds this whole screen on each change, and under VoiceOver that means the
        // accessibility tree is torn down and rebuilt 60 times a second — which reads as
        // focus jumping around and speech cutting itself off mid-word.
        if now - lastReadoutTick >= 0.25 {
            lastReadoutTick = now
            nearestCents = nearestShift
        }
        // The diagram moves often enough to read as motion, but nowhere near 60 Hz — every
        // republish rebuilds this screen, and under VoiceOver that is what makes focus jump.
        if now - lastDiagramTick >= 0.1 {
            lastDiagramTick = now
            shownVehicles = model.vehicles
        }
        // Only on an actual change. Writing the same value back still invalidates the view and
        // re-evaluates its body, which at 60 Hz is the same churn the readout above avoids.
        if isWalkPhase != model.currentPhase.isWalkPhase {
            isWalkPhase = model.currentPhase.isWalkPhase
        }
    }
}
