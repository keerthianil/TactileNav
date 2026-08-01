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
    @State private var vehicles: [SimulatedVehicle] = []
    @State private var phaseRevealed = false
    @State private var isWalkPhase = false
    @State private var nearestCents: Double = 0
    @State private var ticker: Timer?
    @State private var lastTick = CACurrentMediaTime()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IntersectionDiagramView(vehicles: vehicles)
                statusView
                controls
                infoView
            }
            .padding()
        }
        .navigationTitle("Street Crossing Audio")
        .navigationBarTitleDisplayMode(.inline)
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
                        .accessibilityLabel("Doppler shift of the nearest vehicle")
                }
            }

            if phaseRevealed {
                Label(isWalkPhase
                      ? "High Street is green. This is the surge you cross with."
                      : "Congress Street is green. Traffic is crossing your path — wait.",
                      systemImage: isWalkPhase ? "figure.walk" : "hand.raised.fill")
                    .font(.subheadline)
                    .foregroundColor(isWalkPhase ? .green : .red)
            } else {
                Text("Listen first. Which street has the green?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(phaseRevealed ? "Hide the answer" : "Reveal the current phase") {
                phaseRevealed.toggle()
            }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Traffic").font(.subheadline).bold()
                Picker("Traffic", selection: $fleet) {
                    ForEach(IntersectionCrossingModel.Fleet.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Electric traffic is near-silent, so the surge is much harder to hear")

                Text(fleet.detail).font(.caption).foregroundColor(.secondary)
            }
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

    // MARK: - Info

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(DemoIntersection.name, systemImage: "mappin.and.ellipse")
                .font(.subheadline).bold()
            Text("You are crossing Congress Street. High Street runs parallel to your path, so "
                 + "when High Street traffic pulls away together, your walk signal is on. "
                 + "Traffic sweeping left to right across your front is Congress Street, and "
                 + "means wait.")
                .font(.caption).foregroundColor(.secondary)
            Text("During the walk phase, listen for a vehicle that stays close instead of "
                 + "passing — that is a car turning across the crosswalk, the movement most "
                 + "likely to hit a pedestrian who has already stepped off.")
                .font(.caption).foregroundColor(.secondary)
            Label("Headphones needed for the left and right cues", systemImage: "headphones")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Run loop

    private func toggle() { running ? stop() : start() }

    private func start() {
        audio.activate()
        model.reset()
        model.fleet = fleet
        vehicles = []
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
        vehicles = []
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

        vehicles = model.vehicles
        nearestCents = nearestShift
        isWalkPhase = model.currentPhase.isWalkPhase
    }
}

// MARK: - Bird's-eye diagram

/// The intersection seen from above, with the listener on the corner and live traffic.
///
/// Split out from the screen so it can be rendered and checked on its own — and because the
/// screen's job is the run loop, not geometry.
struct IntersectionDiagramView: View {

    let vehicles: [SimulatedVehicle]

    // MARK: - Intersection (bird's-eye)

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Metres to points for the diagram only; the audio works in real metres.
            let scale = side / CGFloat(IntersectionCrossingModel.legLengthM * 2.1)

            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6))

                roadBand(bearing: DemoIntersection.congressBearings.outbound,
                         center: center, scale: scale, length: side * 1.6)
                roadBand(bearing: DemoIntersection.highBearings.outbound,
                         center: center, scale: scale, length: side * 1.6)

                crosswalk(center: center, scale: scale)

                Image(systemName: "figure.stand")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.blue)
                    .position(listenerPoint(center: center, scale: scale))

                ForEach(vehicles) { vehicle in
                    Image(systemName: vehicle.type.symbol)
                        .font(.system(size: 14))
                        .foregroundColor(vehicle.type.isEV ? .green : .orange)
                        .position(diagramPoint(for: vehicle, center: center, scale: scale))
                }
            }
        }
        .frame(height: 260)
        .accessibilityElement()
        // Static on purpose. If this label reported the live phase, VoiceOver would hand over
        // the very thing the listener is meant to work out.
        .accessibilityLabel(
            "Bird's eye view of \(DemoIntersection.name). You are standing on the corner about "
            + "to cross Congress Street, facing along High Street. Traffic runs on all four legs.")
    }

    private func roadBand(bearing: Double, center: CGPoint, scale: CGFloat, length: CGFloat) -> some View {
        Rectangle()
            .fill(Color(.systemGray3))
            .frame(width: CGFloat(DemoIntersection.roadHalfWidthM * 2) * scale, height: length)
            .rotationEffect(.degrees(bearing))
            .position(center)
    }

    /// The crossing the listener is standing at, across Congress Street. Bars run parallel
    /// to Congress traffic and step along the walking direction, as painted zebras do.
    private func crosswalk(center: CGPoint, scale: CGFloat) -> some View {
        let mid = worldPoint(DemoIntersection.crosswalkCenterM, center: center, scale: scale)
        let along = DemoIntersection.direction(DemoIntersection.highBearings.outbound)
        let spacing: CGFloat = 7
        return ForEach(0..<4, id: \.self) { index in
            let step = CGFloat(index) - 1.5
            Rectangle()
                .fill(.white)
                .frame(width: CGFloat(DemoIntersection.roadHalfWidthM * 1.6) * scale, height: 3)
                .rotationEffect(.degrees(DemoIntersection.congressBearings.outbound - 90))
                .position(x: mid.x + step * spacing * CGFloat(along.x),
                          y: mid.y - step * spacing * CGFloat(along.y))
        }
    }

    private func listenerPoint(center: CGPoint, scale: CGFloat) -> CGPoint {
        worldPoint(DemoIntersection.listenerPositionM, center: center, scale: scale)
    }

    /// World metres (+x east, +y north) to a point in the north-up diagram.
    private func worldPoint(_ world: CGPoint, center: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: center.x + world.x * scale, y: center.y - world.y * scale)
    }

    /// Undo the listener-relative frame so the diagram stays north-up.
    private func diagramPoint(for vehicle: SimulatedVehicle, center: CGPoint, scale: CGFloat) -> CGPoint {
        let relative = vehicle.position(legLength: IntersectionCrossingModel.legLengthM)
        let facing = DemoIntersection.listenerFacing * .pi / 180
        let stand = DemoIntersection.listenerPositionM
        let dx = Double(relative.x) * cos(facing) + Double(relative.y) * sin(facing)
        let dy = -Double(relative.x) * sin(facing) + Double(relative.y) * cos(facing)
        return worldPoint(CGPoint(x: Double(stand.x) + dx, y: Double(stand.y) + dy),
                          center: center, scale: scale)
    }
}
