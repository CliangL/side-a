import XCTest

final class SoundEffectsUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SIDEA_TEST_STORAGE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func option(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }
    @MainActor private func assertSelection(_ title: String, control: XCUIElement) {
        let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", title, title)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: control)], timeout: 5), .completed)
    }
    @MainActor func testCompactChoiceClosesAndPersists() {
        let app = launch()
        app.buttons["tab.library"].tap()
        app.buttons["library.settings"].tap()
        let menu = app.buttons["settings.sound"]
        menu.tap()
        let hall = option("音乐厅", in: app)
        XCTAssertTrue(hall.waitForExistence(timeout: 5))
        for title in ["原声", "立体环绕", "清澈人声", "录音棚", "低音增强", "柔和聆听"] {
            XCTAssertTrue(option(title, in: app).exists)
        }
        XCTAssertFalse(app.buttons["完成"].exists, "Effects should use a compact menu, not a new sheet")
        capture(app, "sidea-compact-effects-settings")
        hall.tap()
        XCTAssertFalse(hall.exists, "Selection should dismiss the menu")
        assertSelection("音乐厅", control: menu)
        app.terminate(); app.launch()
        app.buttons["tab.library"].tap()
        app.buttons["library.settings"].tap()
        assertSelection("音乐厅", control: app.buttons["settings.sound"])
        XCTAssertTrue(app.buttons["settings.clearCache"].isHittable)
    }
    @MainActor func testPlayerEffectMenuDoesNotReplacePlaybackPage() {
        let app = launch()
        let song = app.buttons["track.play.netease:1320101152"].firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 5)); song.tap()
        let mini = app.buttons["mini.open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5)); mini.tap()
        let menu = app.buttons["player.sound"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let studio = option("录音棚", in: app)
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        capture(app, "sidea-compact-effects-player")
        studio.tap()
        XCTAssertTrue(app.buttons["player.toggle"].isHittable)
        assertSelection("录音棚", control: menu)
        app.buttons["player.lyrics"].tap()
        XCTAssertTrue(menu.isHittable)
        menu.tap(); option("原声", in: app).tap()
        assertSelection("原声", control: menu)
        XCTAssertTrue(app.buttons["player.toggle"].isHittable)
    }
}
