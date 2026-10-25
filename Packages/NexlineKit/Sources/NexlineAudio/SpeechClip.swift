#if os(iOS)
import AVFoundation

/// Renders text with the on-device voice into `VoiceEngine.playbackFormat` buffers, so audio
/// tests need no network and no keys.
public final class SpeechClip: @unchecked Sendable {
    public enum ClipError: Error {
        case converter
        case nothingRendered
    }

    private let synth = AVSpeechSynthesizer()
    // All state below is touched only on this queue.
    private let queue = DispatchQueue(label: "com.nexlineai.voice.speechclip")
    private var buffers: [AVAudioPCMBuffer] = []
    private var converter: AVAudioConverter?
    private var received = 0
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>?

    public init() {}

    public func render(_ text: String, language: String = "en-US") async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.buffers = []
                self.converter = nil
                self.received = 0
                self.continuation = cont
                // No buffer at all within 10 s: the voice is missing or synthesis failed silently.
                self.queue.asyncAfter(deadline: .now() + 10) {
                    if self.received == 0 { self.finish(ClipError.nothingRendered) }
                }
                DispatchQueue.main.async {
                    self.synth.write(utterance) { buffer in
                        self.queue.async { self.receive(buffer) }
                    }
                }
            }
        }
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard continuation != nil, let pcm = buffer as? AVAudioPCMBuffer else { return }
        // An empty buffer marks the end of the utterance.
        guard pcm.frameLength > 0 else {
            finish(nil)
            return
        }
        do {
            buffers.append(try convert(pcm))
        } catch {
            finish(error)
            return
        }
        received += 1
        // Synthesis runs faster than real time, so a second without a buffer means it is done
        // (in case the empty end marker never comes).
        let mark = received
        queue.asyncAfter(deadline: .now() + 1) {
            if self.received == mark { self.finish(nil) }
        }
    }

    private func finish(_ error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let error {
            cont.resume(throwing: error)
        } else if buffers.isEmpty {
            cont.resume(throwing: ClipError.nothingRendered)
        } else {
            cont.resume(returning: buffers)
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let target = VoiceEngine.playbackFormat
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { throw ClipError.converter }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw ClipError.converter
        }
        var fed = false
        var error: NSError?
        // `.noDataNow` (not end of stream) keeps the resampler's state between buffers.
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? ClipError.converter }
        return output
    }
}
#endif
