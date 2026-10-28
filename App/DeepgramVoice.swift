import Foundation
import NexlineCore

/// Deepgram Aura-2 streaming text-to-speech, the network fallback when xAI fails (Zé, 27 Oct: Edge's free
/// voices now need Microsoft's Sec-MS-GEC v2 token, so Deepgram replaced Edge). One WebSocket per piece:
/// Speak + Flush, 24 kHz 16-bit PCM back, "Flushed" ends it. English only.
enum DeepgramVoice {
    enum VoiceError: LocalizedError {
        case noKey
        case server(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "Deepgram key missing"
            case .server(let message): return "Deepgram: \(message)"
            }
        }
    }

    /// A warm female voice, close to Nexa's `ara` on xAI.
    static let nexaVoice = "aura-2-thalia-en"

    /// Expression tags like [laughs] are performed by xAI only; Deepgram and Kokoro would read them out.
    private static let voiceTag = try! NSRegularExpression(pattern: "\\[/?[a-z]+(?:[ ,]+[a-z]+){0,3}\\]")

    /// `text` without expression tags, for a voice that would read them out.
    static func withoutVoiceTags(_ text: String) -> String {
        voiceTag
            .stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts synthesizing at once; chunks are buffered until read.
    static func stream(_ text: String, voice: String = nexaVoice) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            guard let key = Keychain.get(.deepgramKey) else {
                continuation.finish(throwing: VoiceError.noKey)
                return
            }
            let spoken = withoutVoiceTags(text)
            guard !spoken.isEmpty else {
                continuation.finish()
                return
            }

            var components = URLComponents(string: "wss://api.deepgram.com/v1/speak")!
            components.queryItems = [
                URLQueryItem(name: "model", value: voice),
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: "24000"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 25
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()

            let worker = Task {
                do {
                    try await socket.send(.string(try json(["type": "Speak", "text": spoken])))
                    try await socket.send(.string(try json(["type": "Flush"])))
                    var decoder = PCM16Decoder()
                    var spokeAny = false
                    receiving: while true {
                        switch try await socket.receive() {
                        case .data(let bytes):
                            let samples = decoder.decode(bytes)
                            if !samples.isEmpty {
                                spokeAny = true
                                continuation.yield(samples)
                            }
                        case .string(let message):
                            let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
                            switch object?["type"] as? String {
                            case "Flushed":
                                break receiving
                            case "Warning", "Error":
                                let detail = (object?["description"] as? String) ?? (object?["err_msg"] as? String)
                                guard spokeAny else { throw VoiceError.server(detail ?? "error") }
                                break receiving
                            default:
                                continue
                            }
                        @unknown default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    if let code = (socket.response as? HTTPURLResponse)?.statusCode, code != 101 {
                        continuation.finish(throwing: VoiceError.server("HTTP \(code)"))
                    } else {
                        continuation.finish(throwing: error)
                    }
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
}
