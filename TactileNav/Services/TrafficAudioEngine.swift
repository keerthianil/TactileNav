//
//  TrafficAudioEngine.swift
//  TactileNav
//
//  The audio backbone for traffic perception. One AVAudioEngine drives:
//    • a synthesized, continuously-looping vehicle engine tone whose PITCH is shifted in
//      real time to reproduce the Doppler effect (rising as a vehicle approaches, falling
//      as it recedes) — pitch/pan/volume are all driven live from the vehicle's modelled
//      position, so the Doppler shift is physically computed, never a cosmetic label;
//    • earcons for accessible pedestrian signals (locator tone, WALK tick) and a
//      low-frequency traffic "rumble" whose density tracks the congestion level.
//
//  Doppler:  f' = f · c / (c − v_radial),  v_radial = closing speed toward the listener.
//  A 25 mph pass produces ≈1.1 semitones of total shift (matching the research report),
//  applied via AVAudioUnitTimePitch.pitch (cents). Use headphones for the spatial cues.
//

import Foundation
import AVFoundation

@MainActor
final class TrafficAudioEngine {

    static let shared = TrafficAudioEngine()

    // MARK: - Vehicle types (sound signatures from the research report, Topic 5)

    enum VehicleType: String, CaseIterable, Identifiable {
        case car, bus, truck, ev

        var id: String { rawValue }
        var label: String {
            switch self {
            case .car:   return "Car"
            case .bus:   return "Bus"
            case .truck: return "Truck"
            case .ev:    return "Electric vehicle"
            }
        }
        var symbol: String {
            switch self {
            case .car:   return "car.fill"
            case .bus:   return "bus.fill"
            case .truck: return "truck.box.fill"
            case .ev:    return "bolt.car.fill"
            }
        }
        /// Fundamental engine frequency (Hz).
        var baseFrequency: Double {
            switch self {
            case .car:   return 118
            case .bus:   return 82
            case .truck: return 68
            case .ev:    return 520   // high, faint electric whine
            }
        }
        /// Relative loudness (0…1). EVs are alarmingly quiet (<45 dBA under 20 mph).
        var loudness: Float {
            switch self {
            case .car:   return 0.85
            case .bus:   return 1.0
            case .truck: return 1.0
            case .ev:    return 0.28
            }
        }
        /// Approx. sound level 7.5 m away at ~30 mph, for the on-screen readout.
        var dBADescriptor: String {
            switch self {
            case .car:   return "65–70 dBA"
            case .bus:   return "75–85 dBA"
            case .truck: return "75–85 dBA"
            case .ev:    return "under 45 dBA (near-silent)"
            }
        }
        var isEV: Bool { self == .ev }
    }

    // MARK: - Engine graph

    private let engine = AVAudioEngine()
    private let vehiclePlayer = AVAudioPlayerNode()     // adopts AVAudioMixing → .pan/.volume
    private let vehiclePitch = AVAudioUnitTimePitch()   // real-time Doppler pitch shift
    private let earconPlayer = AVAudioPlayerNode()      // APS tones, ding
    private let rumblePlayer = AVAudioPlayerNode()      // continuous traffic rumble
    private let sampleRate = 44_100.0
    private var started = false

    // MARK: - Session

    private init() {}

    func activate() {
        guard !started else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            engine.attach(vehiclePlayer)
            engine.attach(vehiclePitch)
            engine.attach(earconPlayer)
            engine.attach(rumblePlayer)
            // vehicle: player → pitch(Doppler) → mainMixer.   pan/volume set on the player.
            engine.connect(vehiclePlayer, to: vehiclePitch, format: fmt)
            engine.connect(vehiclePitch, to: engine.mainMixerNode, format: fmt)
            engine.connect(earconPlayer, to: engine.mainMixerNode, format: fmt)
            engine.connect(rumblePlayer, to: engine.mainMixerNode, format: fmt)
            try engine.start()
            started = true
        } catch {
            started = false
        }
    }

    func deactivate() {
        stopVehiclePass()
        stopRumble()
        vehiclePlayer.stop(); earconPlayer.stop(); rumblePlayer.stop()
        engine.stop()
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Buffer synthesis (phase-continuous harmonic tone)

    private func toneBuffer(frequency: Double, harmonics: [Double], seconds: Double,
                            amplitude: Float) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
        for n in 0..<Int(frames) {
            let t = Double(n) / sampleRate
            var s = 0.0
            for (i, h) in harmonics.enumerated() {
                let amp = 1.0 / Double(i + 1)
                s += amp * sin(2 * .pi * frequency * h * t)
            }
            // 6 Hz amplitude modulation → rougher, engine-like timbre
            let mod = 0.85 + 0.15 * sin(2 * .pi * 6 * t)
            let v = Float(s / Double(harmonics.count)) * amplitude * Float(mod)
            L[n] = v; R[n] = v
        }
        return buf
    }

    // MARK: - Continuous traffic rumble (density = congestion)

    private var rumbleLoop: AVAudioPCMBuffer?

    /// Start a low rumble at the given fundamental (nil = quiet, gaps detectable → stop).
    func startRumble(hz: Double?, amplitude: Float) {
        guard started else { return }
        stopRumble()
        guard let hz else { return }
        let buf = toneBuffer(frequency: hz, harmonics: [1, 2], seconds: 0.5, amplitude: amplitude)
        rumbleLoop = buf
        rumblePlayer.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        rumblePlayer.play()
    }

    func stopRumble() {
        rumblePlayer.stop()
        rumbleLoop = nil
    }

    // MARK: - Earcons (APS + confirmation)

    /// A short beep (locator tone / ding / WALK tick), non-spatial.
    func playBeep(hz: Double, seconds: Double = 0.08, amplitude: Float = 0.5) {
        guard started else { return }
        let buf = toneBuffer(frequency: hz, harmonics: [1], seconds: seconds, amplitude: amplitude)
        earconPlayer.scheduleBuffer(buf, at: nil, options: [.interrupts], completionHandler: nil)
        earconPlayer.play()
    }

    // MARK: - Vehicle pass with real Doppler

    struct PassConfig {
        var type: VehicleType = .car
        var speedMph: Double = 25
        var turning: Bool = false      // false = through / straight; true = turns across path
        var curbDistanceM: Double = 4  // lateral distance from listener to the lane
        var spanM: Double = 60         // total travel length
    }

    private var passTimer: Timer?
    private var passStart: CFTimeInterval = 0
    private var passConfig = PassConfig()
    private var lastDistance: Double = .greatestFiniteMagnitude
    private var onPassProgress: ((_ progress: Double, _ closing: Bool, _ pitchCents: Double) -> Void)?
    private var onPassDone: (() -> Void)?

    /// Animate one pass. `progress` 0…1 drives the UI; audio pan/volume/pitch update live.
    func startVehiclePass(_ config: PassConfig,
                          onProgress: @escaping (Double, Bool, Double) -> Void,
                          onComplete: @escaping () -> Void) {
        guard started else { onComplete(); return }
        stopVehiclePass()
        passConfig = config
        onPassProgress = onProgress
        onPassDone = onComplete
        lastDistance = .greatestFiniteMagnitude

        // continuous looping engine tone for this vehicle
        let harmonics: [Double] = config.type.isEV ? [1, 2.5] : [1, 2, 3, 4]
        let loop = toneBuffer(frequency: config.type.baseFrequency, harmonics: harmonics,
                              seconds: 0.5, amplitude: config.type.loudness)
        vehiclePitch.pitch = 0
        vehiclePlayer.scheduleBuffer(loop, at: nil, options: [.loops], completionHandler: nil)
        vehiclePlayer.play()

        passStart = CACurrentMediaTime()
        passTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPass() }
        }
    }

    func stopVehiclePass() {
        passTimer?.invalidate(); passTimer = nil
        vehiclePlayer.stop()
        vehiclePitch.pitch = 0
        onPassProgress = nil
        onPassDone = nil
    }

    private func tickPass() {
        let speedMps = passConfig.speedMph * 0.44704
        let elapsed = CACurrentMediaTime() - passStart
        let travelled = speedMps * elapsed
        let total = passConfig.spanM
        let progress = travelled / total
        guard progress <= 1.0 else {
            let done = onPassDone
            stopVehiclePass()
            done?()
            return
        }

        // Listener at origin. Straight pass: vehicle runs along x at constant lateral z.
        // Turning: it slows and curves toward the listener's crossing (z shrinks), lingering.
        let x = -total / 2 + travelled
        var z = passConfig.curbDistanceM
        if passConfig.turning {
            // in the second half, bend toward the crosswalk (z → ~1 m) and slow the x advance feel
            let p = max(0, (progress - 0.5) * 2)   // 0→1 over the back half
            z = passConfig.curbDistanceM * (1 - 0.8 * p) + 1.0 * p
        }
        let distance = max(0.6, sqrt(x * x + z * z))

        // Doppler from radial closing speed (finite-difference on distance).
        let dt = 1.0 / 60.0
        let closingSpeed = (lastDistance - distance) / dt   // >0 approaching
        lastDistance = distance
        let c = 343.0
        let ratio = c / max(1.0, c - closingSpeed)          // approaching → >1 → higher pitch
        let cents = max(-400, min(400, 1200 * log2(ratio)))
        vehiclePitch.pitch = Float(cents)

        // Direction (pan) and distance (volume). EVs keep a low floor → near-silent hazard.
        let pan = Float(max(-1, min(1, x / (total / 2))))
        vehiclePlayer.pan = pan
        let refDist = 6.0
        var vol = Float(refDist / distance)
        vol = min(vol, 1.0) * passConfig.type.loudness
        vehiclePlayer.volume = max(passConfig.type.isEV ? 0.02 : 0.05, vol)

        onPassProgress?(progress, closingSpeed > 0, cents)
    }
}
