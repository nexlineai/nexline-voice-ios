import AVFoundation
import Foundation

/// Deepgram streaming speech-to-text (Nova-3, English), fed with the voice engine's echo-cancelled mic
/// buffers. Same settings as the RN app: 500 ms endpointing, UtteranceEnd after 1.4 s as a backstop, and the
/// agents' names as keyterms (English only; `keywords` hard-fails on Nova-3, never send it).
///
/// `feed` runs on the audio thread; everything else on the main actor.
final class DeepgramListener: @unchecked Sendable {
    enum DeepgramError: LocalizedError {
        case noKey
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .noKey: return "Deepgram key missing"
            case .rejected(let code): return "Deepgram refused the connection (HTTP \(code)), check the key"
            }
        }
    }

    static let keyterms = ["Nexa", "Carapava", "Cara Pava", "Mamadona", "Grooveline", "Nexline", "Streamline",
                           "Mixcloud", "SoundCloud", "YouTube", "Spotify", "Google Maps"]
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let lock = NSLock()
    /// Under the lock: where the audio thread hands converted audio, and when the first sent sample was
    /// recorded (uptime), so Deepgram's stream times map back to the clock the app uses.
    private var audio: AsyncStream<Data>.Continuation?
    private var firstSampleAt: Double?
    /// Audio thread only.
    private var converter: AVAudioConverter?

    private var socket: URLSessionWebSocketTask?
    private var tasks: [Task<Void, Never>] = []

    /// Opens the stream. `onResult(text, isFinal, endsAt)` gets each result with the uptime its audio ends at.
    /// `onFail` is called once if the connection breaks (not after `stop()`).
    @MainActor
    func start(onResult: @escaping @MainActor (String, Bool, Double?) -> Void,
               onSpeechEnd: @escaping @MainActor () -> Void,
               onFail: @escaping @MainActor (String) -> Void) throws {
        stop()
        guard let key = Keychain.get(.deepgramKey) else { throw DeepgramError.noKey }
        let socket = URLSession.shared.webSocketTask(with: Self.request(key: key))
        socket.resume()
        self.socket = socket

        // Audio is sent strictly in order by one task. While the socket connects it waits here.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(400))
        lock.lock()
        audio = continuation
        firstSampleAt = nil
        lock.unlock()

        let sender = Task { @MainActor [weak self] in
            do {
                for await chunk in stream { try await socket.send(.data(chunk)) }
            } catch {
                self?.failed(socket, error, onFail)
            }
        }
        let receiver = Task { @MainActor [weak self] in
            do {
                while true {
                    let message = try await socket.receive()
                    guard let self, self.socket === socket else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    switch object["type"] as? String {
                    case "Results":
                        let channel = object["channel"] as? [String: Any]
                        let best = (channel?["alternatives"] as? [[String: Any]])?.first
                        let text = best?["transcript"] as? String ?? ""
                        let start = (object["start"] as? Double) ?? 0
                        let duration = (object["duration"] as? Double) ?? 0
                        let endsAt = self.recordedAt(start + duration)
                        onResult(text, (object["is_final"] as? Bool) ?? false, endsAt)
                        if (object["speech_final"] as? Bool) == true { onSpeechEnd() }
                    case "UtteranceEnd":
                        onSpeechEnd()
                    default:
                        continue
                    }
                }
            } catch {
                self?.failed(socket, error, onFail)
            }
        }
        tasks = [sender, receiver]
    }

    @MainActor
    func stop() {
        lock.lock()
        let old = audio
        audio = nil
        lock.unlock()
        old?.finish()
        tasks.forEach { $0.cancel() }
        tasks = []
        if let socket {
            self.socket = nil
            // Lets Deepgram finish cleanly; closing right after is fine, it stops billing either way.
            socket.send(.string(#"{"type":"CloseStream"}"#)) { _ in
                socket.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    /// Audio thread: converts a mic buffer to 16 kHz 16-bit mono and queues it for sending.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let audio = self.audio
        if audio != nil && firstSampleAt == nil {
            firstSampleAt = ProcessInfo.processInfo.systemUptime
                - Double(buffer.frameLength) / buffer.format.sampleRate
        }
        lock.unlock()
        guard let audio else { return }

        let target = Self.format
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let given = OneShot()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if given.used {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given.used = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        audio.yield(Data(bytes: samples, count: Int(out.frameLength) * 2))
    }

    /// Read-only key check for Check connection: open a stream and close it at once. Deepgram refuses a bad
    /// key before the WebSocket opens.
    static func checkKey() async throws -> String {
        guard let key = Keychain.get(.deepgramKey) else { throw DeepgramError.noKey }
        let socket = URLSession.shared.webSocketTask(with: request(key: key))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        do {
            try await socket.send(.string(#"{"type":"CloseStream"}"#))
            _ = try await socket.receive()
            return "key accepted"
        } catch {
            if let code = (socket.response as? HTTPURLResponse)?.statusCode, code != 101 {
                throw DeepgramError.rejected(code)
            }
            if socket.closeCode == .normalClosure { return "key accepted" }
            throw error
        }
    }

    // MARK: Private

    private static func request(key: String) -> URLRequest {
        // One language at a time (Settings); the names as keyterms only help English.
        let language = SpeechLanguage.current
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: language.rawValue),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "endpointing", value: "500"),
            URLQueryItem(name: "utterance_end_ms", value: "1400"),
        ] + (language == .en ? keyterms.map { URLQueryItem(name: "keyterm", value: $0) } : [])
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return request
    }

    /// Stream time (seconds since the first sent sample) → uptime.
    private func recordedAt(_ streamTime: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return firstSampleAt.map { $0 + streamTime }
    }

    @MainActor
    private func failed(_ socket: URLSessionWebSocketTask, _ error: Error, _ onFail: @MainActor (String) -> Void) {
        guard self.socket === socket else { return }
        let reason: String
        if let code = (socket.response as? HTTPURLResponse)?.statusCode, code != 101 {
            reason = DeepgramError.rejected(code).localizedDescription
        } else {
            reason = error.localizedDescription
        }
        stop()
        onFail(reason)
    }
}

/// A one-shot flag the converter's input block can set (the block may be `@Sendable`).
private final class OneShot: @unchecked Sendable {
    var used = false
}
