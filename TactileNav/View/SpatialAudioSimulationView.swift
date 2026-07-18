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
        case .car:
            return "Standard passenger car with internal combustion engine"
        case .bus:
            return "City transit bus with heavy diesel engine"
        case .truck:
            return "Large freight truck with deep exhaust rumble"
        case .ev:
            return "Electric vehicle with quiet high-pitched motor whine"
        }
    }

    var soundInfo: String {
        switch self {
        case .car:
            return "~70 dBA at 25 ft. Broadband engine noise centered around 200-1200 Hz."
        case .bus:
            return "~80 dBA at 25 ft. Low-frequency rumble dominant at 100-350 Hz."
        case .truck:
            return "~85 dBA at 25 ft. Deep engine drone and exhaust at 80-500 Hz."
        case .ev:
            return "~50 dBA at 25 ft. Very quiet high-frequency whine at 2000-4000 Hz. Hard to detect at low speeds."
        }
    }

    /// Each entry is (frequencyHz, amplitude).
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
}

// MARK: - Vehicle Audio Simulator

@MainActor
final class VehicleAudioSimulator: ObservableObject {

    // Audio graph
    private let audioEngine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let vehicleNode = AVAudioPlayerNode()

    // Playback state
    @Published var isPlaying = false
    @Published var vehicleScreenX: CGFloat = 0

    private var positionTimer: Timer?
    private var startTime: Date = .distantPast
    private var duration: Double = 2.0
    private var audioBuffer: AVAudioPCMBuffer?

    // Position range in 3D space
    private let startX: Float = -20
    private let endX: Float = 20
    private let forwardZ: Float = 2

    // MARK: - Setup

    init() {
        configureEngine()
    }

    deinit {
        positionTimer?.invalidate()
        positionTimer = nil
        audioEngine.stop()
    }

    private func configureEngine() {
        // Attach nodes
        audioEngine.attach(environment)
        audioEngine.attach(vehicleNode)

        // Spatialization settings
        vehicleNode.renderingAlgorithm = .HRTFHQ
        vehicleNode.sourceMode = .spatializeIfMono

        // Distance attenuation
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 5.0
        environment.distanceAttenuationParameters.maximumDistance = 50.0
        environment.distanceAttenuationParameters.rolloffFactor = 1.0

        // Connect: vehicleNode -> environment -> mainMixer -> output
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
        guard let monoFormat else { return }
        audioEngine.connect(vehicleNode, to: environment, format: monoFormat)
        audioEngine.connect(environment, to: audioEngine.mainMixerNode, format: nil)

        // Initial position off-screen left
        vehicleNode.position = AVAudio3DPoint(x: startX, y: 0, z: forwardZ)
    }

    // MARK: - Tone Buffer Generation

    /// Creates a looping PCM buffer that mixes the given sine-wave components
    /// with subtle amplitude modulation for a more realistic engine sound.
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

        // Amplitude modulation frequency (slight tremolo for realism)
        let amFreq = 6.0  // Hz – subtle engine pulse

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var sample: Float = 0

            // Mix all frequency components
            for (freq, amp) in frequencies {
                let sine = sin(2.0 * .pi * freq * t)
                sample += amp * Float(sine)
            }

            // Apply subtle amplitude modulation
            let am = Float(1.0 + 0.15 * sin(2.0 * .pi * amFreq * t))
            sample *= am

            // Normalize so total peak stays <= 1.0
            let componentCount = Float(frequencies.count)
            sample /= componentCount

            channelData[frame] = sample
        }

        return buffer
    }

    // MARK: - Playback

    func play(vehicle: VehicleType, speedMPH: Double) {
        // If already playing, stop first
        if isPlaying { stop() }

        // Configure audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
            return
        }

        // Generate tone
        guard let buffer = generateToneBuffer(frequencies: vehicle.frequencies) else {
            print("Failed to generate tone buffer")
            return
        }
        audioBuffer = buffer

        // Reset position
        vehicleNode.position = AVAudio3DPoint(x: startX, y: 0, z: forwardZ)
        vehicleScreenX = -150

        // Calculate duration: distance / speed
        let distanceMeters: Double = Double(endX - startX) // 40 meters
        let speedMS = speedMPH * 0.447
        duration = distanceMeters / speedMS

        // Start engine
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
        } catch {
            print("Audio engine failed to start: \(error)")
            return
        }

        // Schedule looping buffer
        vehicleNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        vehicleNode.play()

        isPlaying = true
        startTime = Date()

        // VoiceOver announcement
        UIAccessibility.post(
            notification: .announcement,
            argument: "Vehicle simulation started"
        )

        // Start position update timer
        positionTimer = Timer.scheduledTimer(
            withTimeInterval: 0.02,
            repeats: true
        ) { [weak self] _ in
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
        vehicleScreenX = 0

        UIAccessibility.post(
            notification: .announcement,
            argument: "Vehicle simulation stopped"
        )
    }

    private func updatePosition() {
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = elapsed / duration

        if progress >= 1.0 {
            // Simulation complete
            positionTimer?.invalidate()
            positionTimer = nil
            vehicleNode.stop()
            isPlaying = false
            vehicleScreenX = 150

            UIAccessibility.post(
                notification: .announcement,
                argument: "Vehicle has passed"
            )
            return
        }

        // Interpolate 3D position from startX to endX
        let currentX = startX + Float(progress) * (endX - startX)
        vehicleNode.position = AVAudio3DPoint(x: currentX, y: 0, z: forwardZ)

        // Map to screen offset (-150 ... +150)
        let normalized = CGFloat((currentX - startX) / (endX - startX))
        vehicleScreenX = -150 + normalized * 300
    }

    /// Tears down the audio engine completely.
    func tearDown() {
        stop()
        audioEngine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
}

// MARK: - Spatial Audio Simulation View

struct SpatialAudioSimulationView: View {

    @State private var selectedVehicle: VehicleType = .car
    @State private var speed: Double = 30
    @State private var isPlaying = false
    @StateObject private var audioSimulator = VehicleAudioSimulator()

    /// Doppler shift percentages for display purposes.
    /// The actual Doppler effect is handled automatically by AVAudioEnvironmentNode.
    private var dopplerShift: (approaching: Double, receding: Double) {
        let speedMS = speed * 0.447
        let soundSpeed = 343.0
        let approaching = (speedMS / (soundSpeed - speedMS)) * 100
        let receding = (speedMS / (soundSpeed + speedMS)) * 100
        return (approaching, receding)
    }

    private var vehicleColor: Color {
        selectedVehicle.color
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                roadVisualization
                vehicleSelector
                speedControl
                playButton
                dopplerInfoSection
                soundCharacteristicsSection
                Spacer(minLength: 30)
            }
        }
        .navigationTitle("Street Crossing Simulation")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            audioSimulator.tearDown()
        }
        .onChange(of: audioSimulator.isPlaying) { _, newValue in
            isPlaying = newValue
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 40))
                .foregroundColor(.blue)
                .accessibilityHidden(true)

            Text("Street Crossing Simulation")
                .font(.title2)
                .fontWeight(.bold)

            Text("Simulates vehicle sounds at a street crossing. Stand at the curb and hear traffic pass in front of you with spatial audio.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Street Crossing Simulation. Simulates vehicle sounds at a street crossing with spatial audio.")
    }

    // MARK: - Road Visualization

    private var roadVisualization: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(height: 20)

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.35))
                    .frame(height: 80)

                Rectangle()
                    .fill(Color.yellow)
                    .frame(height: 3)

                if isPlaying {
                    Circle()
                        .fill(vehicleColor)
                        .frame(width: 24, height: 24)
                        .offset(x: audioSimulator.vehicleScreenX)
                        .animation(.linear(duration: 0.02), value: audioSimulator.vehicleScreenX)
                }
            }

            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 20)

                Image(systemName: "figure.stand")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Street crossing visualization. You are standing at the curb.")
        .accessibilityValue(isPlaying ? "Vehicle passing from left to right" : "Ready")
    }

    // MARK: - Vehicle Selector

    private var vehicleSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vehicle Type")
                .font(.headline)

            Picker("Vehicle Type", selection: $selectedVehicle) {
                ForEach(VehicleType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Select the type of vehicle to simulate")
            .disabled(isPlaying)

            Text(selectedVehicle.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityLabel(selectedVehicle.description)
        }
        .padding(.horizontal)
    }

    // MARK: - Speed Control

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed: \(Int(speed)) mph")
                .font(.headline)

            Slider(value: $speed, in: 15...50, step: 5)
                .accessibilityLabel("Vehicle speed")
                .accessibilityValue("\(Int(speed)) miles per hour")
                .accessibilityHint("Adjust the speed of the simulated vehicle")
                .disabled(isPlaying)

            HStack {
                Text("15 mph")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("50 mph")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Play Button

    private var playButton: some View {
        Button(action: playSimulation) {
            HStack {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                Text(isPlaying ? "Stop" : "Play Pass-By")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(isPlaying ? Color.red : Color.blue)
            .cornerRadius(12)
        }
        .padding(.horizontal)
        .accessibilityLabel(isPlaying ? "Stop simulation" : "Play pass-by simulation")
        .accessibilityHint(
            isPlaying
                ? "Stop the vehicle simulation"
                : "Start the vehicle passing from left to right with spatial audio and Doppler effect"
        )
    }

    // MARK: - Doppler Info

    private var dopplerInfoSection: some View {
        let shift = dopplerShift

        return VStack(alignment: .leading, spacing: 12) {
            Label("Doppler Effect", systemImage: "waveform.badge.magnifyingglass")
                .font(.headline)

            Text("As the vehicle approaches, its pitch rises slightly. As it passes and moves away, the pitch drops. This is the Doppler effect.")
                .font(.subheadline)

            Text("At \(Int(speed)) mph: +\(String(format: "%.1f", shift.approaching))% pitch approaching, -\(String(format: "%.1f", shift.receding))% receding")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Use headphones for the best spatial audio experience. The sound will move from your left ear to your right ear as the vehicle passes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Sound Characteristics

    private var soundCharacteristicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sound Characteristics", systemImage: "speaker.wave.3")
                .font(.headline)

            Text(selectedVehicle.soundInfo)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

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

// MARK: - Preview

#if DEBUG
struct SpatialAudioSimulationView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SpatialAudioSimulationView()
        }
    }
}
#endif
