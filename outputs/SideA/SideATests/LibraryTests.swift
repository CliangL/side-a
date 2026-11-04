import XCTest
@testable import SideA

@MainActor final class LibraryTests: XCTestCase {
    private func record(_ id: String, artist: String = "Artist") -> Track {
        Track(source: "netease", trackID: id, title: id, artist: artist, album: "Album", pictureID: "", lyricID: id)
    }
    private func storeFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json") }

    func testPlaylistAndFavoriteSurviveCacheClearAndRelaunch() throws {
        let file = storeFile()
        let library = LibraryStore(file: file)
        let a = record("a"), b = record("b")
        let id = try XCTUnwrap(library.createPlaylist("Night"))
        library.add(a, to: id); library.add(a, to: id); library.add(b, to: id)
        library.reorder(id, from: [0], to: 2)
        library.toggleFavorite(a)
        if LocalStorage.testID != nil {
            GDClient.shared.cacheData(Data([1,2,3]), key: "test-art")
            GDClient.shared.clearCache()
        }
        let after = LibraryStore(file: file)
        XCTAssertEqual(after.playlists.first?.tracks, [b, a])
        XCTAssertTrue(after.isFavorite(a))
        after.remove(a, from: id)
        XCTAssertTrue(after.isFavorite(a))
        after.deletePlaylist(id)
        XCTAssertTrue(LibraryStore(file: file).isFavorite(a))
    }

    func testCacheKeepsFilesAbovePreviousCapacityUntilExplicitClear() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MediaCache(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = dir.appendingPathComponent("m-old")
        XCTAssertTrue(FileManager.default.createFile(atPath: previous.path, contents: nil))
        let file = try FileHandle(forWritingTo: previous)
        let bytes = 1025 * 1024 * 1024
        try file.truncate(atOffset: UInt64(bytes))
        try file.close()
        let epoch = cache.epoch
        cache.write(Data([1,2,3]), key: "later", epoch: epoch)
        XCTAssertEqual(cache.size, bytes + 3)
        XCTAssertEqual(cache.read("later", ttl: 60), Data([1,2,3]))
        cache.clear()
        cache.write(Data([4]), key: "late-response", epoch: epoch)
        XCTAssertEqual(cache.size, 0)
    }

    func testBulkEditsCoverAndStyleFeedback() throws {
        let store = LibraryStore(file: storeFile())
        var a = record("a", artist: "Singer A")
        a.genres = ["摇滚"]
        var b = record("b", artist: "Singer B")
        b.genres = ["民谣"]
        let id = try XCTUnwrap(store.createPlaylist("日落以后", tracks: [a, a]))
        store.add([b, a, b], to: id)
        store.setCover(b, for: id)
        XCTAssertEqual(store.playlists[0].tracks, [a,b])
        XCTAssertEqual(store.playlists[0].cover, b)
        store.remove([b.id], from: id)
        XCTAssertNil(store.playlists[0].cover)
        XCTAssertEqual(store.playlists[0].tracks, [a])
        store.reduceStyle(of: a, tags: ["摇滚"])
        XCTAssertEqual(store.recommendations(from: [a,b]).first, b)
    }

    func testIntentionalPlaybackAndExplicitFeedback() {
        let file = storeFile()
        let library = LibraryStore(file: file)
        let favorite = record("one"), alternative = record("two", artist: "Else"), third = record("three")
        library.record(favorite, event: "failed", listened: 0, duration: 200)
        XCTAssertTrue(library.seedTracks.isEmpty)
        for day in [-1, 0] {
            library.record(favorite, event: "manualPlay", listened: 0, duration: 200, date: Date().addingTimeInterval(Double(day) * 86400))
        }
        XCTAssertEqual(library.seedTracks.first, favorite)
        XCTAssertTrue(library.reason.contains("2 天"))
        let before = library.recommendations(from: [alternative, third])
        library.record(third, event: "interruption", listened: 5, duration: 200)
        XCTAssertEqual(library.recommendations(from: [alternative, third]), before)
        library.record(third, event: "skip", listened: 5, duration: 200)
        XCTAssertEqual(library.recommendations(from: [alternative, third]).first, alternative)
        library.dislike(third)
        XCTAssertFalse(LibraryStore(file: file).recommendations(from: [alternative, third]).contains(third))
        library.resetPreferences()
        library.trackingEnabled = false
        library.record(favorite, event: "manualPlay", listened: 0, duration: 200)
        XCTAssertTrue(library.seedTracks.isEmpty)
    }
}
