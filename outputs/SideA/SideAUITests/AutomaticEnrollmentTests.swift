import XCTest

final class AutomaticEnrollmentTests: XCTestCase {
    @MainActor func testFreshInstallCanSearchAndPlay() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDEA_LIVE_QA"] == "1", "Opt-in private-build check")
        let storage = UUID().uuidString
        print("QA device name: Side A iOS 验收 " + storage)
        let app = XCUIApplication()
        app.launchEnvironment["SIDEA_TEST_STORAGE"] = storage
        app.launchEnvironment["SIDEA_TEST_AUTO_ENROLL"] = "1"
        app.launch()
        app.buttons["home.search"].tap()
        let scope=app.segmentedControls["search.scope"]
        XCTAssertTrue(scope.buttons["全部"].isSelected)
        scope.buttons["QQ 音乐"].tap()
        XCTAssertTrue(scope.buttons["QQ 音乐"].isSelected)
        let field=app.textFields["search.input"]; field.tap(); field.typeText("菊花台\n")
        let jay=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'track.play.' AND (label CONTAINS '周杰伦' OR label CONTAINS '周杰倫') AND (label CONTAINS '菊花台' OR label CONTAINS '菊花臺')")).firstMatch
        XCTAssertTrue(jay.waitForExistence(timeout: 30), app.staticTexts.allElementsBoundByIndex.prefix(45).map(\.label).joined(separator:" / "))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.buttons["search.gdQQ"].exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        XCTAssertTrue(jay.identifier.contains("|central:qq."))
        XCTAssertTrue(jay.label.contains("QQ 音乐"), jay.label)
        // The presented search sheet and the home feed both have track buttons.
        let list = app.scrollViews.containing(.textField, identifier: "search.input").firstMatch
        XCTAssertTrue(list.exists)
        let trackSelector = NSPredicate(format: "identifier BEGINSWITH 'track.play.'")
        let rows = list.buttons.matching(trackSelector).allElementsBoundByIndex
        let background = app.buttons.matching(trackSelector).allElementsBoundByIndex.filter { row in
            !row.identifier.contains("|central:qq.") && !rows.contains { $0.identifier == row.identifier }
        }
        print("QA underlying view rows", background.map(\.identifier), "hittable", background.filter { $0.isHittable }.count)
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertTrue(row.identifier.contains("|central:qq.") && row.label.contains("QQ 音乐"), row.identifier + " " + row.label)
        }
        print("QA: QQ-only results", rows.count, jay.label)
        jay.tap()
        let mini=app.buttons["mini.open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        let elapsed = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@", "播放进度")).firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 8))
        let change=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            let pos=elapsed.value as? String ?? ""
            return pos.hasPrefix("0:") && !pos.hasPrefix("0:00")
        },object:nil)
        guard XCTWaiter.wait(for:[change], timeout:36) == .completed else {
            XCTFail("No progress. "+app.staticTexts.allElementsBoundByIndex.map(\.label).prefix(35).joined(separator:" / "))
            return
        }
        let before = elapsed.value as? String ?? ""
        sleep(3)
        let after = elapsed.value as? String ?? ""
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(app.buttons["player.toggle"].label,"暂停")
        let quality = app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@", "当前音质")).firstMatch
        XCTAssertTrue(quality.label.contains("FLAC"))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        print("QA: native player", before, after, quality.label)
        app.buttons["player.close"].tap()
        app.buttons["tab.library"].tap()
        app.buttons["library.settings"].tap()
        let reset = app.buttons["settings.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 6))
        if !reset.isHittable { app.swipeUp() }
        let playing = app.buttons["mini.open"]
        XCTAssertLessThan(reset.frame.maxY, playing.frame.minY)
        XCTAssertTrue(reset.isHittable)
        print("QA: settings last row bottom", reset.frame.maxY, "player top", playing.frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "播放中的设置页"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        reset.tap()
        XCTAssertTrue(app.buttons["重置偏好"].waitForExistence(timeout: 3))
        app.buttons["重置偏好"].tap()
        app.terminate()
        app.launch()
        app.buttons["home.search"].tap()
        XCTAssertTrue(scope.buttons["QQ 音乐"].isSelected)
        scope.buttons["全部"].tap()
        XCTAssertTrue(scope.buttons["全部"].isSelected)
    }
}
