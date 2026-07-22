//
//  PortlandFeedbackManager.swift
//  TactileNav
//
//  Orchestrates the non-visual feedback for the Congress Square map while a finger
//  explores it. Haptics run on the TactileMapKit package's `CoreHapticsEngine`; the
//  traffic rumble + earcons run on `TrafficAudioEngine`; speech goes to VoiceOver via
//  `.announcement` (so it never fights VoiceOver's own audio) or `AVSpeechSynthesizer`
//  when VoiceOver is off. Exactly one continuous feedback stream plays at a time —
//  every start first stops the previous, so switching features can never pile up.
//

import Foundation
import UIKit
import AVFoundation
import TactileMapFeedback

@MainActor
final class PortlandFeedbackManager {

    static let shared = PortlandFeedbackManager()

    private let haptics = CoreHapticsEngine()          // from the TactileMapKit package
    private let audio = TrafficAudioEngine.shared
    private let synthesizer = AVSpeechSynthesizer()
    private var crosswalkTickTimer: Timer?

    private init() { audio.activate() }

    // MARK: - Feature feedback

    func startFeedback(for feature: PortlandMapFeature, trafficLevel: TrafficLevel?) {
        stopAllFeedback()

        switch feature.featureType {
        case .corridor:
            let level = trafficLevel ?? .moderate
            // Road buzz: heavier traffic → stronger, deeper vibration (perceivable congestion).
            haptics.start(pattern: HapticPattern(
                intensity: level.hapticIntensity, sharpness: 0.1,
                mode: .continuous(duration: 100)))
            audio.startRumble(hz: level.rumbleHz, amplitude: 0.25)

        case .intersection:
            haptics.start(pattern: .intersectionPulse)

        case .landmark:
            haptics.start(pattern: .landmarkFastPulse)

        case .sidewalk:
            haptics.start(pattern: .streetContinuous)

        case .crosswalk:
            haptics.start(pattern: .crosswalkTick)
            startCrosswalkTicks()
        }
    }

    func stopAllFeedback() {
        haptics.stopAll()
        audio.stopRumble()
        crosswalkTickTimer?.invalidate()
        crosswalkTickTimer = nil
    }

    func playSingleTap() { haptics.playSingleTap() }

    /// Distinct haptic that marks a *traffic-signal state change* — deliberately different
    /// from the road-traffic rumble (audio) and the APS vibrotactile arrow (sustained
    /// pulse): a quick double tap when WALK begins, a single tap when clearance begins.
    func playSignalTransition(toWalk: Bool) {
        haptics.playSingleTap()
        if toWalk {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.haptics.playSingleTap()
            }
        }
    }

    private func startCrosswalkTicks() {
        crosswalkTickTimer?.invalidate()
        crosswalkTickTimer = Timer.scheduledTimer(withTimeInterval: 0.17, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.audio.playBeep(hz: 820, seconds: 0.012, amplitude: 0.35) }
        }
    }

    // MARK: - Speech

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        } else {
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            let u = AVSpeechUtterance(string: text)
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
            synthesizer.speak(u)
        }
    }

    // MARK: - Lifecycle

    func handleAppBackground() { haptics.handleAppBackground(); stopAllFeedback() }
    func handleAppForeground() { haptics.handleAppForeground() }
}
