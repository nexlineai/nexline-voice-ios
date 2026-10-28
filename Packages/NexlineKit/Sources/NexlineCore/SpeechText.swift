import Foundation

/// Turns a bot reply into what the voice says. Port of the RN app's `stripMarkdown` and pause handling.
///
/// Lowercase expression tags (`[laughing softly]`, `[whisper]`) pass through: xAI voices them.
/// Pause-like tags become real silence, because xAI stutters on them or reads them out.
public enum SpeechText {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case silence(ms: Int)
    }

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Applied in order, as (pattern, template).
    private static let rules: [(NSRegularExpression, String)] = [
        (re("<think>[\\s\\S]*?</think>"), ""),
        (re("```[\\s\\S]*?```"), ""),
        (re("`([^`]+)`"), "$1"),
        (re("^#+\\s+", .anchorsMatchLines), ""),
        (re("[*_]{1,2}([^*_]+)[*_]{1,2}"), "$1"),
        // Images serve.py saved: never spoken (the RN app read the alt text with a stray "!").
        (re("!\\[[^\\]]*\\]\\([^)]+\\)"), ""),
        (re("\\[([^\\]]+)\\]\\([^)]+\\)"), "$1"),
        // CAMERA:, [ha:device:entity] and OPEN: markers drive UI, never speech.
        (re("^\\s*CAMERA:camera\\.[a-z0-9_]+\\s*$", [.anchorsMatchLines, .caseInsensitive]), ""),
        (re("\\[ha:[a-z]+:[\\w.]+(?::\\d+)?\\]", .caseInsensitive), ""),
        (re("^\\s*OPEN:[a-z]+(?::.*)?$", [.anchorsMatchLines, .caseInsensitive]), ""),
        // Hermes's MEDIA:<path> marks a file it made, not words (Carapava's was read out, build 18).
        (re("\\bMEDIA:\\S+"), ""),
        // Status asides the model invents ("[Done]"): real expression tags are lowercase.
        (re("\\[[A-Z][^\\]\\n]{0,60}\\]"), ""),
        (re("https?://\\S+"), ""),
        (re("^[-*>]\\s+", .anchorsMatchLines), ""),
        (re("[\\x{1F300}-\\x{1FAFF}\\x{2600}-\\x{27BF}]"), ""),
        (re("\\n{3,}"), "\n\n"),
    ]

    private static let pauseTag = re(
        "\\[[^\\]\\n]{0,40}?(?:pause|pausa|breath|silence|beat)[^\\]\\n]{0,40}?\\]", .caseInsensitive)

    public static func clean(_ text: String) -> String {
        var s = text
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cleaned text split into what to synthesize and silences for pause tags.
    public static func segments(_ text: String) -> [Segment] {
        let s = clean(text)
        var out: [Segment] = []
        var pos = s.startIndex
        func pushText(_ part: Substring) {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.text(t)) }
        }
        for match in pauseTag.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let range = Range(match.range, in: s) else { continue }
            pushText(s[pos..<range.lowerBound])
            let tag = s[range].lowercased()
            out.append(.silence(ms: tag.contains("long") || tag.contains("slow") ? 900 : 500))
            pos = range.upperBound
        }
        pushText(s[pos...])
        return out
    }
}

/// Cuts a streaming reply into speakable pieces. Port of the RN app's `createSentenceFlusher`.
///
/// The first piece flushes at the earliest soft boundary (comma, colon, dash) or after ~50 characters, so
/// the voice starts early; later pieces wait for sentence ends. A cut never lands inside an open `[tag]`,
/// because a torn tag reaches xAI as text and gets read out.
///
/// The first piece is at least `minFirstPiece` characters: a lone "Here," played in 0.4 s and then left a
/// second of silence while the rest synthesized (build 15).
public struct SentenceFlusher: Sendable {
    public static let minFirstPiece = 10

    /// UTF-16 offset into the reply of what was already handed out (the RN app's JS indices).
    private var spokenLength = 0
    private var spokenAny = false

    public init() {}

    private static let soft = try! NSRegularExpression(pattern: "[,;:—-][\")\\]]?\\s")
    private static let hard = try! NSRegularExpression(pattern: "[.!?…]+[\"')\\]]?\\s")

    /// Feeds the whole reply so far. Returns the next piece to speak, if one is ready.
    public mutating func take(_ fullText: String, final: Bool) -> String? {
        let all = fullText as NSString
        let start = min(spokenLength, all.length)
        let pending = all.substring(from: start) as NSString
        var lastEnd = 0

        if final {
            lastEnd = pending.length
        } else if !spokenAny {
            let long = { (end: Int) in
                pending.substring(to: end).trimmingCharacters(in: .whitespaces).count >= Self.minFirstPiece
            }
            for end in Self.ends(Self.soft, pending) where long(end) && Self.cutIsSafe(pending, end) { lastEnd = end }
            for end in Self.ends(Self.hard, pending) where long(end) && Self.cutIsSafe(pending, end) {
                lastEnd = max(lastEnd, end)
            }
            if lastEnd == 0 && pending.length >= 50 {
                var space = pending.range(of: " ", options: .backwards).location
                while space != NSNotFound && space > 20 && !Self.cutIsSafe(pending, space + 1) {
                    space = pending.range(of: " ", options: .backwards,
                                          range: NSRange(location: 0, length: space)).location
                }
                if space != NSNotFound && space > 20 { lastEnd = space + 1 }
            }
        } else {
            for end in Self.ends(Self.hard, pending) where Self.cutIsSafe(pending, end) { lastEnd = end }
        }

        guard lastEnd > 0 else { return nil }
        spokenLength = start + lastEnd
        let piece = pending.substring(to: lastEnd)
        guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        spokenAny = true
        return piece
    }

    private static func ends(_ regex: NSRegularExpression, _ text: NSString) -> [Int] {
        regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .map { $0.range.location + $0.range.length }
    }

    private static func cutIsSafe(_ text: NSString, _ end: Int) -> Bool {
        var open = 0
        for i in 0..<end {
            switch text.character(at: i) {
            case 0x5B: open += 1                     // [
            case 0x5D where open > 0: open -= 1      // ]
            default: break
            }
        }
        return open == 0
    }
}

/// What the user heard of a reply when they cut in. Port of the RN app's `spokenThisTurn`:
/// pieces that finished playing count whole, the playing one by the share of its time that passed.
public struct HeardTimeline: Sendable {
    private struct Piece: Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    private var pieces: [Piece] = []

    public init() {}

    /// `start` and `end` are when the piece's audio plays, in seconds on any one clock.
    public mutating func add(_ text: String, start: Double, end: Double) {
        pieces.append(Piece(text: text, start: start, end: end))
    }

    public func heard(at now: Double) -> String {
        var parts: [String] = []
        for piece in pieces {
            if piece.end <= now {
                parts.append(piece.text)
            } else if piece.start < now {
                let share = min(1, max(0, (now - piece.start) / max(0.001, piece.end - piece.start)))
                let words = piece.text.split(whereSeparator: \.isWhitespace)
                let count = Int((Double(words.count) * share).rounded())
                if count > 0 { parts.append(words.prefix(count).joined(separator: " ")) }
                break
            } else {
                break
            }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when everything queued has played, so a cut-in there isn't one.
    public func fullyPlayed(at now: Double) -> Bool {
        pieces.allSatisfy { $0.end <= now }
    }

    /// What she was saying at `time`: the piece playing then and the one before it (her echo can lag).
    public func text(around time: Double) -> String {
        guard let index = pieces.lastIndex(where: { $0.start <= time }) else { return "" }
        return pieces[max(0, index - 1)...index].map(\.text).joined(separator: " ")
    }

    /// Playback was held at `time` for `seconds`: everything still to play then moves later. A piece cut in
    /// half moves whole, so the share of it heard by any later time stays right.
    public mutating func shift(after time: Double, by seconds: Double) {
        pieces = pieces.map { piece in
            guard piece.end > time else { return piece }
            return Piece(text: piece.text, start: piece.start + seconds, end: piece.end + seconds)
        }
    }
}
