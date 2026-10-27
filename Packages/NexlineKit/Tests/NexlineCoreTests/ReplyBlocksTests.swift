import XCTest
@testable import NexlineCore

final class ReplyBlocksTests: XCTestCase {
    func testOpenMarkerBecomesAnAppLink() {
        let blocks = ReplyBlocks.parse("Putting it on.\nOPEN:youtube:Solomun boiler room")
        XCTAssertEqual(blocks.first, .line("Putting it on."))
        guard case .open(let link) = blocks.last else { return XCTFail("no open block") }
        XCTAssertEqual(link.key, "youtube")
        XCTAssertEqual(link.query, "Solomun boiler room")
        XCTAssertEqual(link.appURL?.absoluteString, "youtube://results?search_query=Solomun%20boiler%20room")
        XCTAssertEqual(link.webURL?.absoluteString,
                       "https://www.youtube.com/results?search_query=Solomun%20boiler%20room")
    }

    func testOpenMarkerWithoutQueryAndUnknownApp() {
        XCTAssertEqual(AppLink.parse("OPEN:Spotify")?.appURL?.absoluteString, "spotify://")
        XCTAssertNil(AppLink.parse("OPEN:netflix:something"))
        XCTAssertNil(AppLink.parse("Say OPEN:youtube"))
    }

    func testMapsOpensGoogleMapsWithDirections() {
        let link = AppLink.parse("OPEN:maps:Sintra")
        XCTAssertEqual(link?.label, "Google Maps")
        XCTAssertEqual(link?.appURL?.absoluteString, "comgooglemaps://?daddr=Sintra&directionsmode=driving")
        XCTAssertEqual(link?.webURL?.absoluteString, "https://www.google.com/maps/dir/?api=1&destination=Sintra")
    }

    func testCutMarkerShowsAsEllipsis() {
        XCTAssertEqual(ReplyBlocks.parse("One. Two. Three. [the user cut this reply off here]"), [.line("One. Two. Three. …")])
    }

    func testChromeTakesTheURLWithoutItsScheme() {
        XCTAssertEqual(AppLink.parse("OPEN:chrome:https://grooveline.org/live")?.appURL?.absoluteString,
                       "googlechromes://grooveline.org/live")
        XCTAssertEqual(AppLink.parse("OPEN:chrome:grooveline radio")?.appURL?.absoluteString,
                       "googlechromes://www.google.com/search?q=grooveline%20radio")
    }

    func testImagesMarkdownAndBare() {
        let blocks = ReplyBlocks.parse("Here it is ![cat](https://nexa.nexline.ai/media/cat.png)\nhttps://x.org/a.JPG")
        XCTAssertEqual(blocks, [
            .line("Here it is"),
            .image(URL(string: "https://nexa.nexline.ai/media/cat.png")!),
            .image(URL(string: "https://x.org/a.JPG")!),
        ])
    }

    func testMediaCardsUnderTheLine() {
        let blocks = ReplyBlocks.parse("Try https://www.mixcloud.com/dj/set-one/. Or https://youtu.be/abc")
        XCTAssertEqual(blocks, [
            .line("Try https://www.mixcloud.com/dj/set-one/. Or https://youtu.be/abc"),
            .media(URL(string: "https://www.mixcloud.com/dj/set-one/")!, .mixcloud),
            .media(URL(string: "https://youtu.be/abc")!, .youtube),
        ])
    }

    func testOneRadioCard() {
        let blocks = ReplyBlocks.parse("Live: https://radio.grooveline.org/auto and https://stream.grooveline.org/x.mp3")
        XCTAssertEqual(blocks.filter { if case .media(_, .radio) = $0 { return true }; return false }.count, 1)
    }

    func testInlinePlayableTracksOnly() {
        XCTAssertTrue(MediaKind.playsInline("https://www.mixcloud.com/dj/set-one/", .mixcloud))
        XCTAssertFalse(MediaKind.playsInline("https://www.mixcloud.com/dj/", .mixcloud))
        XCTAssertFalse(MediaKind.playsInline("https://www.mixcloud.com/discover/house/", .mixcloud))
        XCTAssertTrue(MediaKind.playsInline("https://soundcloud.com/artist/track", .soundcloud))
        XCTAssertFalse(MediaKind.playsInline("https://soundcloud.com/artist/sets/x", .soundcloud))
    }

    func testCameraDeviceAndCode() {
        let blocks = ReplyBlocks.parse("CAMERA:camera.cam_backyard\nIt uses [ha:device:sensor.airco:720] a lot\n```py\nx = 1\n```")
        XCTAssertEqual(blocks, [
            .camera(entityID: "camera.cam_backyard"),
            .line("It uses  a lot"),
            .haDevice(entityID: "sensor.airco"),
            .code(lang: "py", code: "x = 1"),
        ])
    }

    func testExpressionTagsAreHidden() {
        XCTAssertEqual(ReplyBlocks.stripExpressionTags("[laughs] That's funny [soft wonder]"), "That's funny")
        XCTAssertEqual(ReplyBlocks.stripExpressionTags("See [the docs](https://x.org)"), "See [the docs](https://x.org)")
        XCTAssertEqual(ReplyBlocks.stripExpressionTags("Use [Face ID] here"), "Use [Face ID] here")
        XCTAssertEqual(ReplyBlocks.parse("[sighs]\nOkay."), [.line("Okay.")])
    }

    func testMediaLinksBecomeAbsolute() {
        XCTAssertEqual(ReplyBlocks.rewriteMediaURLs("![x](/media/a.png)", base: "https://nexa.nexline.ai"),
                       "![x](https://nexa.nexline.ai/media/a.png)")
    }
}
