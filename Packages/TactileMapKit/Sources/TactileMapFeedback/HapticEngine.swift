import CoreHaptics
import UIKit
import TactileMapCore

// MARK: - Protocol

/// An engine that can play configurable haptic patterns.
///
/// The protocol is `@MainActor` so that UI-lifecycle helpers
/// (`handleAppBackground`, `handleAppForeground`) are safe to call
/// from SwiftUI or UIKit view code.
@MainActor
public protocol HapticEngine: AnyObject {

    /// Start playing the given pattern.  If a pattern of the same
    /// category (continuous / pulsing) is already running, it is
    /// stopped first.
    func start(pattern: HapticPattern)

    /// Stop the most recently started pattern.
    func stop()

    /// Stop all active haptic players (continuous and pulsing).
    func stopAll()

    /// Play a single transient tap with UIImpactFeedbackGenerator fallback.
    func playSingleTap()

    /// Whether any haptic player is currently active.
    var isPlaying: Bool { get }

    /// Call when the app enters the background to release the engine.
    func handleAppBackground()

    /// Call when the app returns to the foreground to restart the engine.
    func handleAppForeground()
}

// MARK: - CoreHaptics implementation

/// Default `HapticEngine` backed by `CHHapticEngine`, parameterised by
/// ``HapticPattern``.
@MainActor
public final class CoreHapticsEngine: HapticEngine {

    // MARK: - Private state

    private var hapticEngine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?
    private var pulsePlayer: CHHapticAdvancedPatternPlayer?

    private var isContinuousPlaying = false
    private var isPulsingPlaying = false
    private var supportsHaptics = false

    /// The pattern that was most recently started via `start(pattern:)`.
    /// Kept so that `restartEngine` can re-create the player after an
    /// engine reset.
    private var activePattern: HapticPattern?

    // MARK: - Public computed property

    public var isPlaying: Bool {
        isContinuousPlaying || isPulsingPlaying
    }

    // MARK: - Initializer

    /// Creates a new engine instance.  Not a singleton -- callers own
    /// the lifecycle.
    public init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        setupEngine()
    }

    // MARK: - Engine setup

    private func setupEngine() {
        guard supportsHaptics else { return }

        do {
            hapticEngine = try CHHapticEngine()

            hapticEngine?.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.restartEngine()
                }
            }

            hapticEngine?.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.restartEngine()
                }
            }

            try hapticEngine?.start()
        } catch {
            TactileMapDiagnostics.log("Haptic engine failed to start -- haptics unavailable: \(error)")
        }
    }

    private func restartEngine() {
        do {
            try hapticEngine?.start()

            // Re-create the active pattern player if one was running.  This
            // covers looping patterns of either category (continuous *and*
            // pulsing/burst) so haptics survive an engine reset triggered by
            // interruptions, Siri, or backgrounding.
            if let pattern = activePattern, isContinuousPlaying || isPulsingPlaying {
                isContinuousPlaying = false
                isPulsingPlaying = false
                start(pattern: pattern)
            }
        } catch {
            TactileMapDiagnostics.log("Haptic engine restart failed: \(error)")
        }
    }

    // MARK: - HapticEngine conformance

    public func start(pattern: HapticPattern) {
        guard supportsHaptics else { return }

        activePattern = pattern

        switch pattern.mode {
        case .continuous(let duration):
            startContinuous(pattern: pattern, duration: duration)

        case .pulsing(let onDuration, let offDuration, let count):
            startPulsing(pattern: pattern,
                         onDuration: onDuration,
                         offDuration: offDuration,
                         count: count)

        case .burst(let pulseCount, let onDuration, let offDuration):
            startBurst(pattern: pattern,
                       pulseCount: pulseCount,
                       onDuration: onDuration,
                       offDuration: offDuration)

        case .transient:
            playTransient(pattern: pattern)
        }
    }

    public func stop() {
        if isContinuousPlaying {
            stopContinuous()
        }
        if isPulsingPlaying {
            stopPulsing()
        }
        activePattern = nil
    }

    public func stopAll() {
        stopContinuous()
        stopPulsing()
        activePattern = nil
    }

    public func playSingleTap() {
        start(pattern: .singleTap)
    }

    public func handleAppBackground() {
        stopAll()
        hapticEngine?.stop()
    }

    public func handleAppForeground() {
        guard supportsHaptics else { return }
        do {
            try hapticEngine?.start()
        } catch {
            TactileMapDiagnostics.log("Foreground engine restart failed: \(error)")
        }
    }

    // MARK: - Continuous vibration

    private func startContinuous(pattern: HapticPattern, duration: TimeInterval) {
        guard !isContinuousPlaying else { return }

        // Stop any pulsing first.
        stopPulsing()

        do {
            try ensureEngineRunning()

            let intensityParam = CHHapticEventParameter(
                parameterID: .hapticIntensity,
                value: pattern.intensity
            )
            let sharpnessParam = CHHapticEventParameter(
                parameterID: .hapticSharpness,
                value: pattern.sharpness
            )

            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensityParam, sharpnessParam],
                relativeTime: 0,
                duration: duration
            )

            let hapticPattern = try CHHapticPattern(events: [event], parameters: [])
            continuousPlayer = try hapticEngine?.makeAdvancedPlayer(with: hapticPattern)
            try continuousPlayer?.start(atTime: CHHapticTimeImmediate)

            isContinuousPlaying = true
        } catch {
            TactileMapDiagnostics.log("Continuous pattern failed to start: \(error)")
        }
    }

    private func stopContinuous() {
        isContinuousPlaying = false
        do {
            try continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
        } catch {
            // Ignoring stop error.
        }
        continuousPlayer = nil
    }

    // MARK: - Pulsing vibration

    private func startPulsing(
        pattern: HapticPattern,
        onDuration: TimeInterval,
        offDuration: TimeInterval,
        count: Int
    ) {
        guard let engine = hapticEngine else { return }

        // Stop any continuous vibration first.
        stopContinuous()
        stopPulsing()

        do {
            try ensureEngineRunning()

            let cycleInterval = onDuration + offDuration
            var events: [CHHapticEvent] = []

            for i in 0..<count {
                let intensityParam = CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: pattern.intensity
                )
                let sharpnessParam = CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: pattern.sharpness
                )

                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [intensityParam, sharpnessParam],
                    relativeTime: TimeInterval(i) * cycleInterval,
                    duration: onDuration
                )
                events.append(event)
            }

            let hapticPattern = try CHHapticPattern(events: events, parameters: [])
            pulsePlayer = try engine.makeAdvancedPlayer(with: hapticPattern)
            pulsePlayer?.loopEnabled = true
            try pulsePlayer?.start(atTime: CHHapticTimeImmediate)

            isPulsingPlaying = true
        } catch {
            TactileMapDiagnostics.log("Pulsing pattern failed to start: \(error)")
        }
    }

    // MARK: - Burst vibration

    /// Plays repeating bursts: `pulseCount` evenly-spaced transient taps within
    /// `onDuration`, then a silent rest of `offDuration`, looping.
    ///
    /// A single zero-intensity spacer event pads the pattern to the full
    /// `onDuration + offDuration` cycle so `loopEnabled` honors the rest between
    /// bursts (transient events have ~0 duration, so without it the loop would
    /// restart immediately with no gap).  Reuses the pulse player slot so
    /// `stop()`/`stopAll()` treat bursts like any other looping pattern.
    private func startBurst(
        pattern: HapticPattern,
        pulseCount: Int,
        onDuration: TimeInterval,
        offDuration: TimeInterval
    ) {
        guard let engine = hapticEngine else { return }
        guard pulseCount > 0, onDuration > 0 else { return }

        // Stop any other vibration first.
        stopContinuous()
        stopPulsing()

        do {
            try ensureEngineRunning()

            let spacing = onDuration / TimeInterval(pulseCount)
            var events: [CHHapticEvent] = []

            for i in 0..<pulseCount {
                let intensityParam = CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: pattern.intensity
                )
                let sharpnessParam = CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: pattern.sharpness
                )

                let event = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [intensityParam, sharpnessParam],
                    relativeTime: TimeInterval(i) * spacing
                )
                events.append(event)
            }

            // Silent spacer spanning the rest so the loop period is the full cycle.
            let spacer = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0)
                ],
                relativeTime: onDuration,
                duration: offDuration
            )
            events.append(spacer)

            let hapticPattern = try CHHapticPattern(events: events, parameters: [])
            pulsePlayer = try engine.makeAdvancedPlayer(with: hapticPattern)
            pulsePlayer?.loopEnabled = true
            try pulsePlayer?.start(atTime: CHHapticTimeImmediate)

            isPulsingPlaying = true
        } catch {
            TactileMapDiagnostics.log("Burst pattern failed to start: \(error)")
        }
    }

    private func stopPulsing() {
        isPulsingPlaying = false
        do {
            try pulsePlayer?.stop(atTime: CHHapticTimeImmediate)
        } catch {
            // Ignoring stop error.
        }
        pulsePlayer = nil
    }

    // MARK: - Transient tap

    private func playTransient(pattern: HapticPattern) {
        guard supportsHaptics else {
            playFallbackTap()
            return
        }

        do {
            try ensureEngineRunning()

            let intensityParam = CHHapticEventParameter(
                parameterID: .hapticIntensity,
                value: pattern.intensity
            )
            let sharpnessParam = CHHapticEventParameter(
                parameterID: .hapticSharpness,
                value: pattern.sharpness
            )

            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [intensityParam, sharpnessParam],
                relativeTime: 0
            )

            let hapticPattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try hapticEngine?.makePlayer(with: hapticPattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            playFallbackTap()
        }
    }

    // MARK: - Helpers

    private func ensureEngineRunning() throws {
        if hapticEngine?.currentTime == nil {
            try hapticEngine?.start()
        }
    }

    private func playFallbackTap() {
        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.prepare()
        impact.impactOccurred()
    }
}
