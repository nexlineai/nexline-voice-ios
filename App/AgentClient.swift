import Foundation
import NexlineCore

/// Carapava and Mamadona: Hermes gateways speaking OpenAI-style streaming chat (`/v1/chat/completions`), with a
/// Bearer key typed into Settings and one gateway session per chat. The stream has the same shape as serve.py's
/// (text deltas plus `{"tool", "status"}` progress lines), so `ChatStreamParser` reads both.
enum AgentClient {
    enum AgentError: LocalizedError {
        case noKey(Bot)
        case http(Bot, Int, String)
        case empty(Bot)

        var errorDescription: String? {
            switch self {
            case .noKey(let bot): return "\(bot.name)'s key is missing (Settings)"
            case .http(let bot, let code, let body): return "\(bot.name) \(code): \(body)"
            case .empty(let bot): return "empty reply from \(bot.name)"
            }
        }
    }

    /// `history` is the conversation before this turn; only the last 20 messages are sent. Past photos are not
    /// re-sent (thousands of tokens each); a note keeps the conversation coherent.
    @MainActor
    static func chat(_ bot: Bot, text: String, history: [TalkModel.Line],
                     image: String?) -> AsyncThrowingStream<ChatStreamParser.Event, Error> {
        let session = ChatStore.shared.sessionID(bot)
        let model = Prefs.model(bot)
        let past: [[String: Any]] = history
            .filter { !$0.failed && !$0.text.isEmpty }
            .suffix(20)
            .map { line -> [String: Any] in
                let content = line.imageFile == nil ? line.text : "\(line.text) [the user attached an image here]"
                return ["role": line.fromUser ? "user" : "assistant", "content": content]
            }
        let current: Any
        if let image {
            current = [
                ["type": "text", "text": text.isEmpty ? "What do you see in this image?" : text],
                ["type": "image_url", "image_url": ["url": image]],
            ]
        } else {
            current = text
        }
        let body: [String: Any] = [
            "model": model,
            "messages": past + [["role": "user", "content": current]],
            "stream": true,
        ]

        return AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    guard let url = bot.endpoint, let keyName = bot.key, let key = Keychain.get(keyName) else {
                        throw AgentError.noKey(bot)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue(session, forHTTPHeaderField: "X-Hermes-Session-Id")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    // Flaky mobile networks (driving): retry a dropped connection, but only before any text came.
                    var attempt = 0
                    while true {
                        attempt += 1
                        var parser = ChatStreamParser()
                        do {
                            let (bytes, response) = try await URLSession.shared.bytes(for: request)
                            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                            guard (200..<300).contains(code) else {
                                var text = ""
                                for try await line in bytes.lines {
                                    text += line
                                    if text.count > 160 { break }
                                }
                                throw AgentError.http(bot, code, String(text.prefix(120)))
                            }
                            for try await line in bytes.lines {
                                guard let event = parser.parse(line: line) else { continue }
                                continuation.yield(event)
                                if event == .done { break }
                            }
                            if parser.reply.isEmpty { throw AgentError.empty(bot) }
                            continuation.finish()
                            return
                        } catch let error as URLError where parser.reply.isEmpty && attempt < 3
                            && error.code != .cancelled {
                            try await Task.sleep(for: .milliseconds(600 * attempt))
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
