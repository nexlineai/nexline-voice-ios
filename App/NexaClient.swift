import Foundation
import NexlineCore

/// Nexa through serve.py on the Jetson (`nexa.nexline.ai`, behind Cloudflare Access), so the phone shares
/// one conversation with the kiosk. No fallback to the raw gateway: when this fails, the app says so.
final class NexaClient: NSObject, URLSessionTaskDelegate {
    enum NexaError: LocalizedError {
        case noKeys
        case rejected(Int)
        case notJSON(Int, String)
        case http(Int, String)
        /// A Jetson service's own reason, like "Kokoro is off on the Jetson".
        case service(String)

        var errorDescription: String? {
            switch self {
            case .noKeys: return "Nexa access keys missing"
            case .rejected(let code): return "Cloudflare Access rejected the token (HTTP \(code))"
            case .notJSON(let code, let body): return "HTTP \(code) but not the expected JSON: \(body)"
            case .http(let code, let body): return "HTTP \(code): \(body)"
            case .service(let reason): return reason
            }
        }
    }

    static let base = URL(string: "https://nexa.nexline.ai")!
    static let shared = NexaClient()

    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    /// Never follow redirects: a rejected token is a 302 to the Access login page, which would end in an
    /// HTML 200 that looks like success.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let id = Keychain.get(.nexaClientID), let secret = Keychain.get(.nexaClientSecret) else {
            throw NexaError.noKeys
        }
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return request
    }

    private func jsonRequest(_ path: String, body: [String: Any]) throws -> URLRequest {
        var request = try request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func check(_ response: URLResponse, body: @autoclosure () -> String) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(code) || code == 401 || code == 403 { throw NexaError.rejected(code) }
        guard (200..<300).contains(code) else { throw NexaError.http(code, String(body().prefix(120))) }
    }

    /// Read-only: proves the token passes Access and serve.py answers. Doesn't touch the conversation.
    func checkConnection() async throws -> String {
        var request = try request("watchdog/version")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        try Self.check(response, body: text)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // serve.py answers `{"version": N}` here (hseq/hlen in newer builds). Any JSON object proves it got past Access.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NexaError.notJSON(code, String(text.prefix(80)))
        }
        let seq = (object["hseq"] ?? object["hlen"] ?? object["version"]).map { "\($0)" } ?? "?"
        return "serve.py answers, history at \(seq)"
    }

    /// Sends one user turn and streams Nexa's reply events. Cancelling the consuming task closes the request.
    /// `image` is a JPEG data URI sent with this turn only (serve.py hands it to her vision model).
    func chat(_ text: String, image: String? = nil) -> AsyncThrowingStream<ChatStreamParser.Event, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    var body: [String: Any] = ["text": text, "client": "phone"]
                    if let image { body["image"] = image }
                    var request = try self.jsonRequest("chat", body: body)
                    request.timeoutInterval = 120
                    let (bytes, response) = try await self.session.bytes(for: request)
                    try Self.check(response, body: "")
                    var parser = ChatStreamParser()
                    for try await line in bytes.lines {
                        guard let event = parser.parse(line: line) else { continue }
                        continuation.yield(event)
                        if event == .done { break }
                    }
                    if parser.reply.isEmpty { throw NexaError.http(200, "empty reply") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    /// One message of the shared conversation (kiosk, phone, Telegram: serve.py keeps them all).
    struct HistoryMessage: Equatable {
        let fromUser: Bool
        let text: String
    }

    /// The shared conversation, oldest first. `/media/` links are made absolute so kiosk pictures load here.
    func history() async throws -> [HistoryMessage] {
        var request = try request("history")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: String(decoding: data, as: UTF8.self))
        let json = try? JSONSerialization.jsonObject(with: data)
        let list = ((json as? [String: Any])?["history"] as? [[String: Any]]) ?? (json as? [[String: Any]])
        guard let list else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NexaError.notJSON(code, String(String(decoding: data, as: UTF8.self).prefix(80)))
        }
        return list.compactMap { item in
            let role = item["role"] as? String
            guard role == "user" || role == "assistant", let content = item["content"] as? String, !content.isEmpty
            else { return nil }
            return HistoryMessage(fromUser: role == "user",
                                  text: ReplyBlocks.rewriteMediaURLs(content, base: Self.base.absoluteString))
        }
    }

    /// Read-only probe for Check connection: HTTP status and size of an endpoint's JSON, never its content.
    func probe(_ path: String) async -> String {
        do {
            var request = try request(path)
            request.timeoutInterval = 10
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data)
            let shape: String
            if let list = json as? [Any] {
                shape = "a list of \(list.count)"
            } else if let object = json as? [String: Any] {
                let parts = object.keys.sorted().prefix(4).map { key -> String in
                    if let list = object[key] as? [Any] { return "\(key): \(list.count)" }
                    return key
                }
                shape = "{" + parts.joined(separator: ", ") + "}"
            } else {
                shape = "not JSON"
            }
            return "HTTP \(code), \(shape)"
        } catch {
            return error.localizedDescription
        }
    }

    /// Loads a picture. Nexa's own media sits behind Access, so only those requests carry the token.
    func imageData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if url.host == Self.base.host {
            request = try self.request(String(url.path.dropFirst()))
            request.url = url
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            try Self.check(response, body: "")
            return data
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw NexaError.http(code, "") }
        return data
    }

    /// The Access headers, for players that fetch from serve.py themselves (the in-chat mix player).
    func accessHeaders() -> [String: String]? {
        guard let id = Keychain.get(.nexaClientID), let secret = Keychain.get(.nexaClientSecret) else { return nil }
        return ["CF-Access-Client-Id": id, "CF-Access-Client-Secret": secret]
    }

    /// A GET on serve.py (Home Assistant states, camera frames). `query` is appended as is.
    func get(_ path: String, query: [URLQueryItem] = [], range: String? = nil,
             timeout: TimeInterval = 15) async throws -> (Data, Int) {
        var request = try request(path)
        request.url = url(path, query: query)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(code) || code == 401 || code == 403 { throw NexaError.rejected(code) }
        return (data, code)
    }

    /// serve.py's address for `path`. Values are encoded by hand: URLComponents leaves "&", "=" and "+" alone,
    /// which breaks a URL passed as a value.
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let plain = Self.base.appendingPathComponent(path)
        guard !query.isEmpty, var components = URLComponents(url: plain, resolvingAgainstBaseURL: false) else { return plain }
        components.percentEncodedQueryItems = query.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: Self.unreserved))
        }
        return components.url ?? plain
    }

    /// The status of a GET without downloading the body (the mix proxy answers 503 while it is still caching).
    func status(_ path: String, query: [URLQueryItem] = [], range: String? = nil) async -> Int {
        guard var request = try? request(path) else { return 0 }
        request.url = url(path, query: query)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.timeoutInterval = 30
        guard let result = try? await session.bytes(for: request) else { return 0 }
        result.0.task.cancel()
        return (result.1 as? HTTPURLResponse)?.statusCode ?? 0
    }

    static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A POST with a JSON body on serve.py (Home Assistant switches, clearing the history).
    func post(_ path: String, json: [String: Any] = [:]) async throws {
        var request = try jsonRequest(path, body: json)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: String(decoding: data, as: UTF8.self))
    }

    /// Nexa's Kokoro voice on the Jetson: one piece as 16-bit PCM at 24 kHz (serve.py `/phone/speak`).
    func speak(_ text: String) async throws -> Data {
        var request = try jsonRequest("phone/speak", body: ["text": text, "client": "phone"])
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try Self.checkService(response, data)
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Sample-Rate") == "24000" else {
            throw NexaError.service("Kokoro sent audio at another rate")
        }
        return data
    }

    /// The Jetson's Whisper on one finished turn (16 kHz mono WAV, serve.py `/phone/transcribe`). `prompt` is the
    /// agents' names, the same list Deepgram gets.
    func transcribe(wav: Data, language: String, prompt: String) async throws -> String {
        var request = try jsonRequest("phone/transcribe", body: [
            "audio": wav.base64EncodedString(), "language": language, "prompt": prompt, "client": "phone"])
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Self.checkService(response, data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw NexaError.notJSON(200, String(String(decoding: data, as: UTF8.self).prefix(80)))
        }
        return text
    }

    /// Like `check`, but serve.py's own reason ("Whisper is off on the Jetson") becomes the error.
    private static func checkService(_ response: URLResponse, _ data: Data) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(code) { return }
        if (400..<600).contains(code), code != 401,
           let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String {
            throw NexaError.service(reason)
        }
        try check(response, body: String(decoding: data, as: UTF8.self))
    }

    /// Tells serve.py what the user actually heard before cutting in, so history keeps only that.
    func reportInterrupt(heard: String) async {
        guard var request = try? jsonRequest("chat/interrupt", body: ["heard": String(heard.prefix(4000))]) else { return }
        request.timeoutInterval = 10
        _ = try? await session.data(for: request)
    }
}
