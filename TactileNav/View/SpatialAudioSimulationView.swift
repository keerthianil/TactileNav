//
//  SpatialAudioSimulationView.swift
//  TactileNav
//
//  A single-lane sandbox for the spatial-audio / Doppler engine, plus the two crossing
//  scenarios the research calls out as the hardest perceptual tasks for a blind
//  pedestrian:
//    • straight-through vs. turning vehicle  (Ashmead 2012 — judging a turn needs ~11 dB
//      more than judging presence), and
//    • loud internal-combustion vehicle vs. near-silent EV  (the EV detection-gap hazard).
//  Both are exposed as toggles over the same lane, driven by the real-Doppler
//  `TrafficAudioEngine`. Headphones recommended for the left/right and distance cues.
//

import SwiftUI

struct SpatialAudioSimulationView: View {

    private let audio = TrafficAudioEngine.shared
    private let feedback = PortlandFeedbackManager.shared

    @State private var vehicle: TrafficAudioEngine.VehicleType = .car
    @State private var turning = false
    @State private var speedMph = 25.0
    @State private var running = false
    @State private var progress: Double = 0
    @State private var closing = true
    @State private var pitchCents = 0.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                laneView
                statusView
                controls
                infoView
            }
            .padding()
        }
        .navigationTitle("Street Crossing Audio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            audio.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                feedback.speak("Street crossing audio sandbox. Put on headphones. Choose a vehicle and whether it goes straight or turns across your path, then start the pass.")
            }
        }
        .onDisappear { audio.stopVehiclePass(); running = false }
    }

    // MARK: - Lane visual (bird's-eye)

    private var laneView: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // sidewalks
                RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray5))
                // road band
                Rectangle().fill(Color(.systemGray2))
                    .frame(height: h * 0.42).position(x: w/2, y: h * 0.40)
                // lane dashes
                ForEach(0..<7) { i in
                    Rectangle().fill(.white)
                        .frame(width: 18, height: 3)
                        .position(x: CGFloat(i) * (w/6), y: h * 0.40)
                }
                // crosswalk near centre
                ForEach(0..<5) { i in
                    Rectangle().fill(.white)
                        .frame(width: 6, height: h * 0.42)
                        .position(x: w/2 - 20 + CGFloat(i) * 10, y: h * 0.40)
                }
                // pedestrian ("You") at the near curb
                VStack(spacing: 2) {
                    Image(systemName: "figure.stand").font(.title2)
                    Text("You").font(.caption2).bold()
                }
                .foregroundColor(.blue)
                .position(x: w/2, y: h * 0.82)

                // vehicle
                Image(systemName: vehicle.symbol)
                    .font(.title)
                    .foregroundColor(vehicle.isEV ? .green : .orange)
                    .scaleEffect(x: closing ? 1 : -1)   // face travel direction
                    .position(x: vehicleX(w), y: vehicleY(h))
                    .opacity(running ? 1 : 0.35)
            }
        }
        .frame(height: 200)
        .accessibilityElement()
        .accessibilityLabel("Lane view. \(vehicle.label) travelling \(turning ? "and turning across your crosswalk" : "straight through"). You are standing at the near curb.")
    }

    private func vehicleX(_ w: CGFloat) -> CGFloat { CGFloat(progress) * w }
    private func vehicleY(_ h: CGFloat) -> CGFloat {
        let lane = h * 0.40
        guard turning, progress > 0.5 else { return lane }
        let p = (progress - 0.5) / 0.5
        return lane + CGFloat(p) * (h * 0.40)   // curve toward the crosswalk / you
    }

    // MARK: - Status

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: closing ? "arrow.right.to.line" : "arrow.right")
                Text(running ? (closing ? "Approaching — pitch rising" : "Receding — pitch falling") : "Ready")
                    .font(.headline)
            }
            Text(running
                 ? String(format: "Doppler shift: %+.0f cents (%.1f semitones)", pitchCents, pitchCents/100)
                 : "Doppler shift updates live as the vehicle moves")
                .font(.caption).foregroundColor(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vehicle").font(.subheadline).bold()
                Picker("Vehicle", selection: $vehicle) {
                    ForEach(TrafficAudioEngine.VehicleType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Electric vehicle is near-silent, demonstrating the detection hazard")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Path").font(.subheadline).bold()
                Picker("Path", selection: $turning) {
                    Text("Straight through").tag(false)
                    Text("Turning across").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityHint("A turning vehicle crosses your path — the harder, riskier case to judge by ear")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Speed: \(Int(speedMph)) mph").font(.subheadline).bold()
                Slider(value: $speedMph, in: 15...45, step: 5)
                    .accessibilityValue("\(Int(speedMph)) miles per hour")
            }

            Button(action: startPass) {
                Label(running ? "Passing…" : "Start pass", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(running ? Color.gray : Color.blue, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(.white)
            }
            .disabled(running)
        }
    }

    // MARK: - Info

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(vehicle.label): \(vehicle.dBADescriptor)", systemImage: "speaker.wave.2.fill")
                .font(.subheadline)
            Text(vehicle.isEV
                 ? "Electric vehicles under 20 mph are near-silent (under 45 dBA), well below the ~65 dBA needed to judge a vehicle's path in traffic. Notice how little warning you get."
                 : "Notice the pitch rise as it approaches and drop as it passes — the Doppler effect — and how a turning vehicle stays closer for longer.")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Drive the pass

    private func startPass() {
        guard !running else { return }
        running = true
        progress = 0
        closing = true
        var cfg = TrafficAudioEngine.PassConfig()
        cfg.type = vehicle
        cfg.turning = turning
        cfg.speedMph = speedMph
        cfg.curbDistanceM = 4
        cfg.spanM = 60

        feedback.speak(turning
            ? "\(vehicle.label) approaching from the left, will turn across your crosswalk."
            : "\(vehicle.label) approaching from the left, going straight through.")

        var announcedPass = false
        audio.startVehiclePass(cfg, onProgress: { p, isClosing, cents in
            progress = p
            pitchCents = cents
            closing = isClosing
            if !isClosing && !announcedPass {
                announcedPass = true
                feedback.speak(turning ? "Turning through the crosswalk now." : "Passing you now.")
            }
        }, onComplete: {
            running = false
            progress = 0
            feedback.speak("Vehicle gone.")
        })
    }
}
