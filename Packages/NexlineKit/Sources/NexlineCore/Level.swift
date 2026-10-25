import Foundation

/// Audio level helpers in dBFS (0 dB = full scale).
public enum Level {
    /// What silence reads as, so log10(0) never reaches the UI.
    public static let silenceDB: Float = -100

    /// RMS level of a block of mono float samples.
    public static func rmsDB(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return silenceDB }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return db(fromAmplitude: (sum / Float(samples.count)).squareRoot())
    }

    public static func rmsDB(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rmsDB($0) }
    }

    public static func db(fromAmplitude amplitude: Float) -> Float {
        guard amplitude > 0 else { return silenceDB }
        return max(silenceDB, 20 * log10(amplitude))
    }
}

/// Mean and peak of a run of block levels.
public struct LevelStats: Sendable {
    public private(set) var count = 0
    public private(set) var peakDB = Level.silenceDB
    private var powerSum: Double = 0

    public init() {}

    public mutating func add(_ db: Float) {
        count += 1
        peakDB = max(peakDB, db)
        powerSum += pow(10, Double(db) / 10)
    }

    /// Averaged as power, not as dB, so loud blocks weigh what they should.
    public var meanDB: Float {
        guard count > 0 else { return Level.silenceDB }
        return max(Level.silenceDB, Float(10 * log10(powerSum / Double(count))))
    }
}
