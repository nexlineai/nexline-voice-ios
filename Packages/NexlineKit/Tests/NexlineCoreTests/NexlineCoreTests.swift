import Foundation
import XCTest
@testable import NexlineCore

final class LevelTests: XCTestCase {
    func testSilenceAndEmptyReadAsFloor() {
        XCTAssertEqual(Level.rmsDB([Float](repeating: 0, count: 512)), Level.silenceDB)
        XCTAssertEqual(Level.rmsDB([]), Level.silenceDB)
    }

    func testFullScaleSineIsMinus3dB() {
        let sine = (0..<4800).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        XCTAssertEqual(Level.rmsDB(sine), -3.01, accuracy: 0.05)
    }

    func testHalfScaleIsMinus6dB() {
        XCTAssertEqual(Level.rmsDB([Float](repeating: 0.5, count: 256)), -6.02, accuracy: 0.01)
    }

    func testStatsAverageAsPower() {
        var stats = LevelStats()
        stats.add(-10)
        stats.add(Level.silenceDB)
        XCTAssertEqual(stats.meanDB, -13.01, accuracy: 0.05)
        XCTAssertEqual(stats.peakDB, -10)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(LevelStats().meanDB, Level.silenceDB)
    }
}

final class BargeInDetectorTests: XCTestCase {
    private let blockMs = 20.0

    /// Feeds `ms` of one level and returns when it triggered, in ms from the start of this call.
    private func feed(_ detector: inout BargeInDetector, db: Float, ms: Double, playing: Bool = false) -> [Double] {
        var hits: [Double] = []
        var t = 0.0
        while t < ms {
            t += blockMs
            if detector.process(levelDB: db, durationMs: blockMs, playing: playing) { hits.append(t) }
        }
        return hits
    }

    func testSpeechTriggersOnceAfterHold() {
        var d = BargeInDetector()
        XCTAssertEqual(feed(&d, db: -60, ms: 1000), [])
        XCTAssertEqual(feed(&d, db: -20, ms: 1000), [160])
    }

    func testShortClickDoesNotTrigger() {
        var d = BargeInDetector()
        _ = feed(&d, db: -60, ms: 1000)
        XCTAssertEqual(feed(&d, db: -10, ms: 100), [])
        XCTAssertEqual(feed(&d, db: -60, ms: 500), [])
    }

    func testRearmsOnlyAfterRelease() {
        var d = BargeInDetector()
        _ = feed(&d, db: -60, ms: 1000)
        XCTAssertEqual(feed(&d, db: -20, ms: 300), [160])
        XCTAssertEqual(feed(&d, db: -60, ms: 200), [])  // a pause shorter than the release
        XCTAssertEqual(feed(&d, db: -20, ms: 300), [])  // is still the same utterance
        XCTAssertEqual(feed(&d, db: -60, ms: 500), [])
        XCTAssertEqual(feed(&d, db: -20, ms: 300), [160])
    }

    func testEchoResidueWhilePlayingStaysBelowTheLine() {
        var d = BargeInDetector()
        _ = feed(&d, db: -60, ms: 1000)
        XCTAssertEqual(feed(&d, db: -48, ms: 3000, playing: true), [])
        XCTAssertEqual(feed(&d, db: -20, ms: 300, playing: true), [160])
    }

    func testSteadyNewNoiseBecomesTheFloor() {
        var d = BargeInDetector()
        _ = feed(&d, db: -60, ms: 1000)
        XCTAssertEqual(feed(&d, db: -35, ms: 8000), [160])  // one false start, then it adapts
        XCTAssertEqual(d.noiseFloorDB, -35, accuracy: 0.01)
        XCTAssertEqual(feed(&d, db: -35, ms: 5000), [])
        XCTAssertEqual(feed(&d, db: -15, ms: 300), [160])   // speech over the new noise still counts
    }
}
