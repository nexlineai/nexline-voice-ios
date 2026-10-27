import Foundation
import NexlineCore

/// xAI streaming text-to-speech, one WebSocket per piece of text (the protocol the RN app and the kiosk use).
/// Audio arrives as 24 kHz 16-bit PCM in base64 and is handed on as float samples while it streams.
enum XAIVoice {
    enum VoiceError: LocalizedError {
        case noKey
        case server(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "xAI key missing"
            case .server(let message): return "xAI: \(message)"
            }
        }
    }

    /// Nexa's voice on the kiosk.
    static let nexaVoice = "ara"

    /// Starts synthesizing at once; chunks are buffered until read.
    static func stream(_ text: String, voice: String = nexaVoice) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            guard let key = Keychain.get(.xaiKey) else {
                continuation.finish(throwing: VoiceError.noKey)
                return
            }
            var components = URLComponents(string: "wss://api.x.ai/v1/tts")!
            components.queryItems = [
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "voice", value: voice),
                URLQueryItem(name: "codec", value: "pcm"),
                URLQueryItem(name: "sample_rate", value: "24000"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 25
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()

            let worker = Task {
                do {
                    try await socket.send(.string(try json(["type": "text.delta", "delta": text])))
                    try await socket.send(.string(try json(["type": "text.done"])))
                    var decoder = PCM16Decoder()
                    receiving: while true {
                        let object: [String: Any]?
                        switch try await socket.receive() {
                        case .string(let s): object = parse(Data(s.utf8))
                        case .data(let d): object = parse(d)
                        @unknown default: object = nil
                        }
                        guard let object else { continue }
                        switch object["type"] as? String {
                        case "audio.delta":
                            if let b64 = object["delta"] as? String, let samples = decoder.decode(base64: b64),
                               !samples.isEmpty {
                                continuation.yield(samples)
                            }
                        case "audio.done":
                            break receiving
                        case "error":
                            let message = (object["message"] as? String) ?? (object["error"] as? String) ?? "error"
                            throw VoiceError.server(message)
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                socket.cancel(with: .normalClosure, reason: nil)
            }
            continuation.onTermination = { _ in
                worker.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
