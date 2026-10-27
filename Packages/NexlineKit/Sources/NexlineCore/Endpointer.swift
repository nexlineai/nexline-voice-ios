import Foundation

/// Decides when the user has finished talking, from the speech recognizer's results.
///
/// Apple's transcriber reports a volatile guess while you talk and a final result once it settles, but no
/// "end of turn" event. A turn ends when the text is final and nothing new arrived for `finalGap`, or,
/// if a volatile guess never got finalized, after `volatileGap` without any new result.
public struct Endpointer: Sendable {
    public var finalGap: Double
    public var volatileGap: Double

    private var finalized = ""
    private var volatile = ""
    private var lastResultAt = 0.0

    public init(finalGap: Double = 0.7, volatileGap: Double = 1.5) {
        self.finalGap = finalGap
        self.volatileGap = volatileGap
    }

    /// Everything heard so far in this turn.
    public var text: String { Self.join(finalized, volatile) }

    /// `at` is in seconds on any clock that `take(at:)` also uses.
    public mutating func add(_ text: String, isFinal: Bool, at time: Double) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        lastResultAt = time
    }

    /// The finished turn, once it is over. Starts a new turn.
    public mutating func take(at now: Double) -> String? {
        let all = text
        guard !all.isEmpty else { return nil }
        let gap = volatile.trimmingCharacters(in: .whitespaces).isEmpty ? finalGap : volatileGap
        guard now - lastResultAt >= gap else { return nil }
        reset()
        return all
    }

    public mutating func reset() {
        finalized = ""
        volatile = ""
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
