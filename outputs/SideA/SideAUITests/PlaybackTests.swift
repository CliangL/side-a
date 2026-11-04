import XCTest

final class PlaybackTests: XCTestCase {
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func openPlayer() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SIDEA_TEST_STORAGE"] = UUID().uuidString
        app.launch()
        let sea = app.buttons["track.play.netease:1320101152"].firstMatch
        if sea.waitForExistence(timeout: 5), sea.isHittable {
            sea.tap()
        } else {
            app.buttons["home.search"].tap()
            let input = app.textFields["search.input"]
            input.tap(); input.typeText("deca joins")
            try XCTSkipUnless(sea.waitForExistence(timeout: 20), "Live search did not return the test recording")
            sea.tap()
        }
        let mini = app.buttons["mini.open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        return app
    }

    @MainActor private func swipePager(_ app: XCUIApplication, left: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.78 : 0.22, dy: 0.43))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.22 : 0.78, dy: 0.43))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor private func assertPage(_ app: XCUIApplication, lyrics: Bool, file: StaticString = #filePath, line: UInt = #line) {
        // A page controller may keep the adjacent slide in the accessibility tree.
        // Wait on the live selection (the shared switch offers the opposite page).
        let pageSwitch = app.buttons["player.lyrics"]
        let selected = NSPredicate(format: "label == %@", lyrics ? "唱片" : "歌词")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: selected, object: pageSwitch)], timeout: 5),
                       .completed, file: file, line: line)
        let identifier = lyrics ? "player.lyricsPage" : "player.coverPage"
        let page = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(page.frame.contains(CGPoint(x: app.frame.midX, y: app.frame.height * 0.43)), file: file, line: line)
        XCTAssertTrue(page.staticTexts["海浪"].firstMatch.exists, "The selected recording should survive paging", file: file, line: line)
    }

    @MainActor func testHorizontalPagingKeepsSongAndAnchoredTransport() throws {
        let app = try openPlayer()
        assertPage(app, lyrics: false)
        let toggle = app.buttons["player.toggle"]
        XCTAssertTrue(toggle.isHittable)
        let initialFrame = toggle.frame
        XCTAssertGreaterThan(initialFrame.midY, app.frame.minY + app.frame.height * 0.82,
                             "Transport should use the lower part of the screen")

        swipePager(app, left: true)
        assertPage(app, lyrics: true)
        XCTAssertEqual(toggle.frame.midY, initialFrame.midY, accuracy: 2)
        capture(app, "sidea-lyrics")
        swipePager(app, left: false)
        assertPage(app, lyrics: false)
        XCTAssertEqual(toggle.frame.midY, initialFrame.midY, accuracy: 2)
    }

    @MainActor func testListeningFlowAndRealScreens() throws {
        let app = try openPlayer()
        let quality = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'FLAC'")).firstMatch
        try XCTSkipUnless(quality.waitForExistence(timeout: 45), "The live music provider did not return a FLAC stream")
        let active = app.buttons["player.toggle"]
        let playing = NSPredicate(format: "label == '暂停'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: playing, evaluatedWith: active)], timeout: 25), .completed)
        capture(app, "sidea-player")
        app.buttons["player.lyrics"].tap()
        assertPage(app, lyrics: true)
        XCTAssertEqual(active.label, "暂停", "Opening lyrics must not interrupt playback")
        active.tap()
        let paused = NSPredicate(format: "label == '播放'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: paused, evaluatedWith: active)], timeout: 5), .completed)
        active.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: playing, evaluatedWith: active)], timeout: 10), .completed)
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "label == '播放进度'")).firstMatch
        XCTAssertTrue(progress.isHittable)
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertEqual(active.label, "暂停", "Seeking on the lyrics page must keep playback active")
        let line = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.lyricLine.'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 30), "A recording with timed lyrics must show actual lyric lines")
        capture(app, "sidea-lyrics-playing")
        app.buttons["player.lyrics"].tap()
        assertPage(app, lyrics: false)
        app.buttons["player.queue"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        active.tap()
        app.buttons["player.close"].tap()
        XCTAssertTrue(app.buttons["mini.open"].waitForExistence(timeout: 5))
        capture(app, "sidea-home")

        let feature = app.staticTexts["为你选的"].firstMatch
        feature.tap()
        XCTAssertTrue(app.buttons["播放全部"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "sidea-playlist")
    }
}
