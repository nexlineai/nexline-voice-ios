/// Decides when the user starts talking, from mic block levels (dBFS) arriving every ~20 ms.
///
/// A block counts as speech when it is above both `minDB` and a margin over the noise floor.
/// While the bot is speaking the margin is larger, because echo cancellation leaves some residue.
/// Speech must last `holdMs` to trigger (a click or a cough doesn't), and after a trigger the
/// detector re-arms only after `releaseMs` of quiet, so one sentence is one trigger.
///
/// `strict` is for the first seconds of the bot's voice after the engine starts, while echo cancellation is
/// still settling: the line goes up by `strictExtraDB` and speech must last `strictHoldMs`.
public struct BargeInDetector: Sendable {
    public struct Config: Sendable {
        public var minDB: Float = -45
        public var marginDB: Float = 12
        public var playbackMarginDB: Float = 18
        public var holdMs: Double = 160
        public var strictExtraDB: Float = 8
        public var strictHoldMs: Double = 400
        public var releaseMs: Double = 400
        /// The floor falls at once on a quieter block and rises this slowly, so speech is not learned as noise.
        public var floorRiseDBPerSec: Float = 3
        /// Nobody talks for this long without a pause: a level that stays up is new background noise
        /// (getting into a car), so it becomes the floor instead of latching as speech forever.
        public var adaptAfterMs: Double = 6000

        public init() {}
    }

    public let config: Config
    public private(set) var noiseFloorDB: Float
    public private(set) var triggered = false
    private var aboveMs = 0.0
    private var belowMs = 0.0

    public init(config: Config = Config(), initialFloorDB: Float = -60) {
        self.config = config
        self.noiseFloorDB = initialFloorDB
    }

    public func threshold(playing: Bool, strict: Bool = false) -> Float {
        max(config.minDB, noiseFloorDB + (playing ? config.playbackMarginDB : config.marginDB)
            + (strict ? config.strictExtraDB : 0))
    }

    /// Feeds one block. Returns true once per utterance, when speech is confirmed.
    public mutating func process(levelDB: Float, durationMs: Double, playing: Bool, strict: Bool = false) -> Bool {
        if levelDB > threshold(playing: playing, strict: strict) {
            aboveMs += durationMs
            belowMs = 0
            if aboveMs >= config.adaptAfterMs {
                noiseFloorDB = levelDB - 3
                aboveMs = 0
            }
        } else {
            belowMs += durationMs
            aboveMs = 0
            learnFloor(levelDB, durationMs)
        }

        if triggered {
            if belowMs >= config.releaseMs { triggered = false }
            return false
        }
        if aboveMs >= (strict ? config.strictHoldMs : config.holdMs) {
            triggered = true
            return true
        }
        return false
    }

    private mutating func learnFloor(_ db: Float, _ ms: Double) {
        if db < noiseFloorDB {
            noiseFloorDB = db
        } else {
            noiseFloorDB = min(db, noiseFloorDB + config.floorRiseDBPerSec * Float(ms / 1000))
        }
    }
}
