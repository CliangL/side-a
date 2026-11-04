import XCTest

final class KuwoPlaybackTests: XCTestCase {
    @MainActor func testKuwoNativePlaybackAndRepeatedSeek() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIDEA_LIVE_QA"] == "1", "Opt-in private-build check")
        let storage = UUID().uuidString
        print("QA device name: Side A iOS 验收 " + storage)
        let app = XCUIApplication()
        app.launchEnvironment["SIDEA_TEST_STORAGE"] = storage
        app.launchEnvironment["SIDEA_TEST_AUTO_ENROLL"] = "1"
        app.launch()
        app.buttons["home.search"].tap()
        let scopes = app.segmentedControls["search.scope"]
        if !scopes.buttons["酷我音乐"].isHittable { scopes.swipeLeft() }
        scopes.buttons["酷我音乐"].tap()
        let input = app.textFields["search.input"]; input.tap(); input.typeText("卡农\n")
        let recording = app.buttons.matching(NSPredicate(format: "identifier CONTAINS '|central:kw.Mzg2MDQ4NTIx'")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 30), app.staticTexts.allElementsBoundByIndex.prefix(35).map(\.label).joined(separator: " / "))
        recording.tap()
        let mini = app.buttons["mini.open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5)); mini.tap()
        let toggle = app.buttons["player.toggle"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 35), .completed)
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "label == '播放进度'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in
            let value = progress.value as? String ?? ""
            return value.hasPrefix("0:") && !value.hasPrefix("0:00")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed)
        print("QA Kuwo native initial", progress.value as? String ?? "")
        // Multiple distant seeks cancel superseded byte requests before the final range is read.
        for point in [0.65, 0.2, 0.75] {
            progress.coordinate(withNormalizedOffset: CGVector(dx: point, dy: 0.5)).tap()
        }
        let seeked = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in
            let value = progress.value as? String ?? ""
            return value.hasPrefix("3:") || value.hasPrefix("4:")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 20), .completed)
        let before = progress.value as? String ?? ""
        let advancesAfterSeek = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in
            let value = progress.value as? String ?? ""
            return value != before && (value.hasPrefix("3:") || value.hasPrefix("4:")) && toggle.label == "暂停"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancesAfterSeek], timeout: 15), .completed)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        let quality = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '当前音质'")).firstMatch
        XCTAssertTrue(quality.label.contains("128 kbps"), quality.label)
        print("QA Kuwo native seek", before, "->", progress.value as? String ?? "", quality.label)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "酷我原生播放与快进"; image.lifetime = .keepAlways; add(image)
        toggle.tap()
        app.terminate()
    }
}
