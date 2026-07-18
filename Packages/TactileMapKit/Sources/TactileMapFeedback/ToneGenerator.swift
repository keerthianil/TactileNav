import AVFoundation

/// Generates pure sine-wave tones programmatically for auditory feedback
/// (beeps, dings, tick sounds) without requiring pre-recorded audio files.
///
/// ```swift
/// let toneGen = ToneGenerator()
/// toneGen.playTone(frequency: 880, duration: 0.08)
/// toneGen.playRepeatingTone(frequency: 1000, duration: 0.05, interval: 0.17, count: 6)
/// ```
@MainActor
public final class ToneGenerator {

    // MARK: - Audio graph

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var isEngineRunning = false

    // MARK: - Repeating state

    private var repeatTimer: Timer?

    // MARK: - Initializer

    /// Creates a tone generator with an optional sample rate.
    public init(sampleRate: Double = 44100) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

        do {
            try audioEngine.start()
            isEngineRunning = true
        } catch {
            // Engine failed to start — tones will be silent.
        }
    }

    // MARK: - Single tone

    /// Play a single sine-wave tone.
    ///
    /// - Parameters:
    ///   - frequency: Tone frequency in Hz (e.g. 880 for A5).
    ///   - duration:  Duration in seconds.
    ///   - amplitude: Peak amplitude 0.0 ... 1.0.
    public func playTone(frequency: Double, duration: Double, amplitude: Float = 0.8) {
        guard isEngineRunning else { return }
        guard let buffer = synthesizeBuffer(frequency: frequency, duration: duration, amplitude: amplitude) else { return }

        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Repeating tone

    /// Play a repeating tone pattern (e.g. crosswalk tick sounds).
    ///
    /// - Parameters:
    ///   - frequency: Tone frequency in Hz.
    ///   - duration:  Duration of each individual tone in seconds.
    ///   - interval:  Time between the start of successive tones.
    ///   - count:     Number of repetitions. Pass 0 for indefinite (call ``stop()`` to end).
    ///   - amplitude: Peak amplitude 0.0 ... 1.0.
    public func playRepeatingTone(
        frequency: Double,
        duration: Double,
        interval: TimeInterval,
        count: Int = 0,
        amplitude: Float = 0.8
    ) {
        stop()

        guard isEngineRunning else { return }
        guard let buffer = synthesizeBuffer(frequency: frequency, duration: duration, amplitude: amplitude) else { return }

        var remaining = count
        let isIndefinite = count == 0

        scheduleBuffer(buffer)

        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                if !isIndefinite {
                    remaining -= 1
                    if remaining <= 0 {
                        timer.invalidate()
                        self.repeatTimer = nil
                        return
                    }
                }

                self.scheduleBuffer(buffer)
            }
        }
    }

    // MARK: - Stop

    /// Stop any playing or repeating tone.
    public func stop() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        playerNode.stop()
    }

    // MARK: - Lifecycle

    /// Call when the app enters the background to release audio resources.
    public func handleAppBackground() {
        stop()
        audioEngine.stop()
        isEngineRunning = false
    }

    /// Call when the app returns to the foreground.
    public func handleAppForeground() {
        guard !isEngineRunning else { return }
        do {
            try audioEngine.start()
            isEngineRunning = true
        } catch {
            // Engine restart failed.
        }
    }

    // MARK: - Buffer synthesis

    private func synthesizeBuffer(frequency: Double, duration: Double, amplitude: Float) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let channelData = buffer.floatChannelData![0]
        let fadeFrames = Int(sampleRate * 0.005)

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            var sample = Float(sin(2.0 * .pi * frequency * time))

            // 5 ms fade-in/out to avoid clicks
            if frame < fadeFrames {
                sample *= Float(frame) / Float(fadeFrames)
            } else if frame > Int(frameCount) - fadeFrames {
                sample *= Float(Int(frameCount) - frame) / Float(fadeFrames)
            }

            channelData[frame] = sample * amplitude
        }

        return buffer
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }
    }
}
