import XCTest
import CarPlay
@testable import SideA

@MainActor final class CarPlayTests: XCTestCase {
    func testManifestRegistersAudioSceneCallbacks() throws {
        let manifest = try XCTUnwrap(Bundle.main.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any])
        let roles = try XCTUnwrap(manifest["UISceneConfigurations"] as? [String: Any])
        let car = try XCTUnwrap((roles["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]])?.first)
        XCTAssertEqual(car["UISceneClassName"] as? String, "CPTemplateApplicationScene")
        let runtimeName = try XCTUnwrap(car["UISceneDelegateClassName"] as? String)
        let cls = try XCTUnwrap(NSClassFromString(runtimeName) as? CarPlaySceneDelegate.Type)
        let delegate = cls.init()
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")))
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didDisconnectInterfaceController:")))
    }

    func testCarPlayTabsAndSongListsUseThePhoneLibrary() throws {
        let delegate = CarPlaySceneDelegate()
        let tabs = delegate.makeRootTemplate().templates.compactMap { $0 as? CPListTemplate }
        XCTAssertEqual(tabs.compactMap(\.title), ["发现", "我的"])
        let folders = tabs.first?.sections.first?.items.compactMap { ($0 as? CPListItem)?.text } ?? []
        XCTAssertEqual(folders, ["为你选的", "最近热歌", "近七天新歌"])

        let library = SideASession.shared.library
        let favorites = delegate.makeList(.favorites, title: "收藏")
        XCTAssertEqual(favorites.sections.flatMap(\.items).compactMap { ($0 as? CPListItem)?.text },
                       Array(library.favorites.prefix(CPListTemplate.maximumItemCount)).map(\.title))
        let personal = delegate.makeList(.personal, title: "为你选的")
        let songs = personal.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        XCTAssertFalse(songs.isEmpty)
        XCTAssertNotNil(songs.first?.handler)
    }
}
