import Foundation
import XCTest
@testable import NexlineCore

final class SpeechTextTests: XCTestCase {
    func testMarkdownAndMarkersAreNotSpoken() {
        XCTAssertEqual(SpeechText.clean("**Hello** there."), "Hello there.")
        XCTAssertEqual(SpeechText.clean("Look ![cat](/media/cat.png) here"), "Look  here")
        XCTAssertEqual(SpeechText.clean("See [the docs](https://x.ai) now"), "See the docs now")
        XCTAssertEqual(SpeechText.clean("Turned on [ha:device:switch.airco_plug]."), "Turned on .")
        XCTAssertEqual(SpeechText.clean("Opening maps\nOPEN:maps:lisbon"), "Opening maps")
        XCTAssertEqual(SpeechText.clean("Let me make it. MEDIA:/root/.hermes/cache/audio/tts_065802.mp3"),
                       "Let me make it.")
        XCTAssertEqual(SpeechText.clean("<think>plan</think>Hi"), "Hi")
    }

    func testLowercaseExpressionTagsStayAndStatusAsidesGo() {
        XCTAssertEqual(SpeechText.clean("[laughing softly] Hi [Done]"), "[laughing softly] Hi")
    }

    func testPauseTagsBecomeSilence() {
        XCTAssertEqual(SpeechText.segments("Well [pause] okay [long pause] bye"), [
            .text("Well"), .silence(ms: 500), .text("okay"), .silence(ms: 900), .text("bye"),
        ])
        XCTAssertEqual(SpeechText.segments("**Just** text"), [.text("Just text")])
        XCTAssertEqual(SpeechText.segments("https://x.ai"), [])
    }
}

final class SentenceFlusherTests: XCTestCase {
    func testFlushBeforeAToolThenCarryOn() {
        var f = SentenceFlusher()
        XCTAssertNil(f.take("Let me find those.", final: false))
        XCTAssertEqual(f.take("Let me find those.", final: true), "Let me find those.")
        XCTAssertNil(f.take("Let me find those.", final: true))
        XCTAssertEqual(f.take("Let me find those.Mood lights are on, purple. The", final: false),
                       "Mood lights are on, purple. ")
    }

    func testFirstPieceFlushesEarlyThenWholeSentences() {
        var f = SentenceFlusher()
        XCTAssertEqual(f.take("Sure thing, I can help with that", final: false), "Sure thing, ")
        XCTAssertNil(f.take("Sure thing, I can help with that", final: false))
        XCTAssertEqual(f.take("Sure thing, I can help with that. Next", final: false), "I can help with that. ")
        XCTAssertEqual(f.take("Sure thing, I can help with that. Next thing", final: true), "Next thing")
        XCTAssertNil(f.take("Sure thing, I can help with that. Next thing", final: true))
    }

    /// Build 15: "Here," alone, then a second of silence while the rest synthesized.
    func testFirstPieceIsNeverALoneWord() {
        var f = SentenceFlusher()
        XCTAssertNil(f.take("Here, what do", final: false))
        XCTAssertNil(f.take("Sure. Playing", final: false))
        XCTAssertEqual(f.take("Here, what do you want? I", final: false), "Here, what do you want? ")
        var g = SentenceFlusher()
        XCTAssertEqual(g.take("Done.", final: true), "Done.")
    }

    func testNeverCutsInsideATag() {
        var f = SentenceFlusher()
        XCTAssertNil(f.take("[singing softly, warmly] la la", final: false))
        XCTAssertEqual(f.take("[singing softly, warmly] la la. And", final: false), "[singing softly, warmly] la la. ")
    }

    func testLongFirstPieceWithoutPunctuationCutsAtASpace() {
        var f = SentenceFlusher()
        let text = "one two three four five six seven eight nine ten eleven"
        XCTAssertEqual(f.take(text, final: false), "one two three four five six seven eight nine ten ")
        XCTAssertEqual(f.take(text, final: true), "eleven")
    }

    func testShorterReplacementDoesNotCrash() {
        var f = SentenceFlusher()
        XCTAssertEqual(f.take("Hello there, friend. How", final: false), "Hello there, friend. ")
        XCTAssertNil(f.take("Hi", final: false))
        XCTAssertNil(f.take("Hi", final: true))
    }
}

final class HeardTimelineTests: XCTestCase {
    func testCountsPlayedPiecesAndPartOfThePlayingOne() {
        var t = HeardTimeline()
        t.add("one two three four", start: 0, end: 1)
        t.add("five six", start: 1, end: 2)
        XCTAssertEqual(t.heard(at: 0), "")
        XCTAssertEqual(t.heard(at: 0.5), "one two")
        XCTAssertEqual(t.heard(at: 1.5), "one two three four five")
        XCTAssertEqual(t.heard(at: 3), "one two three four five six")
        XCTAssertFalse(t.fullyPlayed(at: 1.5))
        XCTAssertTrue(t.fullyPlayed(at: 2))
        XCTAssertTrue(HeardTimeline().fullyPlayed(at: 0))
    }

    func testAPauseMovesWhatWasStillToPlay() {
        var t = HeardTimeline()
        t.add("one two", start: 0, end: 1)
        t.add("three four", start: 1, end: 2)
        t.add("five six", start: 2, end: 3)
        XCTAssertEqual(t.text(around: 1.5), "one two three four")
        // Held at 1.5 for 2 s: "three four" was half played, the rest waits.
        t.shift(after: 1.5, by: 2)
        XCTAssertEqual(t.heard(at: 1.5), "one two")
        XCTAssertEqual(t.heard(at: 3.5), "one two three")
        XCTAssertEqual(t.heard(at: 4.0), "one two three four")
        XCTAssertFalse(t.fullyPlayed(at: 4.5))
        XCTAssertTrue(t.fullyPlayed(at: 5))
    }
}

final class ChatStreamParserTests: XCTestCase {
    func testDeltasToolsReplaceAndDone() {
        var p = ChatStreamParser()
        XCTAssertEqual(p.parse(line: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#), .text("Hel"))
        XCTAssertEqual(p.parse(line: "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\r"), .text("Hello"))
        XCTAssertEqual(p.parse(line: #"data: {"tool":"web_search","status":"start","label":"Searching"}"#),
                       .tool(label: "Searching", status: "start"))
        XCTAssertEqual(p.parse(line: #"data: {"choices":[{"delta":{"content":"Hi!"}}],"replace":true}"#), .text("Hi!"))
        XCTAssertEqual(p.reply, "Hi!")
        XCTAssertEqual(p.parse(line: "data: [DONE]"), .done)
    }

    func testIgnoresNoise() {
        var p = ChatStreamParser()
        XCTAssertNil(p.parse(line: ": keepalive"))
        XCTAssertNil(p.parse(line: "event: message"))
        XCTAssertNil(p.parse(line: "data: {not json"))
        XCTAssertNil(p.parse(line: #"data: {"choices":[{"delta":{}}]}"#))
        XCTAssertEqual(p.reply, "")
    }
}

final class PCM16DecoderTests: XCTestCase {
    func testLittleEndianSigned() {
        var d = PCM16Decoder()
        XCTAssertEqual(d.decode(Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00])), [-1, 32767.0 / 32768, 0])
    }

    func testSampleSplitAcrossChunks() {
        var d = PCM16Decoder()
        XCTAssertEqual(d.decode(Data([0x00])), [])
        XCTAssertEqual(d.decode(Data([0x40, 0x00, 0xC0])), [0.5, -0.5])
    }

    func testBase64() {
        var d = PCM16Decoder()
        XCTAssertEqual(d.decode(base64: Data([0x00, 0x40]).base64EncodedString()), [0.5])
        XCTAssertNil(d.decode(base64: "not base64!"))
    }
}

final class EndpointerTests: XCTestCase {
    func testFinalTextEndsTheTurnAfterTheGap() {
        var e = Endpointer()
        e.add("turn on", isFinal: false, at: 0)
        e.add("turn on the lights", isFinal: true, at: 1)
        XCTAssertNil(e.take(at: 1.5))
        XCTAssertEqual(e.take(at: 1.8), "turn on the lights")
        XCTAssertNil(e.take(at: 5))
    }

    func testNewSpeechKeepsTheTurnOpen() {
        var e = Endpointer()
        e.add("turn on the lights", isFinal: true, at: 1)
        e.add("in the", isFinal: false, at: 1.6)
        XCTAssertNil(e.take(at: 2.4))
        e.add("in the kitchen", isFinal: true, at: 2.5)
        XCTAssertEqual(e.take(at: 3.3), "turn on the lights in the kitchen")
    }

    func testUnfinalizedGuessEndsAfterTheLongerGap() {
        var e = Endpointer()
        e.add("hello", isFinal: false, at: 0)
        XCTAssertNil(e.take(at: 1))
        XCTAssertEqual(e.take(at: 1.5), "hello")
    }

    func testResetDropsEverything() {
        var e = Endpointer()
        e.add("echo words", isFinal: true, at: 0)
        e.reset()
        XCTAssertEqual(e.text, "")
        XCTAssertNil(e.take(at: 10))
    }

    func testSpeechEndEndsAFinishedSentenceAtOnce() {
        var e = Endpointer(finalGap: 1.6, volatileGap: 2.5)
        e.add("What time is it?", isFinal: true, at: 1)
        XCTAssertNil(e.take(at: 1.2))
        e.speechEnded(at: 1.2)
        XCTAssertEqual(e.take(at: 1.2), "What time is it?")
    }

    func testSpeechEndWaitsWhenItTrailsOff() {
        var e = Endpointer(finalGap: 1.6, volatileGap: 2.5)
        e.add("turn on the", isFinal: true, at: 1)
        e.speechEnded(at: 1)
        XCTAssertNil(e.take(at: 2))
        XCTAssertEqual(e.take(at: 2.5), "turn on the")
    }

    func testTalkingAgainCancelsTheSpeechEnd() {
        var e = Endpointer(finalGap: 1.6, volatileGap: 2.5)
        e.add("Okay so,", isFinal: true, at: 1)
        e.speechEnded(at: 1)
        e.add("check the", isFinal: false, at: 1.5)
        XCTAssertNil(e.take(at: 3))
        e.add("check the lights.", isFinal: true, at: 3)
        e.speechEnded(at: 3)
        XCTAssertEqual(e.take(at: 3), "Okay so, check the lights.")
    }

    func testLooksUnfinished() {
        XCTAssertTrue(Endpointer.looksUnfinished("turn on the"))
        XCTAssertTrue(Endpointer.looksUnfinished("I want to,"))
        XCTAssertTrue(Endpointer.looksUnfinished("okay so"))
        XCTAssertTrue(Endpointer.looksUnfinished("liga a luz da"))
        XCTAssertFalse(Endpointer.looksUnfinished("Stop."))
        XCTAssertFalse(Endpointer.looksUnfinished("what time is it?"))
        XCTAssertFalse(Endpointer.looksUnfinished("turn on the lights"))
        XCTAssertFalse(Endpointer.looksUnfinished(""))
    }
}
