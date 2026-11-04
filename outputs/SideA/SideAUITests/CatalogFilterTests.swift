import XCTest

final class CatalogFilterTests: XCTestCase {
    @MainActor func testSearchScopeAndSimpleSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["SIDEA_TEST_STORAGE"] = UUID().uuidString
        app.launch()
        app.buttons["home.search"].tap()
        let picker = app.segmentedControls["search.scope"]
        XCTAssertTrue(picker.buttons["全部"].isSelected)
        for title in ["QQ 音乐", "网易云", "酷我音乐", "JOOX"] {
            if !picker.buttons[title].isHittable { picker.swipeLeft() }
            picker.buttons[title].tap()
            XCTAssertTrue(picker.buttons[title].isSelected)
        }
        picker.swipeRight()
        picker.buttons["QQ 音乐"].tap()
        XCTAssertTrue(picker.buttons["QQ 音乐"].isSelected)
        XCTAssertFalse(app.buttons["search.customCatalog"].exists)
        app.terminate()
        app.launch()
        app.buttons["home.search"].tap()
        XCTAssertTrue(picker.buttons["QQ 音乐"].isSelected)
        app.buttons["完成"].tap()
        app.buttons["tab.library"].tap()
        XCTAssertFalse(app.buttons["library.customCatalog"].exists)
        app.buttons["library.settings"].tap()
        XCTAssertFalse(app.buttons["settings.customCatalog"].exists)
        XCTAssertFalse(app.buttons["central.connect"].exists)
        XCTAssertFalse(app.staticTexts["容量上限"].exists)
        app.buttons["settings.clearCache"].tap()
        XCTAssertTrue(app.buttons["settings.reset"].isHittable)
    }
}
