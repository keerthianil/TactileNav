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
            // One player → pitch → tone → mixer chain per simultaneous vehicle. Each vehicle
            // needs its own pitch shifter because each carries a different Doppler curve, and
            // its own filter because distance dulls a sound as well as quietening it.
            voices = (0..<Self.voiceCount).map { _ in
                let player = AVAudioPlayerNode()   // adopts AVAudioMixing → .pan/.volume
                let pitch = AVAudioUnitTimePitch() // real-time Doppler pitch shift
                let tone = AVAudioUnitEQ(numberOfBands: 1)
                // Air and distance roll off the top end long before they roll off the volume.
                // Without this a far-off car is just a quiet near car, which is the single
                // biggest reason synthesised traffic reads as fake.
                tone.bands[0].filterType = .lowPass
                tone.bands[0].frequency = 18_000
                tone.bands[0].bypass = false
                engine.attach(player)
                engine.attach(pitch)
                engine.attach(tone)
                engine.connect(player, to: pitch, format: fmt)
                engine.connect(pitch, to: tone, format: fmt)
                engine.connect(tone, to: engine.mainMixerNode, format: fmt)
                return Voice(player: player, pitch: pitch, tone: tone)
            }
            try engine.start()
            started = true
        } catch {
            started = false
        }
    }


    // MARK: - Buffer synthesis (phase-continuous harmonic tone)

    /// A looping vehicle sound: engine harmonics plus the tyre roar that actually dominates.
    ///
    /// A stack of sine harmonics on its own sounds like an organ, not a car. What you mostly
    /// hear from a passing vehicle is broadband tyre-on-road noise; the engine is the part that
    /// gives it a pitch to Doppler-shift. So the buffer is both: a harmonic series for pitch,
    /// and filtered noise for the body of the sound. An EV keeps the noise and loses almost all
    /// of the engine, which is exactly why it is so hard to hear.
    ///
    /// The loop is long and its length is a whole number of cycles of the fundamental, so it
    /// repeats without a click and without an audible period.
    private func toneBuffer(frequency: Double, harmonics: [Double], seconds: Double,
                            amplitude: Float, noiseMix: Double) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        // Round the loop to whole cycles of the fundamental so the wrap is seamless.
        let cycles = (seconds * frequency).rounded()
        let exactSeconds = cycles / frequency
        let frames = AVAudioFrameCount(sampleRate * exactSeconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let left = buf.floatChannelData![0], right = buf.floatChannelData![1]

        // Slightly different noise in each ear. Real road noise is not a point source, and a
        // decorrelated pair widens it into something that sits around you rather than inside
        // your head — which is what makes the stereo movement readable.
        var noiseL = 0.0, noiseR = 0.0
        var generator = SystemRandomNumberGenerator()

        for n in 0..<Int(frames) {
            let t = Double(n) / sampleRate

            var engineTone = 0.0
            for (index, harmonic) in harmonics.enumerated() {
                // Falling amplitude up the series, and a little detune so the harmonics beat
                // against each other instead of locking into a synthetic buzz.
                let amplitude = 1.0 / Double(index + 1)
                let detune = 1.0 + 0.0015 * Double(index)
                engineTone += amplitude * sin(2 * .pi * frequency * harmonic * detune * t)
            }
            engineTone /= Double(harmonics.count)

            // One-pole low-passed white noise: tyre roar.
            let whiteL = Double.random(in: -1...1, using: &generator)
            let whiteR = Double.random(in: -1...1, using: &generator)
            noiseL += 0.08 * (whiteL - noiseL)
            noiseR += 0.08 * (whiteR - noiseR)

            // Engine roughness: the firing rhythm, not a tremolo on the whole sound.
            let roughness = 0.88 + 0.12 * sin(2 * .pi * 6 * t)

            let engineLevel = (1 - noiseMix) * engineTone * roughness
            let sampleL = engineLevel + noiseMix * noiseL * 6
            let sampleR = engineLevel + noiseMix * noiseR * 6
            left[n] = Float(sampleL) * amplitude
            right[n] = Float(sampleR) * amplitude
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
        let tone: AVAudioUnitEQ
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

        // An EV is nearly all tyre noise — the thing that makes it dangerous to a listener.
        let harmonics: [Double] = type.isEV ? [1, 2.5] : [1, 2, 3, 4, 5]
        let noiseMix = type.isEV ? 0.82 : 0.45
        let loop = toneBuffer(frequency: type.baseFrequency, harmonics: harmonics,
                              seconds: 1.5, amplitude: type.loudness, noiseMix: noiseMix)
        voice.pitch.pitch = 0
        voice.tone.bands[0].frequency = 18_000
        voice.player.volume = 0
        voice.player.scheduleBuffer(loop, at: nil, options: [.loops], completionHandler: nil)
        voice.player.play()
        return index
    }

    /// Drive a voice from its vehicle's modelled position.
    ///
    /// `brightness` is 0 for far away and 1 for right beside you; it opens the low-pass so a
    /// close vehicle is bright and detailed and a distant one is a dull rumble. Distance is
    /// carried by three things at once — level, brightness and pitch shift — because that is
    /// how it is carried in the real world, and any one of them alone sounds synthetic.
    func updateVoice(_ index: Int, pan: Float, volume: Float, cents: Float, brightness: Float) {
        guard voices.indices.contains(index) else { return }
        let voice = voices[index]
        voice.player.pan = max(-1, min(1, pan))
        voice.player.volume = max(0, min(1, volume))
        voice.pitch.pitch = max(-2_400, min(2_400, cents))
        let clamped = max(0, min(1, brightness))
        // 900 Hz when far, ~14 kHz when close, on a curve rather than a straight line so the
        // change is audible across the whole approach instead of only in the last few metres.
        voice.tone.bands[0].frequency = 900 + 13_100 * clamped * clamped
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
