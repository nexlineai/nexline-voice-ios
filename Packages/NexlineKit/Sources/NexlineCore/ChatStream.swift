import Foundation

/// Parses the event stream from serve.py's `/chat` (server-sent events with OpenAI-style deltas).
///
/// serve.py streams text deltas as they come, tool progress lines (`{"tool", "status"}`), and at the end
/// may send the processed reply again with `replace: true` (after media rewriting), which replaces the
/// text instead of extending it.
public struct ChatStreamParser: Sendable {
    public enum Event: Equatable, Sendable {
        /// The whole reply so far.
        case text(String)
        case tool(label: String, status: String)
        case done
    }

    public private(set) var reply = ""

    public init() {}

    /// Feeds one line of the stream.
    public mutating func parse(line raw: String) -> Event? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let tool = object["tool"] as? String, let status = object["status"] as? String {
            return .tool(label: (object["label"] as? String) ?? tool, status: status)
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty
        else { return nil }
        if object["replace"] as? Bool == true {
            reply = content
        } else {
            reply += content
        }
        return .text(reply)
    }
}

/// Decodes xAI's streamed PCM (signed 16-bit little-endian mono) into float samples.
/// Keeps an odd trailing byte for the next chunk, so a sample split across chunks isn't lost.
public struct PCM16Decoder: Sendable {
    private var carry: UInt8?

    public init() {}

    public mutating func decode(base64: String) -> [Float]? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return decode(data)
    }

    public mutating func decode(_ data: Data) -> [Float] {
        var bytes = [UInt8](data)
        if let first = carry {
            bytes.insert(first, at: 0)
            carry = nil
        }
        if bytes.count % 2 == 1 { carry = bytes.removeLast() }
        var out = [Float](repeating: 0, count: bytes.count / 2)
        for i in out.indices {
            let sample = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
            out[i] = Float(sample) / 32768
        }
        return out
    }
}
