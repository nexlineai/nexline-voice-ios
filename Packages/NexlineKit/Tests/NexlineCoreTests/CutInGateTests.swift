import XCTest
@testable import NexlineCore

final class CutInGateTests: XCTestCase {
    /// Mic blocks every 20 ms from `from` to `to`.
    private func blocks(_ gate: inout CutInGate, loud: Bool, from: Double, to: Double) -> CutInGate.Action {
        var t = from
        while t < to - 0.0001 {
            let action = gate.level(loud: loud, at: t)
            if action != .wait { return action }
            t += 0.02
        }
        return .wait
    }

    func testACoughPausesHerAndSheCarriesOn() {
        var gate = CutInGate()
        gate.pause(at: 10, herText: "There was a lighthouse keeper")
        XCTAssertEqual(blocks(&gate, loud: true, from: 10, to: 10.3), .wait)
        XCTAssertEqual(blocks(&gate, loud: false, from: 10.3, to: 11.2), .wait)
        XCTAssertEqual(blocks(&gate, loud: false, from: 11.2, to: 11.4), .resume(pausedAt: 10))
        XCTAssertFalse(gate.isPaused)
    }

    func testYourWordsCutHerOff() {
        var gate = CutInGate()
        gate.pause(at: 10, herText: "One. Two. Three.")
        XCTAssertEqual(gate.heard([HeardWord("Stop.", start: 9.8, end: 10.2)]), .cut(pausedAt: 10, words: "Stop."))
    }

    func testHerOwnEchoRecognizedLateIsNotYou() {
        var gate = CutInGate()
        gate.pause(at: 10, herText: "I'm good, how are you?")
        // Her words, recognized from the echo just before the pause.
        XCTAssertEqual(gate.heard([HeardWord("I'm", start: 9.6, end: 9.8), HeardWord("good,", start: 9.8, end: 10.1)]),
                       .wait)
        // Older words don't count either, hers or not.
        XCTAssertEqual(gate.heard([HeardWord("hello", start: 8, end: 8.4)]), .wait)
        XCTAssertTrue(gate.isPaused)
        // A word of hers said well after the pause is the user's: she is silent then.
        XCTAssertEqual(gate.heard([HeardWord("good", start: 10.4, end: 10.7)]), .cut(pausedAt: 10, words: "good"))
    }

    func testSpeechWithoutWordsCutsAfterASecond() {
        var gate = CutInGate()
        gate.pause(at: 10, herText: "Hello")
        // Syllables with short dips: still one stretch of sound.
        XCTAssertEqual(blocks(&gate, loud: true, from: 10, to: 10.4), .wait)
        XCTAssertEqual(blocks(&gate, loud: false, from: 10.4, to: 10.6), .wait)
        XCTAssertEqual(blocks(&gate, loud: true, from: 10.6, to: 11.1), .cut(pausedAt: 10, words: nil))
    }

    func testHerWordsAsTheRecognizerWritesThem() {
        let her = CutInGate.vocabulary("There was a lighthouse keeper on the Alentejo coast. One, two, three.")
        XCTAssertFalse(CutInGate.isForeign("light", to: her))       // part of "lighthouse"
        XCTAssertFalse(CutInGate.isForeign("house", to: her))
        XCTAssertFalse(CutInGate.isForeign("Alentejos", to: her))   // a letter off
        XCTAssertFalse(CutInGate.isForeign("keepers,", to: her))
        XCTAssertFalse(CutInGate.isForeign("1.", to: her))          // numbers never count
        XCTAssertFalse(CutInGate.isForeign("no", to: her))          // nor words under three letters
        XCTAssertTrue(CutInGate.isForeign("stop", to: her))
        XCTAssertTrue(CutInGate.isForeign("Wait,", to: her))
    }

    func testOnASpeakerHerLateWordsDontCutButYoursDo() {
        var gate = CutInGate()
        gate.leadIn = 1.5
        gate.echoTail = 0.6
        gate.pause(at: 20, herText: "There was a lighthouse keeper on the Alentejo coast")
        // Her words (some misheard) from before the pause, recognized late.
        XCTAssertEqual(gate.heard([HeardWord("light", start: 18.9, end: 19.1), HeardWord("house", start: 19.1, end: 19.4),
                                   HeardWord("keepers", start: 19.4, end: 19.8)]), .wait)
        // The user's word that caused the pause, re-sent as final.
        XCTAssertEqual(gate.heard([HeardWord("coast", start: 19.0, end: 19.3), HeardWord("stop", start: 19.3, end: 19.7)]),
                       .cut(pausedAt: 20, words: "stop"))
    }

    func testNothingHappensUnlessPaused() {
        var gate = CutInGate()
        XCTAssertEqual(gate.level(loud: true, at: 1), .wait)
        XCTAssertEqual(gate.heard([HeardWord("stop", start: 0.5, end: 1)]), .wait)
        gate.pause(at: 2, herText: "")
        gate.reset()
        XCTAssertFalse(gate.isPaused)
    }
}
