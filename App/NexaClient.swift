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

        var errorDescription: String? {
            switch self {
            case .noKeys: return "Nexa access keys missing"
            case .rejected(let code): return "Cloudflare Access rejected the token (HTTP \(code))"
            case .notJSON(let code, let body): return "HTTP \(code) but not the expected JSON: \(body)"
            case .http(let code, let body): return "HTTP \(code): \(body)"
            }
        }
    }

    static let base = URL(string: "https://nexa.nexline.ai")!

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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seq = (object["hseq"] ?? object["hlen"]) as? Int
        else { throw NexaError.notJSON(code, String(text.prefix(80))) }
        return "serve.py answers, history at \(seq)"
    }

    /// Sends one user turn and streams Nexa's reply events. Cancelling the consuming task closes the request.
    func chat(_ text: String) -> AsyncThrowingStream<ChatStreamParser.Event, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    var request = try self.jsonRequest("chat", body: ["text": text, "client": "phone"])
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

    /// Tells serve.py what the user actually heard before cutting in, so history keeps only that.
    func reportInterrupt(heard: String) async {
        guard var request = try? jsonRequest("chat/interrupt", body: ["heard": String(heard.prefix(4000))]) else { return }
        request.timeoutInterval = 10
        _ = try? await session.data(for: request)
    }
}
