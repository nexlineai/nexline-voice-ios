import AVFoundation
import CryptoKit
import Foundation
import NexlineAudio

/// Microsoft Edge's free read-aloud voices, the first fallback when xAI fails. Port of the RN app's
/// `edgeTts.ts`. Edge only sends MP3, so each piece is downloaded whole, decoded, then handed on.
enum EdgeVoice {
    enum EdgeError: LocalizedError {
        case noAudio
        case decode

        var errorDescription: String? {
            switch self {
            case .noAudio: return "Edge sent no audio"
            case .decode: return "Edge audio couldn't be decoded"
            }
        }
    }

    static let voice = "en-US-AvaMultilingualNeural"
    /// Not a secret: the public constant every Edge read-aloud client sends (edge-tts and others ship it).
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    /// Microsoft rejects stale Edge versions with a 403. Bump it if 403s show up.
    private static let edgeVersion = "143.0.3650.75"

    static func stream(_ text: String) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    let mp3 = try await synthesize(text)
                    try Task.checkCancellation()
                    continuation.yield(try decode(mp3))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    private static func synthesize(_ text: String) async throws -> Data {
        var components = URLComponents(
            string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        components.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "Sec-MS-GEC", value: secMsGec()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-\(edgeVersion)"),
            URLQueryItem(name: "ConnectionId", value: requestID()),
        ]
        let major = edgeVersion.split(separator: ".").first ?? "143"
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0",
            forHTTPHeaderField: "User-Agent")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        return try await withTaskCancellationHandler {
            let stamp = timestamp()
            let config = #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
            try await socket.send(.string(
                "X-Timestamp:\(stamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n\(config)"))
            let ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
                + "<voice name='\(voice)'>\(escapeXML(text))</voice></speak>"
            try await socket.send(.string(
                "X-RequestId:\(requestID())\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(stamp)\r\nPath:ssml\r\n\r\n\(ssml)"))

            var audio = Data()
            while true {
                switch try await socket.receive() {
                case .string(let message):
                    if message.contains("Path:turn.end") {
                        guard !audio.isEmpty else { throw EdgeError.noAudio }
                        return audio
                    }
                case .data(let frame):
                    // A binary frame: 2-byte big-endian header length, the headers, then the audio.
                    let bytes = [UInt8](frame)
                    guard bytes.count > 2 else { continue }
                    let headerEnd = 2 + (Int(bytes[0]) << 8 | Int(bytes[1]))
                    guard bytes.count > headerEnd else { continue }
                    let header = String(decoding: bytes[2..<headerEnd], as: UTF8.self)
                    if header.contains("Path:audio") { audio.append(contentsOf: bytes[headerEnd...]) }
                @unknown default:
                    continue
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// MP3 → 24 kHz mono float samples, through a temporary file (AVAudioFile reads MP3 from files only).
    private static func decode(_ mp3: Data) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edge-\(UUID().uuidString).mp3")
        try mp3.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let target = VoiceEngine.playbackFormat
        guard file.length > 0,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length))
        else { throw EdgeError.decode }
        try file.read(into: input)

        guard let converter = AVAudioConverter(from: input.format, to: target) else { throw EdgeError.decode }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw EdgeError.decode
        }
        let given = OneShot()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if given.used {
                inputStatus.pointee = .endOfStream
                return nil
            }
            given.used = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else {
            throw error ?? EdgeError.decode
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Sec-MS-GEC: SHA-256 of the Windows file time (in 100 ns ticks, rounded down to 5 minutes) followed by
    /// the client token. Built as "<seconds>0000000" like the RN app, so no big multiplication is needed.
    private static func secMsGec() -> String {
        var seconds = Int64(Date().timeIntervalSince1970) + 11_644_473_600
        seconds -= seconds % 300
        let digest = SHA256.hash(data: Data("\(seconds)0000000\(trustedClientToken)".utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func requestID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
