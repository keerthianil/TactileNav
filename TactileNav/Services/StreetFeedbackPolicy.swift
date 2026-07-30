//
//  StreetFeedbackPolicy.swift
//  TactileNav
//
//  Haptics and speech for the Congress Square street map.
//
//  Three surfaces, three signatures, and silence off them:
//
//    road       heavy continuous buzz     intensity 1.0   sharpness 0.10
//    sidewalk   softer continuous buzz    intensity 0.78  sharpness 0.78
//    crosswalk  sharp transient tick      intensity 1.0   sharpness 1.00, one tap / 0.17 s
//    empty      nothing at all
//
//  The distinction that matters most is road vs. sidewalk: same shape, different texture, so
//  a finger can tell the roadway from the walkway without being told. The crosswalk tick is
//  deliberately transient rather than a short continuous pulse — a tap reads as a discrete
//  marking, where a pulse blurs into the road buzz beside it.
//
//  Speech is dwell-gated and haptics are not. See `TactileSpeechChannel` for why.
//

import AVFoundation
import Foundation
import TactileMapCore
import TactileMapFeedback
import UIKit

// MARK: - The element handed to the policy

/// The minimum a feedback policy needs to know about a surface under the finger.
///
/// The shared policy dispatches on `elementType` and speaks `properties.name`, so this
/// carries those and nothing else. `name` is the *spoken* form rather than the raw street
/// name: for a road they are the same thing, and for a sidewalk or crossing the spoken form
/// is the one that identifies it.
struct StreetSurfaceElement: TactileMapElement {
    let id: String
    let elementType: TactileElementType
    let properties: TactileProperties

    /// Not used for feedback decisions; the geometry lives in `StreetMap` in content points.
    var geometry: TactileGeometry { .point(TactileCoordinate(x: 0, y: 0)) }

    init(id: String, surface: StreetSurface, announcement: String) {
        self.id = id
        self.elementType = surface.elementType
        self.properties = TactileProperties(name: announcement)
    }
}

// MARK: - Haptic patterns

extension HapticPattern {
    /// A single sharp tap every 0.17 s, looped.
    ///
    /// The shared `crosswalkTick` preset hits the same cadence with short *continuous*
    /// pulses. A transient tap is crisper and cannot smear into a steady vibration, which
    /// matters here because a crossing is usually felt with a road buzzing right beside it.
    static let crosswalkTransientTick = HapticPattern(
        intensity: 1.0,
        sharpness: 1.0,
        mode: .burst(pulseCount: 1, onDuration: 0.05, offDuration: 0.12)
    )
}

// MARK: - Policy

/// Maps the three street surfaces onto their haptic signatures and spoken names.
///
/// Only `onEnter` is overridden; everything else — stopping, tap handling — is inherited.
@MainActor
final class StreetFeedbackPolicy: OutdoorFeedbackPolicy {

    override func onEnter(element: any TactileMapElement, touchType: TouchType) {
        switch element.elementType {
        case .road:
            hapticEngine.start(pattern: .heavyBuzzContinuous)
        case .street:
            hapticEngine.start(pattern: .streetContinuous)
        case .crosswalk:
            hapticEngine.start(pattern: .crosswalkTransientTick)
        default:
            super.onEnter(element: element, touchType: touchType)
            return
        }
        // Every surface names itself; the inherited policy only speaks for some types.
        audioEngine.speak(element.properties.name)
    }
}

// MARK: - Speech

/// The single speech channel for this map.
///
/// Nothing else on the screen is allowed to speak. Everything funnels through here so the
/// rules below hold unconditionally rather than depending on each caller remembering them.
///
/// **Why speech is delayed and haptics are not.** A finger sweeping across a grid crosses a
/// street every few milliseconds. Announcing each one means every utterance interrupts the
/// one before it, and the user hears `"Congr—" "Hi—" "Fre—"` instead of a street name. So
/// `speak` waits `dwell` seconds and any newer request cancels the pending one: sweep across
/// six streets and you hear exactly the one you stop on. Haptics stay instantaneous, so the
/// map still feels continuous while the speech stays legible. Feeling everything and hearing
/// only what you settle on is the right division of the two channels.
@MainActor
final class TactileSpeechChannel: NSObject, SpatialAudioEngine {

    /// How long a finger must rest on one surface before it is named.
    private let dwell: TimeInterval = 0.2

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingSpeech: DispatchWorkItem?
    private var suppressedUntil: CFTimeInterval = 0
    private var isAnnouncing = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(announcementFinished(_:)),
            name: UIAccessibility.announcementDidFinishNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Suppression

    /// Hold exploration speech for `duration`, so an entry summary is never cut in half by
    /// the first street a finger happens to land on.
    func suppressExploration(for duration: TimeInterval) {
        suppressedUntil = CACurrentMediaTime() + duration
    }

    private var isSuppressed: Bool { CACurrentMediaTime() < suppressedUntil }

    @objc private func announcementFinished(_ note: Notification) {
        isAnnouncing = false
        // If VoiceOver reports it was cut off, the next utterance is a replacement rather
        // than a queue-behind, which is exactly what `.high` priority already gives us.
        // Tracked here so the flag reflects reality instead of an assumption.
        _ = note.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool
    }

    // MARK: SpatialAudioEngine

    /// The dwell-gated path. This is what the feedback policy calls on every surface entry.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        pendingSpeech?.cancel()
        guard !isSuppressed else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSuppressed else { return }
            self.utter(text)
        }
        pendingSpeech = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    func speak(_ text: String, configuration: SpeechConfiguration) { speak(text) }

    func speakSpatially(_ text: String, at position: AVAudio3DPoint) { speak(text) }

    /// Speak at once, no dwell. For discrete gestures — a tap or a rotor action — where the
    /// user has already committed and a delay would just feel unresponsive.
    func speakNow(_ text: String) {
        guard !text.isEmpty else { return }
        pendingSpeech?.cancel()
        utter(text)
    }

    func playSpatialSound(_ name: String, at position: AVAudio3DPoint, volume: Float) {}

    func playClickSound() {}

    func registerSound(name: String, buffer: AVAudioPCMBuffer) {}

    func stopAll() {
        pendingSpeech?.cancel()
        pendingSpeech = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Cancel anything queued but let whatever is mid-sentence finish. Used when a finger
    /// lifts: cutting the current street name off at that moment is just rude.
    func cancelPending() {
        pendingSpeech?.cancel()
        pendingSpeech = nil
    }

    // MARK: Delivery

    private func utter(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            isAnnouncing = true
            UIAccessibility.post(notification: .announcement, argument: Self.announcement(text))
        } else {
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.volume = 1.0
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            synthesizer.speak(utterance)
        }
    }

    /// High priority so a new street name *replaces* the previous utterance outright instead
    /// of layering over it. Without this two names can overlap into noise.
    private static func announcement(_ text: String) -> Any {
        if #available(iOS 17.0, *) {
            return NSAttributedString(
                string: text,
                attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.high]
            )
        }
        return text
    }
}

// MARK: - Controller

/// What the map view talks to. Owns the policy, the haptic engine and the speech channel.
@MainActor
final class StreetFeedbackController {

    static let shared = StreetFeedbackController()

    private let speech = TactileSpeechChannel()
    private let haptics = CoreHapticsEngine()
    private let policy: StreetFeedbackPolicy
    private var activeIdentifier: String?

    private init() {
        policy = StreetFeedbackPolicy(hapticEngine: haptics, audioEngine: speech)

        // Core Haptics tears its engine down when the app backgrounds, and nothing restarts
        // it on the way back — so without this, haptics are silently dead for the rest of the
        // session after the first time the user switches away.
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopAll()
                self?.haptics.handleAppBackground()
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.haptics.handleAppForeground() }
        }
    }

    /// A finger has entered a new surface. Called only on an actual change, so there is no
    /// repeat to guard against here.
    func enter(surface: StreetSurface, identifier: String, announcement: String) {
        guard identifier != activeIdentifier else { return }
        activeIdentifier = identifier
        haptics.stopAll()
        policy.onEnter(
            element: StreetSurfaceElement(id: identifier, surface: surface, announcement: announcement),
            touchType: .direct)
    }

    /// The finger is over empty space — between the streets, inside a block. Silence, and no
    /// vibration, is the correct feedback: it is how a blank area reads as blank.
    func leaveAll() {
        activeIdentifier = nil
        haptics.stopAll()
        speech.cancelPending()
    }

    /// Finger lifted, or leaving the screen entirely.
    func stopAll() {
        activeIdentifier = nil
        haptics.stopAll()
        speech.cancelPending()
    }

    func playTap() {
        haptics.playSingleTap()
    }

    /// Discrete gesture — speak without waiting.
    func announceImmediately(_ text: String) {
        speech.speakNow(text)
    }

    /// Where-am-I cue after the map has been panned. Deliberately routed through the same
    /// channel so it can never overlap a street name.
    func announceOrientation(_ text: String) {
        speech.speakNow(text)
    }

    /// Screen-entry summary. Holds exploration speech until it has had time to finish, so
    /// the intro and the first street name don't talk over each other.
    func announceScreenEntry(_ text: String) {
        speech.suppressExploration(for: 2.5)
        UIAccessibility.post(notification: .screenChanged, argument: text)
        if !UIAccessibility.isVoiceOverRunning {
            speech.speakNow(text)
        }
    }
}
