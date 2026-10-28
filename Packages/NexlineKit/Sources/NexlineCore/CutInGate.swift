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
    private var herWords: Set<String> = []
    private var lastLoudAt = 0.0
    private var loudSince = 0.0

    public init() {}

    public var isPaused: Bool { pausedAt != nil }

    /// A sound over her voice: she is paused now. `herText` is what she was saying, to tell her echo from you.
    public mutating func pause(at time: Double, herText: String) {
        pausedAt = time
        herWords = Set(Self.words(herText))
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
        let yours = words.filter { word in
            guard word.end >= pausedAt - leadIn else { return false }
            return word.end >= pausedAt + echoTail || !herWords.contains(Self.normalized(word.text))
        }
        guard !yours.isEmpty else { return .wait }
        return finish(.cut(pausedAt: pausedAt, words: yours.map(\.text).joined(separator: " ")))
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

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty }
    }
}
