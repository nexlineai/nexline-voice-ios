import Foundation

/// A word the recognizer heard and when it was said, in seconds on the caller's clock.
public struct HeardWord: Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(_ text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Decides what a sound over her voice was. Loudness alone cut her off on a cough, and on her own echo while
/// echo cancellation settled (Carapava's first reply, build 18). So a sound only pauses her: words from the user
/// cut her off, and a sound that brings no words lets her carry on from where she paused.
///
/// A word counts when it ends around the pause or later and isn't one of hers (her echo, recognized late), or
/// when it ends well after the pause, when she is silent. Sound that goes on for `sustainedCut` cuts without
/// words, so speech the recognizer can't transcribe (another language) still gets through.
public struct CutInGate: Sendable {
    public enum Action: Equatable, Sendable {
        /// Not decided yet (or not paused).
        case wait
        /// Carry on. `pausedAt` is when she was paused.
        case resume(pausedAt: Double)
        /// The user is talking: cut her off as of `pausedAt`. `words` is what confirmed it, nil for sound alone.
        case cut(pausedAt: Double, words: String?)
    }

    /// Quiet this long, with no words, and she carries on.
    public var resumeAfter = 1.0
    /// Sound this long, words or not, and she stops.
    public var sustainedCut = 1.0
    /// A dip shorter than this doesn't end a stretch of sound (the gaps between syllables).
    public var gapTolerance = 0.3
    /// Words ending this soon before the pause may be the user's first words.
    public var leadIn = 0.5
    /// Her echo can't end later than this after the pause, so any word ending later is the user's.
    public var echoTail = 0.4

    public private(set) var pausedAt: Double?
    /// Her words while paused, to tell her echo from the user.
    public private(set) var herWords: Set<String> = []
    private var lastLoudAt = 0.0
    private var loudSince = 0.0

    public init() {}

    public var isPaused: Bool { pausedAt != nil }

    /// A sound over her voice: she is paused now. `herText` is what she was saying, to tell her echo from you.
    public mutating func pause(at time: Double, herText: String) {
        pausedAt = time
        herWords = Self.vocabulary(herText)
        lastLoudAt = time
        loudSince = time
    }

    /// Every mic block while paused. `loud` means the block is over the line for the user's voice.
    public mutating func level(loud: Bool, at time: Double) -> Action {
        guard let pausedAt else { return .wait }
        if loud {
            if time - lastLoudAt > gapTolerance { loudSince = time }
            lastLoudAt = time
            if time - loudSince >= sustainedCut { return finish(.cut(pausedAt: pausedAt, words: nil)) }
            return .wait
        }
        if time - lastLoudAt >= resumeAfter { return finish(.resume(pausedAt: pausedAt)) }
        return .wait
    }

    /// Words the recognizer returned while she is paused.
    public mutating func heard(_ words: [HeardWord]) -> Action {
        guard let pausedAt else { return .wait }
        let yours = self.yours(words, pausedAt: pausedAt, herWords: herWords)
        guard !yours.isEmpty else { return .wait }
        return finish(.cut(pausedAt: pausedAt, words: yours.map(\.text).joined(separator: " ")))
    }

    /// The user's words for a pause at `pausedAt`: any word ending `echoTail` after it (she is silent by then), and
    /// words ending in the `leadIn` before it that can't be hers.
    public func yours(_ words: [HeardWord], pausedAt: Double, herWords: Set<String>) -> [HeardWord] {
        words.filter { word in
            if word.end >= pausedAt + echoTail { return true }
            return word.end >= pausedAt - leadIn && Self.isForeign(word.text, to: herWords)
        }
    }

    /// The words of `text`, as compared here.
    public static func vocabulary(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty })
    }

    /// True when `word` can't be one of `herWords` as the recognizer may have written it. A word counts as hers
    /// when it's equal, a letter off (two for long words), or part of one ("light" in "lighthouse"). Numbers and
    /// words under three letters never count against her: the recognizer writes those its own way ("1" for "one",
    /// "I am" for "I'm").
    public static func isForeign(_ word: String, to herWords: Set<String>) -> Bool {
        let w = normalized(word)
        guard w.count >= 3, !w.allSatisfy(\.isNumber) else { return false }
        return !herWords.contains { matches(w, $0) }
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        let longer = max(a.count, b.count)
        if shorter >= 4 && (a.contains(b) || b.contains(a)) { return true }
        let allowed = longer >= 8 ? 2 : (shorter >= 4 ? 1 : 0)
        return allowed > 0 && longer - shorter <= allowed && distance(Array(a), Array(b)) <= allowed
    }

    /// Edit distance (insertions, deletions, substitutions).
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    public mutating func reset() {
        pausedAt = nil
        herWords = []
    }

    private mutating func finish(_ action: Action) -> Action {
        reset()
        return action
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
