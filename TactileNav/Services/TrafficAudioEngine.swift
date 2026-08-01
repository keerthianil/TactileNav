//
//  TrafficAudioEngine.swift
//  TactileNav
//
//  The audio backbone for traffic perception. One AVAudioEngine drives a pool of vehicle
//  voices: each is a synthesized, continuously-looping engine tone whose PITCH is shifted in
//  real time to reproduce the Doppler effect (rising as a vehicle approaches, falling as it
//  recedes). Pitch, pan and volume are all driven live from the vehicle's modelled position,
//  so the Doppler shift is physically computed, never a cosmetic label.
//
//  The pool exists because a four-way intersection has traffic on more than one leg at once,
//  and telling those movements apart by ear is the entire skill being demonstrated.
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
        var isEV: Bool { self == .ev }
    }

    // MARK: - Engine graph

    private let engine = AVAudioEngine()
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
            // One player → pitch → mixer chain per simultaneous vehicle. Each vehicle needs
            // its own pitch shifter because each carries a different Doppler curve.
            voices = (0..<Self.voiceCount).map { _ in
                let player = AVAudioPlayerNode()   // adopts AVAudioMixing → .pan/.volume
                let pitch = AVAudioUnitTimePitch() // real-time Doppler pitch shift
                engine.attach(player)
                engine.attach(pitch)
                engine.connect(player, to: pitch, format: fmt)
                engine.connect(pitch, to: engine.mainMixerNode, format: fmt)
                return Voice(player: player, pitch: pitch)
            }
            try engine.start()
            started = true
        } catch {
            started = false
        }
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

    // MARK: - Voice pool
    //
    // A four-way intersection has traffic on several legs at once, so one shared player is
    // not enough — each vehicle needs its own pitch shifter to carry its own Doppler curve.
    // Voices are pooled rather than created per vehicle because attaching and connecting
    // nodes on a running engine is expensive and audibly glitchy.

    private struct Voice {
        let player: AVAudioPlayerNode
        let pitch: AVAudioUnitTimePitch
        var inUse = false
    }

    private var voices: [Voice] = []

    /// Simultaneous vehicles. Beyond this the intersection is a wall of noise anyway, and the
    /// individual Doppler curves stop being distinguishable — which is the thing being taught.
    static let voiceCount = 6

    /// Claim a voice and start its engine tone looping. Returns nil when all are busy.
    func acquireVoice(type: VehicleType) -> Int? {
        guard started else { return nil }
        guard let index = voices.firstIndex(where: { !$0.inUse }) else { return nil }

        voices[index].inUse = true
        let voice = voices[index]

        let harmonics: [Double] = type.isEV ? [1, 2.5] : [1, 2, 3, 4]
        let loop = toneBuffer(frequency: type.baseFrequency, harmonics: harmonics,
                              seconds: 0.5, amplitude: type.loudness)
        voice.pitch.pitch = 0
        voice.player.volume = 0
        voice.player.scheduleBuffer(loop, at: nil, options: [.loops], completionHandler: nil)
        voice.player.play()
        return index
    }

    /// Drive a voice from its vehicle's modelled position.
    func updateVoice(_ index: Int, pan: Float, volume: Float, cents: Float) {
        guard voices.indices.contains(index) else { return }
        let voice = voices[index]
        voice.player.pan = max(-1, min(1, pan))
        voice.player.volume = max(0, min(1, volume))
        voice.pitch.pitch = max(-2_400, min(2_400, cents))
    }

    func releaseVoice(_ index: Int) {
        guard voices.indices.contains(index) else { return }
        voices[index].player.stop()
        voices[index].pitch.pitch = 0
        voices[index].inUse = false
    }

    func releaseAllVoices() {
        for index in voices.indices {
            voices[index].player.stop()
            voices[index].pitch.pitch = 0
            voices[index].inUse = false
        }
    }
}
