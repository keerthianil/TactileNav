import SwiftUI
import Combine
import AVFoundation

// MARK: - Vehicle Type

enum VehicleType: String, CaseIterable {
    case car, bus, truck, ev

    var label: String {
        switch self {
        case .car:   return "Car"
        case .bus:   return "Bus"
        case .truck: return "Truck"
        case .ev:    return "EV"
        }
    }

    var description: String {
        switch self {
        case .car:   return "Standard passenger car"
        case .bus:   return "City transit bus"
        case .truck: return "Large freight truck"
        case .ev:    return "Electric vehicle, quiet at low speeds"
        }
    }

    var soundInfo: String {
        switch self {
        case .car:   return "~70 dBA, 200-1200 Hz"
        case .bus:   return "~80 dBA, 100-350 Hz"
        case .truck: return "~85 dBA, 80-500 Hz"
        case .ev:    return "~50 dBA, 2000-4000 Hz"
        }
    }

    var frequencies: [(Double, Float)] {
        switch self {
        case .car:   return [(200, 0.5), (800, 0.5), (1200, 0.5)]
        case .bus:   return [(100, 0.7), (200, 0.7), (350, 0.7)]
        case .truck: return [(80, 0.8), (160, 0.8), (500, 0.8)]
        case .ev:    return [(2000, 0.15), (4000, 0.15)]
        }
    }

    var color: Color {
        switch self {
        case .car:   return .blue
        case .bus:   return .orange
        case .truck: return .red
        case .ev:    return .green
        }
    }

    var icon: String {
        switch self {
        case .car:   return "car.fill"
        case .bus:   return "bus.fill"
        case .truck: return "truck.box.fill"
        case .ev:    return "bolt.car.fill"
        }
    }
}

// MARK: - Vehicle Audio Simulator

@MainActor
final class VehicleAudioSimulator: ObservableObject {

    private let audioEngine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let vehicleNode = AVAudioPlayerNode()

    @Published var isPlaying = false
    @Published var vehicleProgress: CGFloat = 0

    private var positionTimer: Timer?
    private var startTime: Date = .distantPast
    private var duration: Double = 2.0
    private var audioBuffer: AVAudioPCMBuffer?

    private let startX: Float = -20
    private let endX: Float = 20
    private let forwardZ: Float = 2

    init() {
        configureEngine()
    }

    deinit {
        positionTimer?.invalidate()
        positionTimer = nil
        audioEngine.stop()
    }

    private func configureEngine() {
        audioEngine.attach(environment)
        audioEngine.attach(vehicleNode)

        vehicleNode.renderingAlgorithm = .HRTFHQ
        vehicleNode.sourceMode = .spatializeIfMono

        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 5.0
        environment.distanceAttenuationParameters.maximumDistance = 50.0
        environment.distanceAttenuationParameters.rolloffFactor = 1.0

        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
        guard let monoFormat else { return }
        audioEngine.connect(vehicleNode, to: environment, format: monoFormat)
        audioEngine.connect(environment, to: audioEngine.mainMixerNode, format: nil)

        vehicleNode.position = AVAudio3DPoint(x: startX, y: 0, z: forwardZ)
    }

    private func generateToneBuffer(frequencies: [(Double, Float)]) -> AVAudioPCMBuffer? {
        let sampleRate: Double = 44100
        let lengthSeconds: Double = 3.0
        let frameCount = AVAudioFrameCount(sampleRate * lengthSeconds)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData?[0] else { return nil }

        let amFreq = 6.0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var sample: Float = 0

            for (freq, amp) in frequencies {
                let sine = sin(2.0 * .pi * freq * t)
                sample += amp * Float(sine)
            }

            let am = Float(1.0 + 0.15 * sin(2.0 * .pi * amFreq * t))
            sample *= am

            let componentCount = Float(frequencies.count)
            sample /= componentCount

            channelData[frame] = sample
        }

        return buffer
    }

    func play(vehicle: VehicleType, speedMPH: Double) {
        if isPlaying { stop() }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }

        guard let buffer = generateToneBuffer(frequencies: vehicle.frequencies) else { return }
        audioBuffer = buffer

        vehicleNode.position = AVAudio3DPoint(x: startX, y: 0, z: forwardZ)
        vehicleProgress = 0

        let distanceMeters: Double = Double(endX - startX)
        let speedMS = speedMPH * 0.447
        duration = distanceMeters / speedMS

        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            return
        }

        vehicleNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        vehicleNode.play()

        isPlaying = true
        startTime = Date()

        UIAccessibility.post(notification: .announcement, argument: "Vehicle simulation started")

        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updatePosition()
            }
        }
    }

    func stop() {
        positionTimer?.invalidate()
        positionTimer = nil
        vehicleNode.stop()
        isPlaying = false
        vehicleProgress = 0
        UIAccessibility.post(notification: .announcement, argument: "Vehicle simulation stopped")
    }

    private func updatePosition() {
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = elapsed / duration

        if progress >= 1.0 {
            positionTimer?.invalidate()
            positionTimer = nil
            vehicleNode.stop()
            isPlaying = false
            vehicleProgress = 1.0
            UIAccessibility.post(notification: .announcement, argument: "Vehicle has passed")
            return
        }

        let currentX = startX + Float(progress) * (endX - startX)
        vehicleNode.position = AVAudio3DPoint(x: currentX, y: 0, z: forwardZ)
        vehicleProgress = CGFloat(progress)
    }

    func tearDown() {
        stop()
        audioEngine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch { }
    }
}

// MARK: - Spatial Audio Simulation View

struct SpatialAudioSimulationView: View {

    @State private var selectedVehicle: VehicleType = .car
    @State private var speed: Double = 30
    @State private var isPlaying = false
    @StateObject private var audioSimulator = VehicleAudioSimulator()

    private var dopplerShift: (approaching: Double, receding: Double) {
        let speedMS = speed * 0.447
        let soundSpeed = 343.0
        let approaching = (speedMS / (soundSpeed - speedMS)) * 100
        let receding = (speedMS / (soundSpeed + speedMS)) * 100
        return (approaching, receding)
    }

    var body: some View {
        VStack(spacing: 0) {
            laneView
                .frame(maxHeight: .infinity)

            controlPanel
        }
        .navigationTitle("Street Crossing")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            audioSimulator.tearDown()
        }
        .onChange(of: audioSimulator.isPlaying) { _, newValue in
            isPlaying = newValue
        }
    }

    // MARK: - Lane View (Bird's Eye)

    private var laneView: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let sidewalkH: CGFloat = 40
            let roadH = height - sidewalkH * 2
            let laneH = roadH / 2

            ZStack(alignment: .topLeading) {
                // Top sidewalk
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: width, height: sidewalkH)

                // Road surface
                Rectangle()
                    .fill(Color.gray.opacity(0.45))
                    .frame(width: width, height: roadH)
                    .offset(y: sidewalkH)

                // Lane divider (dashed yellow center line)
                Path { path in
                    let y = sidewalkH + laneH
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))

                // Lane direction arrows
                ForEach(0..<3, id: \.self) { i in
                    let x = width * CGFloat(i + 1) / 4
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .position(x: x, y: sidewalkH + laneH / 2)
                }
                ForEach(0..<3, id: \.self) { i in
                    let x = width * CGFloat(i + 1) / 4
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .position(x: x, y: sidewalkH + laneH + laneH / 2)
                }

                // Vehicle (moves across lane 2)
                if isPlaying {
                    let vehicleX = width * audioSimulator.vehicleProgress
                    Image(systemName: selectedVehicle.icon)
                        .font(.system(size: 28))
                        .foregroundColor(selectedVehicle.color)
                        .position(x: vehicleX, y: sidewalkH + laneH + laneH / 2)
                        .animation(.linear(duration: 0.02), value: audioSimulator.vehicleProgress)
                }

                // Bottom sidewalk
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: width, height: sidewalkH)
                    .offset(y: sidewalkH + roadH)

                // Pedestrian on bottom sidewalk
                VStack(spacing: 2) {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                    Text("You")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .position(x: width / 2, y: sidewalkH + roadH + sidewalkH / 2)

                // Crosswalk stripes at center
                ForEach(0..<6, id: \.self) { i in
                    let y = sidewalkH + CGFloat(i) * (roadH / 6) + roadH / 12
                    Rectangle()
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 30, height: 4)
                        .position(x: width / 2, y: y)
                }

                // Traffic light at top
                VStack(spacing: 2) {
                    Circle()
                        .fill(isPlaying ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Rectangle()
                        .fill(Color.gray)
                        .frame(width: 3, height: 12)
                }
                .position(x: width / 2 + 25, y: sidewalkH / 2)

                // Labels
                Text("Lane 1")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
                    .position(x: 35, y: sidewalkH + laneH / 2)

                Text("Lane 2")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
                    .position(x: 35, y: sidewalkH + laneH + laneH / 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Street crossing lane view. Two-lane road with crosswalk. You are at the curb.")
        .accessibilityValue(isPlaying ? "\(selectedVehicle.label) passing in lane 2" : "Ready to simulate")
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 12) {
            // Vehicle picker
            HStack(spacing: 8) {
                ForEach(VehicleType.allCases, id: \.self) { type in
                    Button {
                        if !isPlaying { selectedVehicle = type }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: type.icon)
                                .font(.system(size: 18))
                            Text(type.label)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selectedVehicle == type ? type.color.opacity(0.2) : Color.clear)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedVehicle == type ? type.color : Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .foregroundColor(selectedVehicle == type ? type.color : .secondary)
                    .disabled(isPlaying)
                    .accessibilityLabel("\(type.label). \(type.description)")
                    .accessibilityAddTraits(selectedVehicle == type ? .isSelected : [])
                }
            }
            .padding(.horizontal)

            // Speed + sound info
            HStack {
                Text("\(Int(speed)) mph")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .frame(width: 50)

                Slider(value: $speed, in: 15...50, step: 5)
                    .disabled(isPlaying)
                    .accessibilityLabel("Vehicle speed")
                    .accessibilityValue("\(Int(speed)) miles per hour")

                Text(selectedVehicle.soundInfo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 90)
            }
            .padding(.horizontal)

            // Play button
            Button(action: playSimulation) {
                HStack {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    Text(isPlaying ? "Stop" : "Play Pass-By")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isPlaying ? Color.red : Color.blue)
                .cornerRadius(10)
            }
            .padding(.horizontal)
            .accessibilityLabel(isPlaying ? "Stop simulation" : "Play pass-by simulation")
            .accessibilityHint("Vehicle crosses from left to right with spatial audio")

            // Doppler + headphone note
            HStack {
                let shift = dopplerShift
                Image(systemName: "headphones")
                    .foregroundColor(.secondary)
                Text("Use headphones")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Doppler: +\(String(format: "%.1f", shift.approaching))% / -\(String(format: "%.1f", shift.receding))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    private func playSimulation() {
        if isPlaying {
            audioSimulator.stop()
            isPlaying = false
        } else {
            audioSimulator.play(vehicle: selectedVehicle, speedMPH: speed)
            isPlaying = true
        }
    }
}

#if DEBUG
struct SpatialAudioSimulationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SpatialAudioSimulationView()
        }
    }
}
#endif
