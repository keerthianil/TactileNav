// PortlandFeedbackManager.swift
// TactileNav
//
// Central feedback hub for Portland map haptics and audio.
// Uses CHHapticEngine directly for custom haptic patterns.

import UIKit
import CoreHaptics
import AVFoundation
import TactileMapCore
import TactileMapFeedback

@MainActor
final class PortlandFeedbackManager {

    static let shared = PortlandFeedbackManager()

    // MARK: - Haptic Engine

    private(set) var hapticEngine: CHHapticEngine?
    private var currentPlayer: CHHapticPatternPlayer?
    private var isEngineRunning = false

    // MARK: - Audio

    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var speechSynthesizer = AVSpeechSynthesizer()
    private var dingTimer: Timer?
    private var tickTimer: Timer?

    // MARK: - State

    private var activeFeedbackType: PortlandFeatureType?

    // MARK: - Init

    private init() {
        setupHapticEngine()
        setupAudioEngine()
        registerForLifecycleNotifications()
    }

    // MARK: - Engine Setup

    private func setupHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.isAutoShutdownEnabled = true
            hapticEngine?.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    self?.isEngineRunning = false
                }
            }
            hapticEngine?.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.restartEngine()
                }
            }
            try hapticEngine?.start()
            isEngineRunning = true
        } catch {
            print("PortlandFeedbackManager: Failed to create haptic engine: \(error)")
        }
    }

    private func restartEngine() {
        do {
            try hapticEngine?.start()
            isEngineRunning = true
        } catch {
            print("PortlandFeedbackManager: Failed to restart haptic engine: \(error)")
        }
    }

    private func ensureEngineRunning() {
        guard let engine = hapticEngine, !isEngineRunning else { return }
        do {
            try engine.start()
            isEngineRunning = true
        } catch {
            print("PortlandFeedbackManager: Could not start engine: \(error)")
        }
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        guard let engine = audioEngine, let player = audioPlayerNode else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            print("PortlandFeedbackManager: Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Road Feedback (Heavy continuous buzz)

    func startRoadFeedback() {
        stopAllFeedback()
        activeFeedbackType = .corridor
        ensureEngineRunning()

        guard let engine = hapticEngine else { return }
        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
                    ],
                    relativeTime: 0,
                    duration: 30.0
                )
            ], parameters: [])
            currentPlayer = try engine.makePlayer(with: pattern)
            try currentPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable on this device
        }
    }

    func stopRoadFeedback() {
        guard activeFeedbackType == .corridor else { return }
        stopCurrentHaptic()
        activeFeedbackType = nil
    }

    // MARK: - Intersection Feedback (Pulsing + ding)

    func startIntersectionFeedback() {
        stopAllFeedback()
        activeFeedbackType = .intersection
        ensureEngineRunning()

        guard let engine = hapticEngine else { return }

        // Pulsing haptic: 0.25s interval, 0.15s on
        do {
            var events: [CHHapticEvent] = []
            let pulseDuration: TimeInterval = 0.15
            let pulseInterval: TimeInterval = 0.25
            var time: TimeInterval = 0
            while time < 30.0 {
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: time,
                    duration: pulseDuration
                ))
                time += pulseInterval
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            currentPlayer = try engine.makePlayer(with: pattern)
            try currentPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }

        // Repeating ding audio
        startDingSound()
    }

    func stopIntersectionFeedback() {
        guard activeFeedbackType == .intersection else { return }
        stopCurrentHaptic()
        stopDingSound()
        activeFeedbackType = nil
    }

    // MARK: - Landmark Feedback (Fast pulse)

    func startLandmarkFeedback() {
        stopAllFeedback()
        activeFeedbackType = .landmark
        ensureEngineRunning()

        guard let engine = hapticEngine else { return }
        do {
            var events: [CHHapticEvent] = []
            let pulseDuration: TimeInterval = 0.08
            let pulseInterval: TimeInterval = 0.12
            var time: TimeInterval = 0
            while time < 30.0 {
                events.append(CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                    ],
                    relativeTime: time,
                    duration: pulseDuration
                ))
                time += pulseInterval
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            currentPlayer = try engine.makePlayer(with: pattern)
            try currentPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    func stopLandmarkFeedback() {
        guard activeFeedbackType == .landmark else { return }
        stopCurrentHaptic()
        activeFeedbackType = nil
    }

    // MARK: - Sidewalk Feedback (Softer continuous)

    func startSidewalkFeedback() {
        stopAllFeedback()
        activeFeedbackType = .sidewalk
        ensureEngineRunning()

        guard let engine = hapticEngine else { return }
        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.78),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.78)
                    ],
                    relativeTime: 0,
                    duration: 30.0
                )
            ], parameters: [])
            currentPlayer = try engine.makePlayer(with: pattern)
            try currentPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    func stopSidewalkFeedback() {
        guard activeFeedbackType == .sidewalk else { return }
        stopCurrentHaptic()
        activeFeedbackType = nil
    }

    // MARK: - Crosswalk Feedback (Rapid transient ticks + audio)

    func startCrosswalkFeedback() {
        stopAllFeedback()
        activeFeedbackType = .crosswalk
        ensureEngineRunning()

        guard let engine = hapticEngine else { return }
        do {
            var events: [CHHapticEvent] = []
            let tickInterval: TimeInterval = 0.17
            var time: TimeInterval = 0
            while time < 30.0 {
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: time
                ))
                time += tickInterval
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            currentPlayer = try engine.makePlayer(with: pattern)
            try currentPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }

        // Repeating tick audio
        startTickSound()
    }

    func stopCrosswalkFeedback() {
        guard activeFeedbackType == .crosswalk else { return }
        stopCurrentHaptic()
        stopTickSound()
        activeFeedbackType = nil
    }

    // MARK: - Single Tap

    func playSingleTap() {
        ensureEngineRunning()
        guard let engine = hapticEngine else { return }
        do {
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: 0
                )
            ], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics unavailable
        }
    }

    // MARK: - Speech

    /// Speaks text using VoiceOver announcement (if running) or AVSpeechSynthesizer.
    func speak(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            speechSynthesizer.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            speechSynthesizer.speak(utterance)
        }
    }

    // MARK: - Stop All

    func stopAllFeedback() {
        stopCurrentHaptic()
        stopDingSound()
        stopTickSound()
        speechSynthesizer.stopSpeaking(at: .immediate)
        activeFeedbackType = nil
    }

    private func stopCurrentHaptic() {
        try? currentPlayer?.stop(atTime: CHHapticTimeImmediate)
        currentPlayer = nil
    }

    // MARK: - Audio Synthesis

    /// Plays a repeating 1120 Hz ding (0.16s) for intersection feedback.
    private func startDingSound() {
        playTone(frequency: 1120.0, duration: 0.16)
        dingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playTone(frequency: 1120.0, duration: 0.16)
            }
        }
    }

    private func stopDingSound() {
        dingTimer?.invalidate()
        dingTimer = nil
    }

    /// Plays a repeating 820 Hz tick (0.012s) for crosswalk feedback.
    private func startTickSound() {
        playTone(frequency: 820.0, duration: 0.012)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.17, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playTone(frequency: 820.0, duration: 0.012)
            }
        }
    }

    private func stopTickSound() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Synthesizes a pure tone at the given frequency and duration using AVAudioEngine.
    private func playTone(frequency: Double, duration: Double) {
        guard let engine = audioEngine, let player = audioPlayerNode else { return }

        let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }

        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }

        buffer.frameLength = frameCount
        guard let floatData = buffer.floatChannelData?[0] else { return }

        for i in 0..<Int(frameCount) {
            let sample = sin(2.0 * Double.pi * frequency * Double(i) / sampleRate)
            // Apply envelope to avoid clicks
            let envelope: Double
            let rampSamples = min(Int(0.005 * sampleRate), Int(frameCount) / 4)
            if i < rampSamples {
                envelope = Double(i) / Double(rampSamples)
            } else if i > Int(frameCount) - rampSamples {
                envelope = Double(Int(frameCount) - i) / Double(rampSamples)
            } else {
                envelope = 1.0
            }
            floatData[i] = Float(sample * envelope * 0.3)
        }

        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - App Lifecycle

    private func registerForLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAppBackground()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAppForeground()
            }
        }
    }

    func handleAppBackground() {
        stopAllFeedback()
        hapticEngine?.stop()
        isEngineRunning = false
        audioEngine?.pause()
    }

    func handleAppForeground() {
        restartEngine()
        if let engine = audioEngine, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("PortlandFeedbackManager: Failed to restart audio engine: \(error)")
            }
        }
    }

    // MARK: - Feature-Based Feedback

    /// Starts feedback appropriate for the given feature type.
    func startFeedback(for feature: PortlandMapFeature) {
        switch feature.featureType {
        case .corridor:
            startRoadFeedback()
        case .intersection:
            startIntersectionFeedback()
        case .landmark:
            startLandmarkFeedback()
        case .sidewalk:
            startSidewalkFeedback()
        case .crosswalk:
            startCrosswalkFeedback()
        }
    }
}
