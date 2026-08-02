//
//  SpatialAudioSimulationView.swift
//  TactileNav
//
//  Street Crossing Audio — a four-way intersection you judge by ear.
//
//  You are standing on the corner of Congress Street at High Street, about to cross Congress.
//  Traffic runs on all four legs under a signal cycle. The task is the one blind travellers
//  actually perform: work out from sound alone when the parallel street gets its green,
//  because that surge is the cue to step off.
//
//  Nothing is narrated. There is deliberately no spoken commentary on what the traffic is
//  doing — being told the answer is the opposite of the exercise. The current phase is
//  available on demand behind a button so a listener can check themselves, and every control
//  is labelled for VoiceOver as usual.
//

import SwiftUI

struct SpatialAudioSimulationView: View {

    private let audio = TrafficAudioEngine.shared
    @State private var model = IntersectionCrossingModel()

    @State private var running = false
    @State private var fleet: IntersectionCrossingModel.Fleet = .gasoline
    @State private var phaseRevealed = false
    @State private var isWalkPhase = false
    @State private var nearestCents: Double = 0
    @State private var ticker: Timer?
    @State private var lastTick = CACurrentMediaTime()
    /// When the readout was last republished. The audio runs at 60 Hz; the *view* must not.
    @State private var lastReadoutTick = CACurrentMediaTime()

    var body: some View {
        VStack(spacing: 14) {
            // The intersection is the demo, so it gets the room. It is a tactile diagram
            // rather than an illustration: the same junction the traffic is running through,
            // laid out so a finger can find the roadway, the sidewalks, the crossings and the
            // kerb ramps. Silent while traffic plays — see `speaks`.
            IntersectionTactileView(alongName: DemoIntersection.alongStreet,
                                    acrossName: DemoIntersection.acrossStreet,
                                    speaks: !running)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.separator)))
            statusView
            controls
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .navigationTitle("Street Crossing Audio")
        .navigationBarTitleDisplayMode(.inline)
        // The diagram above is explored with one finger, which is the same gesture that would
        // otherwise pop this screen out from under it.
        .disablesSwipeBack()
        .onAppear { audio.activate() }
        .onDisappear { stop() }
    }

    // MARK: - Status and the on-demand answer

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: running ? "waveform" : "pause.circle")
                Text(running ? "Listening" : "Stopped").font(.headline)
                Spacer()
                if running {
                    Text(String(format: "%+.0f cents", nearestCents))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        // Hidden from VoiceOver on purpose. It is a sighted readout of a
                        // number that changes several times a second, and the exercise is to
                        // judge the traffic by ear — a voice reading out pitch shifts is both
                        // a distraction and a partial answer.
                        .accessibilityHidden(true)
                }
            }

            if phaseRevealed {
                Label(isWalkPhase ? "High Street green — cross now" : "Congress Street green — wait",
                      systemImage: isWalkPhase ? "figure.walk" : "hand.raised.fill")
                    .font(.subheadline)
                    .foregroundColor(isWalkPhase ? .green : .red)
            } else {
                Text("Which street has the green?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(phaseRevealed ? "Hide answer" : "Reveal phase") { phaseRevealed.toggle() }
                .font(.subheadline)
                .accessibilityHint(phaseRevealed
                    ? "Stops showing which street has the green"
                    : "Shows which street has the green, so you can check your judgement")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Traffic", selection: $fleet) {
                ForEach(IntersectionCrossingModel.Fleet.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Traffic type")
            .accessibilityHint("Electric traffic is near-silent, so the surge is much harder to hear")
            .onChange(of: fleet) { _, newValue in model.fleet = newValue }

            Button(action: toggle) {
                Label(running ? "Stop" : "Start listening",
                      systemImage: running ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
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
            audio.updateVoice(voice,
                              pan: pan,
                              volume: max(vehicle.type.isEV ? 0.015 : 0.04, volume),
                              cents: Float(cents))

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
        // Only on an actual change. Writing the same value back still invalidates the view and
        // re-evaluates its body, which at 60 Hz is the same churn the readout above avoids.
        if isWalkPhase != model.currentPhase.isWalkPhase {
            isWalkPhase = model.currentPhase.isWalkPhase
        }
    }
}
