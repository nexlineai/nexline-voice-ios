import Foundation
import UIKit

/// Where Home Assistant is reached. With an address and a long-lived access token in Settings, the app talks to
/// the house's Home Assistant directly (each kiosk customer has their own). Without them, or while that fails,
/// it goes through the kiosk (serve.py `/ha/*` with Nexa's Access token), as before.
@MainActor
enum HAClient {
    nonisolated static let urlKey = "ha.url"

    struct Direct {
        let base: URL
        let token: String
    }

    enum HAError: LocalizedError {
        case notSet
        case http(Int)
        case blocked(Int)
        case badReply

        var errorDescription: String? {
            switch self {
            case .notSet: return "Add Home Assistant's address and token in Settings"
            case .http(401): return "Home Assistant refused the token (HTTP 401)"
            case .http(let code): return "Home Assistant answered HTTP \(code)"
            case .blocked(let code): return "blocked before Home Assistant (HTTP \(code), a login page in front of it?)"
            case .badReply: return "that address didn't answer like Home Assistant"
            }
        }
    }

    /// After a direct failure the kiosk route is used for a while, so camera polling doesn't pay a timeout per frame.
    private static var directDownUntil = Date.distantPast
    private(set) static var lastProblem: String?

    /// Redirects are refused: a login page in front of Home Assistant must fail, not look like an answer.
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    static var direct: Direct? {
        guard let base = normalized(UserDefaults.standard.string(forKey: urlKey)),
              let token = Keychain.get(.haToken) else { return nil }
        return Direct(base: base, token: token)
    }

    static var configured: Bool { direct != nil || TalkModel.keysCached }

    /// "home.example.com/" → https://home.example.com
    static func normalized(_ raw: String?) -> URL? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    // MARK: Calls

    /// Every entity as Home Assistant reports it (`entity_id`, `state`, `attributes`).
    static func states() async throws -> [[String: Any]] {
        if let direct = usableDirect {
            do {
                let (data, _) = try await fetch(request(direct, "api/states"))
                guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw HAError.badReply
                }
                ok()
                return list
            } catch {
                try failed(error)
            }
        }
        let (data, code) = try await NexaClient.shared.get("ha/states")
        guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = json["states"] as? [[String: Any]]
        else { throw HAError.http(code) }
        return states
    }

    static func toggle(_ entityID: String) async throws {
        if let direct = usableDirect {
            do {
                var request = request(direct, "api/services/homeassistant/toggle")
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["entity_id": entityID])
                _ = try await fetch(request)
                ok()
                return
            } catch {
                try failed(error)
            }
        }
        try await NexaClient.shared.post("ha/toggle", json: ["entity_id": entityID])
    }

    static func snapshot(_ entityID: String) async -> UIImage? {
        if let direct = usableDirect {
            do {
                var request = request(direct, "api/camera_proxy/\(entityID)")
                request.timeoutInterval = 12
                let (data, _) = try await fetch(request)
                ok()
                return UIImage(data: data)
            } catch {
                do { try failed(error) } catch { return nil }
            }
        }
        let bust = URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000)))
        guard let result = try? await NexaClient.shared.get("ha/camera/\(entityID)", query: [bust], timeout: 12),
              result.1 == 200 else { return nil }
        return UIImage(data: result.0)
    }

    /// Settings › Test: asks `/api/` with what was typed (or what is saved).
    static func test(address: String, token: String?) async -> String {
        guard let base = normalized(address) else { return "Enter the address first, like https://home.example.com" }
        guard let token = token.flatMap({ $0.isEmpty ? nil : $0 }) ?? Keychain.get(.haToken) else {
            return "Enter the token first"
        }
        do {
            let (data, _) = try await fetch(request(Direct(base: base, token: token), "api/"))
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let message = json?["message"] as? String else { return HAError.badReply.localizedDescription }
            return "Connected: \(message)"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Plumbing

    private static var usableDirect: Direct? {
        guard Date() > directDownUntil else { return nil }
        return direct
    }

    private static func ok() {
        lastProblem = nil
    }

    /// Falls back to the kiosk when it can; otherwise the error stands.
    private static func failed(_ error: Error) throws {
        lastProblem = error.localizedDescription
        directDownUntil = Date().addingTimeInterval(30)
        guard TalkModel.keysCached else { throw error }
    }

    private static func request(_ direct: Direct, _ path: String) -> URLRequest {
        var request = URLRequest(url: direct.base.appendingPathComponent(path))
        request.setValue("Bearer \(direct.token)", forHTTPHeaderField: "Authorization")
        for (name, value) in accessHeaders(for: direct.base) ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = 15
        return request
    }

    /// A Home Assistant behind Nexline's own Cloudflare Access (ha.nexline.ai) needs the same service token as
    /// Nexa. It is only ever sent to hosts in Nexa's own domain, never to a customer's or a third party's.
    private static func accessHeaders(for url: URL) -> [String: String]? {
        guard let host = url.host?.lowercased(), let nexaHost = NexaClient.base.host?.lowercased() else { return nil }
        let parent = nexaHost.split(separator: ".").suffix(2).joined(separator: ".")
        guard host == parent || host.hasSuffix("." + parent) else { return nil }
        return NexaClient.shared.accessHeaders()
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(code) || code == 403 { throw HAError.blocked(code) }
        guard (200..<300).contains(code) else { throw HAError.http(code) }
        return (data, code)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
