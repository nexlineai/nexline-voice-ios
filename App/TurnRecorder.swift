import AVFoundation
import Foundation

/// The mic as 16 kHz mono 16-bit for the last 40 s, so a finished turn can go to the Jetson's Whisper.
/// It hears the same buffers as the iPhone's recognizer.
///
/// `feed` runs on the audio thread; `wav` and `clear` on the main actor.
final class TurnRecorder: @unchecked Sendable {
    static let rate = 16_000.0
    private static let keep = 40.0
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var samples: [Int16] = []
    /// Uptime when the newest sample came in.
    private var newestAt = 0.0
    /// Audio thread only.
    private var converter: AVAudioConverter?

    func clear() {
        lock.lock()
        samples = []
        newestAt = 0
        lock.unlock()
    }

    /// Audio thread: converts a mic buffer and keeps it.
    func feed(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        let given = Flag()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let limit = Int(Self.keep * Self.rate)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        newestAt = now
        // Trimmed 5 s at a time, not on every buffer.
        if samples.count > limit + Int(5 * Self.rate) { samples.removeFirst(samples.count - limit) }
        lock.unlock()
    }

    /// The audio from `start` (uptime) up to now as a WAV file, the last `longest` seconds at most. Nil when there
    /// is less than 0.3 s.
    func wav(from start: Double, longest: Double = 30) -> Data? {
        lock.lock()
        let wanted = min(Int((newestAt - start) * Self.rate), Int(longest * Self.rate), samples.count)
        let pcm = wanted > 0 ? Array(samples.suffix(wanted)) : []
        lock.unlock()
        guard pcm.count >= Int(0.3 * Self.rate) else { return nil }
        return Self.wav(pcm)
    }

    /// `seconds` of silence as a WAV file (Check connection asks Whisper with it).
    static func silence(seconds: Double) -> Data {
        wav([Int16](repeating: 0, count: Int(seconds * rate)))
    }

    private static func wav(_ pcm: [Int16]) -> Data {
        var data = Data(capacity: 44 + pcm.count * 2)
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        put("RIFF"); put32(36 + bytes); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        put("data"); put32(bytes)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
