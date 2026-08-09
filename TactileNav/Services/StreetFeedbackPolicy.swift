//
//  StreetFeedbackPolicy.swift
//  TactileNav
//
//  Haptics and speech for the Congress Square street map.
//
//  One surface, one signature, and silence off it:
//
//    road    heavy continuous buzz    intensity 1.0, sharpness 0.10, held until the finger
//            leaves — a deep rumble rather than a bright vibration, because a low sharpness
//            spreads across more of the fingertip and is easier to stay on top of.
//    empty   nothing at all
//
//  The buzz is one 100-second continuous event on an advanced player, started when the finger
//  enters a road and stopped when it leaves. It is deliberately *not* restarted per touch
//  sample: retriggering at 60 Hz turns a steady rumble into a stutter, and the gap between
//  players is audible as a break in the line.
//
//  Speech is dwell-gated and haptics are not. See `TactileSpeechChannel` for why.
//

import AVFoundation
import Foundation
import TactileMapCore
import TactileMapFeedback
import UIKit

// MARK: - The element handed to the policy

/// The minimum a feedback policy needs to know about the road under the finger.
///
/// The shared policy dispatches on `elementType` and speaks `properties.name`, so this
/// carries those and nothing else.
struct StreetSurfaceElement: TactileMapElement {
    let id: String
    let elementType: TactileElementType = .road
    let properties: TactileProperties

    /// Not used for feedback decisions; the geometry lives in `StreetMap` in content points.
    var geometry: TactileGeometry { .point(TactileCoordinate(x: 0, y: 0)) }

    init(id: String, announcement: String) {
        self.id = id
        self.properties = TactileProperties(name: announcement)
    }
}

// MARK: - Policy

/// Gives a road its buzz and its name.
///
/// Only `onEnter` is overridden; everything else — stopping, tap handling — is inherited.
@MainActor
final class StreetFeedbackPolicy: OutdoorFeedbackPolicy {

    override func onEnter(element: any TactileMapElement, touchType: TouchType) {
        guard element.elementType == .road else {
            super.onEnter(element: element, touchType: touchType)
            return
        }
        hapticEngine.start(pattern: .heavyBuzzContinuous)
        // The inherited policy only speaks for some types, and a road has to name itself.
        audioEngine.speak(element.properties.name)
    }
}

// MARK: - Speech

/// The single speech channel for the whole app.
///
/// Nothing anywhere is allowed to speak except through here, so the rules below hold
/// unconditionally rather than depending on each caller remembering them.
///
/// **Why speech is delayed and haptics are not.** A finger sweeping across a grid crosses a
/// street every few milliseconds. Announcing each one means every utterance interrupts the
/// one before it, and the user hears `"Congr—" "Hi—" "Fre—"` instead of a street name. So
/// `speak` waits `dwell` seconds and any newer request cancels the pending one: sweep across
/// six streets and you hear exactly the one you stop on. Haptics stay instantaneous, so the
/// map still feels continuous while the speech stays legible. Feeling everything and hearing
/// only what you settle on is the right division of the two channels.
///
/// **Why this synthesises its own speech instead of posting VoiceOver announcements.** A
/// posted announcement goes into VoiceOver's queue, and there is no API that empties that
/// queue. Every symptom of the old version follows from that one fact: a new surface could
/// not cut the previous name short, so names stacked up and arrived late — you would hear
/// "crossing" while your finger was already back on the lane — and leaving the screen could
/// not stop what was still waiting to be read, so a junction went on naming itself over the
/// map underneath. Synthesising here makes every one of those a single `stopSpeaking` call.
/// VoiceOver users keep their own voice and speaking rate through
/// `prefersAssistiveTechnologySettings`, which is the only thing the announcement route was
/// really buying.
@MainActor
final class TactileSpeechChannel: NSObject, SpatialAudioEngine {

    /// The one voice in the app.
    ///
    /// Shared, not one per screen. "Stop what you were saying" has to work across a screen
    /// boundary as well as inside one: when the junction close-up owned a second synthesizer,
    /// leaving it silenced one voice and left the other talking over the map underneath.
    static let shared = TactileSpeechChannel()

    /// How long a finger must rest on one surface before it is named.
    private let dwell: TimeInterval = 0.2

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingSpeech: DispatchWorkItem?
    private var pendingArrival: DispatchWorkItem?
    private var suppressedUntil: CFTimeInterval = 0
    private var hasActivatedSession = false

    /// How long to leave clear for VoiceOver to read the label of the element it has just
    /// focused, before this channel says anything of its own. See `speakArrival`.
    private let voiceOverFocusGrace: TimeInterval = 1.2

    // MARK: Arrival

    /// A screen introducing itself.
    ///
    /// **This is the only place two voices could ever talk at once, and why it is delayed.**
    /// Pushing a screen moves VoiceOver's focus, and VoiceOver reads the newly focused
    /// element's label in its own voice — that is not something an app can cancel or opt out
    /// of. So this channel waits for it to finish rather than talking over it, and the labels
    /// on the tactile surfaces are kept to a name so there is little to wait for. Everything
    /// past the name — the street count, the arms of a junction, how to explore — is said
    /// here, where it can be stopped.
    ///
    /// Cancelled outright by a finger arriving. The introduction is a courtesy; a finger on
    /// the glass is an instruction, and someone who starts exploring has heard as much of it
    /// as they wanted.
    func speakArrival(_ text: String) {
        guard !text.isEmpty else { return }
        cancelArrival()
        let delay = UIAccessibility.isVoiceOverRunning ? voiceOverFocusGrace : 0.3
        // Hold exploration speech until the introduction has had room, so the two do not
        // interleave into gibberish if a finger lands halfway through.
        suppressExploration(for: delay + 6)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingArrival = nil
            self.utter(text)
        }
        pendingArrival = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelArrival() {
        pendingArrival?.cancel()
        pendingArrival = nil
    }

    /// Whether an introduction is still waiting to be spoken. Readable so a test can check it
    /// is dropped by a finger rather than left to play underneath exploration.
    var hasArrivalPending: Bool { pendingArrival != nil }

    // MARK: Suppression

    /// Hold exploration speech for `duration`, so an entry summary is never cut in half by
    /// the first street a finger happens to land on.
    func suppressExploration(for duration: TimeInterval) {
        suppressedUntil = CACurrentMediaTime() + duration
    }

    /// Drop the hold immediately, and drop the introduction with it.
    ///
    /// A finger on the glass replaces the introduction rather than queueing behind it — which
    /// is the difference between one voice and two.
    func endSuppression() {
        suppressedUntil = 0
        cancelArrival()
    }

    private var isSuppressed: Bool { CACurrentMediaTime() < suppressedUntil }

    // MARK: SpatialAudioEngine

    /// The dwell-gated path. This is what the feedback policy calls on every surface entry.
    ///
    /// The previous name is cut off the moment a new surface is asked for, not when the new
    /// one starts speaking. What is in the air belongs to the thing the finger has already
    /// left, and letting it run to the end is what made a name arrive one surface too late.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        pendingSpeech?.cancel()
        // Checked before anything is stopped: while the entry summary holds the channel, a
        // surface entry is dropped outright rather than cutting the summary in half.
        guard !isSuppressed else { return }
        stopSpeakingNow()

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

    /// Everything stops, including whatever is mid-sentence. This is the screen-exit path.
    func stopAll() {
        suppressedUntil = 0
        cancelArrival()
        pendingSpeech?.cancel()
        pendingSpeech = nil
        stopSpeakingNow()
    }

    /// Whether an utterance is waiting out its dwell. Readable so a test can tell a
    /// suppressed channel (which drops requests) from a live one (which schedules them).
    var hasSpeechPending: Bool { pendingSpeech != nil }

    /// Whether anything is being said right now. Readable for the same reason.
    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Cancel anything queued but let whatever is mid-sentence finish. Used when a finger
    /// lifts, or moves into the blank ground between streets: cutting the current street name
    /// off at that moment is just rude.
    func cancelPending() {
        pendingSpeech?.cancel()
        pendingSpeech = nil
    }

    // MARK: Delivery

    private func stopSpeakingNow() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func utter(_ text: String) {
        prepareSession()
        stopSpeakingNow()

        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = 1.0
        if UIAccessibility.isVoiceOverRunning {
            // Speak in the user's own VoiceOver voice, at their own rate. A blind user has
            // tuned those settings to something they can work at, and a map that ignores them
            // is a map that sounds wrong on every single utterance. This is what makes owning
            // the synthesizer cost nothing next to posting announcements.
            utterance.prefersAssistiveTechnologySettings = true
        } else {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        synthesizer.speak(utterance)
    }

    /// Route speech through a mixable playback session, so it is audible alongside VoiceOver
    /// rather than silenced by it, and does not interrupt other audio.
    ///
    /// The category is re-asserted on every utterance rather than set once: the Street
    /// Crossing Audio screen installs its own session, so coming back to a map cannot be
    /// assumed to leave this one in place. Activation happens once — that is the expensive
    /// half, and it survives a category change.
    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        guard !hasActivatedSession else { return }
        hasActivatedSession = true
        try? session.setActive(true)
    }
}

// MARK: - Controller

/// What the map view talks to. Owns the policy, the haptic engine and the speech channel.
@MainActor
final class StreetFeedbackController {

    static let shared = StreetFeedbackController()

    private let speech = TactileSpeechChannel.shared
    private let haptics = CoreHapticsEngine()
    private let policy: StreetFeedbackPolicy
    private var activeIdentifier: String?

    /// The junction ding. Created on first use so the audio session is configured before its
    /// engine starts — see `startIntersectionTone`.
    private lazy var tone = ToneGenerator()
    private var toneRunning = false

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
                self?.tone.handleAppBackground()
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.haptics.handleAppForeground()
                self?.tone.handleAppForeground()
            }
        }
    }

    /// A finger has entered a road. Called only on an actual change of road, so the buzz is
    /// never restarted while a finger stays on one street — which is what keeps it a steady
    /// rumble rather than a stutter.
    func enter(identifier: String, announcement: String) {
        guard identifier != activeIdentifier else { return }
        activeIdentifier = identifier
        stopIntersectionTone()
        haptics.stopAll()
        policy.onEnter(
            element: StreetSurfaceElement(id: identifier, announcement: announcement),
            touchType: .direct)
    }

    /// A finger has entered a junction. Three cues at once, matching the overview map in the
    /// reference app: a pulsing haptic distinct from the steady road buzz, a repeating ding,
    /// and the junction spoken once. Called only on a change of junction, so the ding is not
    /// restarted every touch sample.
    func enterIntersection(identifier: String, announcement: String) {
        guard identifier != activeIdentifier else { return }
        activeIdentifier = identifier
        haptics.stopAll()
        // Slow pulse, intensity 1.0 / sharpness 0.5, 0.15 s on / 0.10 s off, looped — the
        // reference app's intersection signature, clearly not the road's continuous rumble.
        haptics.start(pattern: .intersectionPulse)
        startIntersectionTone()
        // Through the same dwell-gated channel as street names, so panning past a run of
        // junctions never stacks announcements or cuts one off mid-word.
        speech.speak(announcement)
    }

    /// The finger is over empty space — between the streets, inside a block. Silence, and no
    /// vibration, is the correct feedback: it is how a blank area reads as blank.
    func leaveAll() {
        activeIdentifier = nil
        stopIntersectionTone()
        haptics.stopAll()
        speech.cancelPending()
    }

    /// Finger lifted. Haptics and the ding stop at once; whatever is mid-sentence is allowed
    /// to finish, because cutting a street name off the instant a finger leaves is just rude.
    func stopAll() {
        activeIdentifier = nil
        stopIntersectionTone()
        haptics.stopAll()
        speech.cancelPending()
    }

    /// Leaving the screen. Everything stops, including a sentence already in flight.
    ///
    /// This is the distinction `stopAll` deliberately does not make, and missing it is what
    /// left the map still naming a street over the top of the screen that replaced it. A
    /// finger lifting and a screen going away want opposite things from the speech channel.
    func silence() {
        activeIdentifier = nil
        stopIntersectionTone()
        haptics.stopAll()
        speech.stopAll()
    }

    // MARK: Junction ding

    /// 1120 Hz, 0.16 s, repeating every 0.4 s while the finger stays on the junction — the
    /// reference app's cadence. Left running until the finger moves onto a road, onto empty
    /// space, or lifts.
    private func startIntersectionTone() {
        prepareToneSession()
        toneRunning = true
        tone.playRepeatingTone(frequency: 1120, duration: 0.16, interval: 0.4, count: 0, amplitude: 0.7)
    }

    private func stopIntersectionTone() {
        guard toneRunning else { return }
        toneRunning = false
        tone.stop()
    }

    /// Route the ding through a mixable playback session so it is audible alongside VoiceOver
    /// rather than silenced by it, and does not interrupt other audio.
    ///
    /// Re-asserted on every tone start rather than once: the Street Crossing Audio screen sets
    /// its own session, so coming back to the map cannot be assumed to leave this one in
    /// place. Both calls are idempotent, and a junction is entered rarely enough that the cost
    /// is nothing.
    private func prepareToneSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    /// A finger has arrived on the map. Ends the screen-entry hold — see `endSuppression`.
    func beginExploring() {
        speech.endSuppression()
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

    /// Screen-entry summary — see `TactileSpeechChannel.speakArrival` for the timing, which is
    /// what keeps this from landing on top of VoiceOver reading the screen it just focused.
    func announceScreenEntry(_ text: String) {
        speech.speakArrival(text)
    }
}
