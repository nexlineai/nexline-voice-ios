import Foundation

/// Decides when the user has finished talking, from the speech recognizer's results.
///
/// Apple's transcriber reports a volatile guess while you talk and a final result once it settles, but no
/// "end of turn" event. A turn ends when the text is final and nothing new arrived for `finalGap`, or,
/// if a volatile guess never got finalized, after `volatileGap` without any new result.
///
/// Deepgram does say when speech ended (`speech_final`, `UtteranceEnd`): `speechEnded(at:)` ends the turn at
/// once, unless it looks unfinished ("turn on the"), which waits `unfinishedGap` for more. Port of the RN
/// app's semantic endpointing gate. Background noise can keep those events away (speaker mode, 28 Oct: turns
/// ended 2.7-4.8 s after the last word), so with `sentenceGap` a finalized sentence ends the turn by itself.
///
/// Quiet is counted from the newest word: empty results and repeats of the same guess are not new speech.
public struct Endpointer: Sendable {
    public var finalGap: Double
    public var volatileGap: Double
    public var unfinishedGap: Double
    /// Quiet after a finalized text ending in `.`, `?` or `!` that ends the turn without a speech-end event;
    /// nil to wait for `finalGap`.
    public var sentenceGap: Double?

    private var finalized = ""
    private var volatile = ""
    private var lastResultAt = 0.0
    private var endHinted = false

    public init(finalGap: Double = 0.7, volatileGap: Double = 1.5, unfinishedGap: Double = 1.4,
                sentenceGap: Double? = nil) {
        self.finalGap = finalGap
        self.volatileGap = volatileGap
        self.unfinishedGap = unfinishedGap
        self.sentenceGap = sentenceGap
    }

    /// Everything heard so far in this turn.
    public var text: String { Self.join(finalized, volatile) }

    /// `at` is when the newest word in `text` ended, or when the result came if the recognizer gives no word
    /// times, in seconds on any clock that `take(at:)` also uses.
    public mutating func add(_ text: String, isFinal: Bool, at time: Double) {
        // An empty result is no new speech (Deepgram sends them while it only hears noise): it clears a guess
        // but must not hold the turn open.
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            volatile = ""
            return
        }
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
            // Talking again after the recognizer said speech ended.
            endHinted = false
        }
        lastResultAt = max(lastResultAt, time)
    }

    /// The recognizer says speech ended.
    public mutating func speechEnded(at time: Double) {
        endHinted = true
        lastResultAt = max(lastResultAt, time)
    }

    /// The finished turn, once it is over. Starts a new turn.
    public mutating func take(at now: Double) -> String? {
        let all = text
        guard !all.isEmpty else { return nil }
        let settled = volatile.trimmingCharacters(in: .whitespaces).isEmpty
        let gap: Double
        if endHinted && settled {
            gap = Self.looksUnfinished(all) ? unfinishedGap : 0
        } else if settled, let sentenceGap, let last = all.last, ".?!".contains(last) {
            gap = sentenceGap
        } else {
            gap = settled ? finalGap : volatileGap
        }
        guard now - lastResultAt >= gap else { return nil }
        reset()
        return all
    }

    public mutating func reset() {
        finalized = ""
        volatile = ""
        endHinted = false
    }

    /// Words you almost never end a finished thought on (English and Portuguese), from the RN app.
    private static let unfinishedTail: Set<String> = [
        "and", "or", "but", "so", "because", "then", "like", "uh", "um",
        "e", "ou", "mas", "porque", "então", "tipo",
        "the", "a", "an", "to", "of", "for", "with", "about", "that", "is", "was",
        "if", "when", "my", "your", "in", "on", "at", "i", "we", "you", "its",
        "o", "os", "as", "uma", "de", "da", "do", "para", "com", "que",
        "se", "quando", "meu", "minha", "no", "na", "em",
    ]

    /// True when the text trails off: a comma or dash at the end, a trail-off word, or under three words
    /// with no closing punctuation. A closing `.`, `?` or `!` never waits.
    public static func looksUnfinished(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return false }
        if ",;:…—-".contains(last) { return true }
        if ".?!".contains(last) { return false }
        let words = t.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
        guard let tail = words.last else { return false }
        if words.count < 3 { return true }
        return unfinishedTail.contains(String(tail))
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
