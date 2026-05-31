import AVFoundation

/// A registry of named sound-effect assets that can be preloaded into
/// `AVAudioPCMBuffer`s for low-latency spatial playback.
///
/// ```swift
/// let registry = SoundRegistry()
/// registry.register(name: "elevator", resource: "elevator", extension: "mp3")
/// registry.preloadAll(format: monoFormat)
///
/// if let buf = registry.buffer(for: "elevator") {
///     playerNode.scheduleBuffer(buf)
/// }
/// ```
@MainActor
public final class SoundRegistry {

    // MARK: - Storage

    /// URL for each registered sound name.
    private var registeredSounds: [String: URL] = [:]

    /// Preloaded (and optionally format-converted) buffers keyed by name.
    private var preloadedBuffers: [String: AVAudioPCMBuffer] = [:]

    // MARK: - Initializer

    public init() {}

    // MARK: - Registration

    /// Register a sound effect by file URL.
    ///
    /// - Parameters:
    ///   - name: The lookup key used later in ``buffer(for:)``.
    ///   - url:  The local file URL of the audio asset.
    public func register(name: String, url: URL) {
        registeredSounds[name] = url
    }

    /// Register a sound effect from a bundle resource.
    ///
    /// - Parameters:
    ///   - name:     The lookup key.
    ///   - resource: The resource file name (without extension).
    ///   - ext:      The file extension (e.g., `"mp3"`).
    ///   - bundle:   The bundle containing the resource.  Defaults to `.main`.
    public func register(name: String, resource: String, extension ext: String, bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: resource, withExtension: ext) else {
            return
        }
        registeredSounds[name] = url
    }

    // MARK: - Buffer access

    /// Returns the preloaded buffer for the given name, or `nil` if the
    /// name has not been registered or `preloadAll` has not been called.
    public func buffer(for name: String) -> AVAudioPCMBuffer? {
        preloadedBuffers[name]
    }

    /// The names of all currently registered sounds.
    public var registeredNames: [String] {
        Array(registeredSounds.keys)
    }

    // MARK: - Preloading

    /// Reads every registered sound file into memory and converts it to
    /// the target format (typically mono 22050 Hz for HRTF spatialization).
    ///
    /// Call this once after all sounds are registered and the audio engine
    /// format is known.
    ///
    /// - Parameter format: The target `AVAudioFormat`.  Buffers whose
    ///   native format already matches are stored as-is; others are
    ///   converted via `AVAudioConverter`.
    public func preloadAll(format: AVAudioFormat) {
        for (name, url) in registeredSounds {
            guard let buffer = loadAndConvert(url: url, targetFormat: format) else {
                continue
            }
            preloadedBuffers[name] = buffer
        }
    }

    // MARK: - Internal helpers

    private func loadAndConvert(url: URL, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return nil
        }

        // Read the entire file into a buffer using its native format.
        guard let fileBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            return nil
        }

        do {
            try file.read(into: fileBuffer)
        } catch {
            return nil
        }

        // If the native format already matches, return as-is.
        if file.processingFormat.channelCount == targetFormat.channelCount &&
           file.processingFormat.sampleRate == targetFormat.sampleRate {
            return fileBuffer
        }

        // Convert to the target format.
        guard let converter = AVAudioConverter(
            from: file.processingFormat,
            to: targetFormat
        ) else {
            return nil
        }

        let sampleRateRatio = targetFormat.sampleRate / file.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(file.length) * sampleRateRatio) + 100

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        var error: NSError?

        // Use a reference type to avoid a Swift concurrency warning about
        // capturing a mutable `var` in a sendable closure.
        final class InputState { var hasData = true }
        let state = InputState()

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if state.hasData {
                state.hasData = false
                outStatus.pointee = .haveData
                return fileBuffer
            }
            outStatus.pointee = .endOfStream
            return nil
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if error != nil {
            return nil
        }

        return convertedBuffer
    }
}
