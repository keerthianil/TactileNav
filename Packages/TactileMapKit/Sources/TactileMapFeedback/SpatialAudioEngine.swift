import AVFoundation

// MARK: - Protocol

/// An engine that provides regular speech, HRTF-spatialized speech,
/// spatial sound-effect playback, and a click sound for landmarks.
@MainActor
public protocol SpatialAudioEngine: AnyObject {

    /// Speak the given text using the default system voice (non-spatial).
    func speak(_ text: String)

    /// Speak the given text spatialized at a 3-D position using HRTF.
    func speakSpatially(_ text: String, at position: AVAudio3DPoint)

    /// Play a previously registered spatial sound at the given position.
    ///
    /// - Parameters:
    ///   - name:     The sound name as registered via ``registerSound(name:buffer:)``.
    ///   - position: The 3-D position relative to the listener.
    ///   - volume:   Gain multiplier for the player node.
    func playSpatialSound(_ name: String, at position: AVAudio3DPoint, volume: Float)

    /// Play a short synthesized click / ping sound (880 Hz, 80 ms).
    func playClickSound()

    /// Stop all speech and spatial audio immediately.
    func stopAll()

    /// Register a preloaded buffer so it can be played by name.
    func registerSound(name: String, buffer: AVAudioPCMBuffer)
}

// MARK: - AVFoundation implementation

/// Default `SpatialAudioEngine` built on `AVAudioEngine`,
/// `AVAudioEnvironmentNode`, and `AVSpeechSynthesizer`.
///
/// Extracted from Nav_Indoor's `AudioService`.  Uses mono 22050 Hz for
/// HRTF spatialization, inverse distance attenuation with a large
/// reference distance, small-room reverb, and a boosted output volume
/// to keep spatial audio perceptible.
///
/// Public init -- NOT a singleton.
@MainActor
public final class AVSpatialAudioEngine: NSObject, SpatialAudioEngine {

    // MARK: - Core nodes

    private let audioEngine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let audioPlayerNode = AVAudioPlayerNode()

    // MARK: - Speech

    private var speechSynthesizer = AVSpeechSynthesizer()
    private let speechManager = SpeechSynthesizerManager()

    // MARK: - Click sound

    private var clickPlayerNode: AVAudioPlayerNode?
    private var clickToneBuffer: AVAudioPCMBuffer?

    // MARK: - Registered sound buffers

    private var registeredBuffers: [String: AVAudioPCMBuffer] = [:]

    // MARK: - Mono format shared across the engine

    /// Mono, float32, 22050 Hz -- required for HRTF.
    private let monoFormat: AVAudioFormat

    // MARK: - State

    private var isEngineRunning = false

    // MARK: - Initializer

    public override init() {
        monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 22050.0,
            channels: 1,
            interleaved: false
        )!

        super.init()

        configureAudioSession()
        setupInterruptionHandling()
        setupAudioEngine()
        setupClickSound()
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Playback only — this app never records. Using .playAndRecord
            // activates the mic input path which, with .defaultToSpeaker,
            // causes an audible idle/feedback buzz (very noticeable when
            // VoiceOver activates audio). .playback avoids that entirely while
            // .mixWithOthers keeps VoiceOver speech coexisting cleanly.
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            // Audio session configuration failed.
        }
    }

    // MARK: - Interruption handling

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            break
        case .ended:
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                if !audioEngine.isRunning {
                    try audioEngine.start()
                }
            } catch {
                // Recovery after interruption failed.
            }
        @unknown default:
            break
        }
    }

    // MARK: - Engine setup

    private func setupAudioEngine() {
        audioEngine.attach(environment)
        audioEngine.attach(audioPlayerNode)

        // Spatial rendering on the player node.
        audioPlayerNode.renderingAlgorithm = .HRTFHQ
        audioPlayerNode.sourceMode = .spatializeIfMono

        // Environment settings.
        environment.renderingAlgorithm = .HRTFHQ
        environment.sourceMode = .spatializeIfMono

        // Distance attenuation -- inverse model, high reference distance
        // so that nearby positions stay loud.
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 10.0
        environment.distanceAttenuationParameters.maximumDistance = 100.0
        environment.distanceAttenuationParameters.rolloffFactor = 0.3

        // Reverb -- small room, low level for clarity.
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.smallRoom)
        environment.reverbParameters.level = 0.2

        // Boost overall output.
        environment.outputVolume = 1.5

        // Wire: player -> environment (mono) -> main mixer.
        audioEngine.connect(audioPlayerNode, to: environment, format: monoFormat)
        audioEngine.connect(environment, to: audioEngine.mainMixerNode, format: nil)

        // Listener at origin, default orientation.
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)

        do {
            try audioEngine.start()
            isEngineRunning = true
        } catch {
            // Audio engine failed to start.
        }
    }

    // MARK: - Click sound setup

    private func setupClickSound() {
        let clickNode = AVAudioPlayerNode()
        clickPlayerNode = clickNode

        audioEngine.attach(clickNode)

        let clickFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        audioEngine.connect(clickNode, to: audioEngine.mainMixerNode, format: clickFormat)

        // Synthesize an 880 Hz sine wave, 80 ms long, with 5 ms fade-in/out.
        let sampleRate: Double = 44100
        let frequency: Double = 880
        let duration: Double = 0.08
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        let channelData = buffer.floatChannelData![0]
        let fadeFrames = Int(sampleRate * 0.005)

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            var sample = Float(sin(2.0 * Double.pi * frequency * time))

            if frame < fadeFrames {
                sample *= Float(frame) / Float(fadeFrames)
            } else if frame > Int(frameCount) - fadeFrames {
                sample *= Float(Int(frameCount) - frame) / Float(fadeFrames)
            }

            channelData[frame] = sample * 0.8
        }

        clickToneBuffer = buffer
    }

    // MARK: - SpatialAudioEngine conformance

    public func speak(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
        } catch {
            // Proceeding despite audio session activation failure.
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        speechSynthesizer.speak(utterance)
    }

    public func speakSpatially(_ text: String, at position: AVAudio3DPoint) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                // Fallback to non-spatial speech.
                speak(text)
                return
            }
        }

        audioPlayerNode.position = position
        audioPlayerNode.renderingAlgorithm = .HRTFHQ
        audioPlayerNode.sourceMode = .spatializeIfMono
        audioPlayerNode.volume = 1.0

        speechManager.speak(text: text, audioPlayerNode: audioPlayerNode)
    }

    public func playSpatialSound(_ name: String, at position: AVAudio3DPoint, volume: Float) {
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                return
            }
        }

        audioPlayerNode.stop()
        audioPlayerNode.reset()

        audioPlayerNode.position = position
        audioPlayerNode.renderingAlgorithm = .HRTFHQ
        audioPlayerNode.volume = volume

        guard let buffer = registeredBuffers[name] else {
            return
        }

        audioPlayerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)

        if !audioPlayerNode.isPlaying {
            audioPlayerNode.play()
        }
    }

    public func playClickSound() {
        guard let clickNode = clickPlayerNode,
              let buffer = clickToneBuffer else {
            return
        }

        clickNode.stop()
        clickNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)

        if !clickNode.isPlaying {
            clickNode.play()
        }
    }

    public func stopAll() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        speechManager.stopAllSpeech(audioPlayerNode: audioPlayerNode)

        audioPlayerNode.stop()

        clickPlayerNode?.stop()
    }

    public func registerSound(name: String, buffer: AVAudioPCMBuffer) {
        registeredBuffers[name] = buffer
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpatialAudioEngine: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        // No-op -- available for subclass or debug override.
    }

    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        // No-op -- available for subclass or debug override.
    }
}
