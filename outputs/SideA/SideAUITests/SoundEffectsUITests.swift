import XCTest

final class SoundEffectsUITests: XCTestCase {
    @MainActor func testSceneChoicePersistsAndSettingsRemainReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["SIDEA_TEST_STORAGE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["tab.library"].waitForExistence(timeout: 10))
        app.buttons["tab.library"].tap()
        app.buttons["library.settings"].tap()
        app.buttons["settings.sound"].tap()
        XCTAssertTrue(app.buttons["sound.original"].isSelected)
        let night = app.buttons["sound.night"]
        if !night.isHittable { app.scrollViews.firstMatch.swipeUp() }
        night.tap()
        XCTAssertTrue(night.isSelected)
        app.terminate()
        app.launch()
        app.buttons["tab.library"].tap()
        app.buttons["library.settings"].tap()
        app.buttons["settings.sound"].tap()
        XCTAssertTrue(app.buttons["sound.night"].isSelected)
        app.buttons["完成"].tap()
        let clear = app.buttons["settings.clearCache"]
        if !clear.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(clear.isHittable)
    }
}
