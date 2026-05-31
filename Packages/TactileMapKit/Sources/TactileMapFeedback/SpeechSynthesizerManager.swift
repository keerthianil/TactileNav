import AVFoundation

/// Writes TTS output to an `AVAudioPCMBuffer` and schedules it on a
/// spatial `AVAudioPlayerNode`, enabling HRTF-spatialized speech.
///
/// Extracted from Nav_Indoor's `SpeechSynthesizerManager`.  The
/// study-specific `lastPlayedCircle` property has been removed.
///
/// ## Thread safety
/// Buffer ownership is managed on a dedicated serial queue to prevent
/// deallocation while the buffer is still being played.
public final class SpeechSynthesizerManager: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    // MARK: - Properties

    /// The underlying speech synthesizer used by `.write()`.
    public let speechSynthesizer: AVSpeechSynthesizer

    /// Completion handler called when the utterance finishes.
    private var finishCompletion: (() -> Void)?

    /// Strong reference kept alive until playback completes so that
    /// the buffer is not deallocated prematurely.
    private var currentBuffer: AVAudioPCMBuffer?

    /// Serial queue that guards `currentBuffer` access.
    private let bufferQueue = DispatchQueue(label: "TactileMapFeedback.speechBuffer", qos: .userInitiated)

    // MARK: - Initializer

    public override init() {
        self.speechSynthesizer = AVSpeechSynthesizer()
        super.init()
        self.speechSynthesizer.delegate = self
    }

    // MARK: - Public API

    /// Synthesizes `text` to a PCM buffer and schedules it on the given
    /// player node for spatial playback.
    ///
    /// - Parameters:
    ///   - text:            The text to speak.
    ///   - audioPlayerNode: A node already attached to an `AVAudioEngine`
    ///                      with a mono format (required for HRTF).
    ///   - completion:      Optional closure invoked when the utterance
    ///                      delegate fires `didFinish`.
    public func speak(
        text: String,
        audioPlayerNode: AVAudioPlayerNode,
        completion: (() -> Void)? = nil
    ) {
        // Stop any in-progress playback.
        audioPlayerNode.stop()
        audioPlayerNode.reset()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.finishCompletion = completion

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            self.speechSynthesizer.write(utterance) { [weak self] buffer in
                guard let self = self,
                      let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    return
                }

                // Validate the buffer.
                guard pcmBuffer.frameLength > 0,
                      pcmBuffer.format.channelCount > 0,
                      pcmBuffer.format.sampleRate > 0 else {
                    return
                }

                guard audioPlayerNode.engine?.isRunning == true else {
                    return
                }

                // Retain the buffer on a dedicated queue.
                self.bufferQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.currentBuffer = pcmBuffer

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }

                        guard audioPlayerNode.engine?.isRunning == true else {
                            self.bufferQueue.async { self.currentBuffer = nil }
                            return
                        }

                        let playerFormat = audioPlayerNode.outputFormat(forBus: 0)
                        let bufferToSchedule: AVAudioPCMBuffer

                        if pcmBuffer.format.channelCount != playerFormat.channelCount {
                            if let converted = self.convertBuffer(pcmBuffer, toFormat: playerFormat) {
                                bufferToSchedule = converted
                            } else {
                                self.bufferQueue.async { self.currentBuffer = nil }
                                return
                            }
                        } else {
                            bufferToSchedule = pcmBuffer
                        }

                        audioPlayerNode.scheduleBuffer(bufferToSchedule, completionHandler: nil)

                        if !audioPlayerNode.isPlaying {
                            audioPlayerNode.play()
                        }
                    }
                }
            }
        }
    }

    /// Immediately stops all speech synthesis and clears scheduled
    /// buffers on the given player node.
    public func stopAllSpeech(audioPlayerNode: AVAudioPlayerNode) {
        bufferQueue.async { [weak self] in
            self?.currentBuffer = nil
        }

        speechSynthesizer.stopSpeaking(at: .immediate)

        audioPlayerNode.stop()
        audioPlayerNode.reset()

        finishCompletion = nil
    }

    // MARK: - Buffer conversion

    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        toFormat format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: buffer.frameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if error != nil {
            return nil
        }

        return convertedBuffer
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finishCompletion?()
        finishCompletion = nil
    }
}
