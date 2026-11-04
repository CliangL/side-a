import XCTest

final class SmokeTests: XCTestCase {
    @MainActor func testHomeSearchLibraryAndFavoritePersistence() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SIDEA_TEST_STORAGE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 15))
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'favorite.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        let favoriteID = first.identifier
        if first.label == "取消收藏" { first.tap() }
        first.tap()
        app.buttons["tab.library"].tap()
        app.buttons["library.favorites"].tap()
        XCTAssertTrue(app.buttons[favoriteID].waitForExistence(timeout: 6))
        app.terminate()
        app.launch()
        app.buttons["tab.library"].tap()
        app.buttons["library.favorites"].tap()
        let saved = app.buttons[favoriteID].firstMatch
        XCTAssertTrue(saved.exists)
        saved.tap()
        app.buttons["tab.home"].tap()
        app.buttons["home.search"].tap()
        let input = app.textFields["search.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Clair de lune")
        XCTAssertTrue(app.staticTexts["搜索结果"].waitForExistence(timeout: 7))
    }
}
