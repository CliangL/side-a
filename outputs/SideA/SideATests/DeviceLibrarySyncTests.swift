import XCTest
@testable import SideA

@MainActor private final class MemoryCloud: LibraryCloudTransport {
    var identity = UUID().uuidString
    var reply = LibraryCloudReply(revision: 0, data: nil)
    var offline = false
    var writes = 0
    var onBind: (() -> Void)?
    var onSave: (() -> Void)?
    var conflict: DeviceLibrarySnapshot?
    func bind() async throws -> LibraryCloudReply {
        if offline { throw URLError(.notConnectedToInternet) }
        onBind?(); onBind = nil
        return reply
    }
    func save(_ data: DeviceLibrarySnapshot, revision: Int) async throws -> LibraryCloudReply {
        if offline { throw URLError(.notConnectedToInternet) }
        writes += 1
        if let conflict {
            self.conflict = nil
            reply = LibraryCloudReply(revision: reply.revision + 1, data: conflict)
            return reply
        }
        guard revision == reply.revision else { return reply }
        onSave?(); onSave = nil
        reply = LibraryCloudReply(revision: revision + 1, data: data)
        return reply
    }
}

@MainActor final class DeviceLibrarySyncTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(source: "central", trackID: "qq." + id, title: id, artist: "Singer", album: "Album", pictureID: id, lyricID: id,
              catalogEndpoint: URL(string: "https://music.cliang.top/v1/music"), managedCatalog: true)
    }
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cloud.json") }

    func testThreeWayMergeKeepsIndependentEditsAndDeletions() {
        let a = track("a"), b = track("b"), c = track("c"), d = track("d")
        var base = DeviceLibrarySnapshot()
        let playlist = UserPlaylist(name: "Before", tracks: [a,b], cover: a)
        let removed = UserPlaylist(name: "Remove", tracks: [b])
        base.library.favorites = [a,b]; base.library.playlists = [playlist, removed]
        base.library.hidden = ["old"]; base.library.mutedStyles = ["rock"]
        var local = base, remote = base
        local.library.favorites = [c,b]
        local.library.playlists = [playlist]
        local.library.playlists[0].tracks = [b]
        local.library.hidden = []; local.library.mutedStyles = []
        remote.library.favorites = [d,a,b]
        remote.library.playlists[0].name = "Renamed"
        remote.library.playlists[0].tracks.append(d)
        remote.library.playlists[1].name = "Remote edit"
        remote.library.hidden.insert("new"); remote.library.mutedStyles?.insert("folk")
        let merged = DeviceLibrarySnapshot.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.library.favorites, [c,b,d])
        XCTAssertEqual(merged.library.playlists.count, 1)
        XCTAssertEqual(merged.library.playlists[0].name, "Renamed")
        XCTAssertEqual(merged.library.playlists[0].tracks, [b,d])
        XCTAssertNil(merged.library.playlists[0].cover)
        XCTAssertEqual(merged.library.hidden, ["new"])
        XCTAssertEqual(merged.library.mutedStyles, ["folk"])
    }

    func testFreshInstallationRestoresEverythingBeforeAnyUpload() async throws {
        let a = track("favorite"), b = track("recent")
        var expected = DeviceLibrarySnapshot()
        expected.library.favorites = [a]; expected.library.recent = [b,a]
        expected.library.playlists = [UserPlaylist(name: "Cloud playlist", tracks: [b,a], cover: b)]
        expected.library.listening = [ListeningDay(track: a, date: Date(), choices: 2, replays: 1, completions: 1, quickSkips: 0)]
        expected.library.genres = [a.id: ["民谣"]]; expected.library.mutedStyles = ["rock"]; expected.library.hidden = [b.id]
        expected.playback.resume = CloudPlayback.Resume(queue: [b,a], index: 1, position: 42)
        expected.playback.losslessOnly = true; expected.qqSearch = true
        let transport = MemoryCloud(); transport.reply = LibraryCloudReply(revision: 7, data: expected)
        var local = DeviceLibrarySnapshot()
        let sync = DeviceLibrarySync(file: file(), read: { local }, apply: { local = $0 }, connect: { transport })
        await sync.flush()
        XCTAssertEqual(local, expected)
        XCTAssertTrue(sync.lastSyncSucceeded)
        XCTAssertEqual(transport.writes, 0, "An empty reinstall must not overwrite its saved cloud library")
    }

    func testUserEditDuringFirstFetchSurvivesRestore() async {
        let saved = track("saved"), fresh = track("just-tapped")
        var cloud = DeviceLibrarySnapshot(); cloud.library.favorites = [saved]
        let transport = MemoryCloud(); transport.reply = LibraryCloudReply(revision: 1, data: cloud)
        var local = DeviceLibrarySnapshot()
        transport.onBind = { local.library.favorites = [fresh] }
        let sync = DeviceLibrarySync(file: file(), read: { local }, apply: { local = $0 }, connect: { transport })
        await sync.flush()
        XCTAssertEqual(local.library.favorites, [fresh, saved])
        XCTAssertEqual(transport.reply.data, local)
    }

    func testOfflineDeletionSurvivesRelaunchAndCloudConflict() async throws {
        let a = track("a"), b = track("b"), c = track("c"), d = track("d")
        let path = file(), transport = MemoryCloud()
        var local = DeviceLibrarySnapshot(); local.library.favorites = [a,b]
        var sync: DeviceLibrarySync? = DeviceLibrarySync(file: path, read: { local }, apply: { local = $0 }, connect: { transport })
        await sync?.flush()
        XCTAssertEqual(transport.reply.data, local)
        local.library.favorites = [c,b]
        transport.offline = true
        await sync?.flush()
        XCTAssertEqual(local.library.favorites, [c,b])
        XCTAssertEqual(transport.reply.data?.library.favorites, [a,b])
        sync = nil
        transport.offline = false
        var conflict = try XCTUnwrap(transport.reply.data); conflict.library.favorites = [d,a,b]
        transport.conflict = conflict
        let restarted = DeviceLibrarySync(file: path, read: { local }, apply: { local = $0 }, connect: { transport })
        await restarted.flush()
        XCTAssertEqual(local.library.favorites, [c,b,d])
        XCTAssertEqual(transport.reply.data, local)
        XCTAssertTrue(restarted.lastSyncSucceeded)
    }

    func testEditsDuringUploadAreSentAfterAcknowledgedSnapshot() async {
        let a = track("a"), b = track("b")
        let transport = MemoryCloud()
        var local = DeviceLibrarySnapshot(); local.library.favorites = [a]
        transport.onSave = { local.library.favorites = [b] }
        let sync = DeviceLibrarySync(file: file(), read: { local }, apply: { local = $0 }, connect: { transport })
        async let first: Void = sync.flush()
        async let second: Void = sync.flush()
        _ = await (first,second)
        XCTAssertEqual(local.library.favorites, [b])
        XCTAssertEqual(transport.reply.data, local)
        XCTAssertEqual(transport.writes, 2)
    }

    func testFailedDiskRestoreDoesNotAcknowledgeOrUpload() async {
        var expected = DeviceLibrarySnapshot(); expected.library.favorites = [track("saved")]
        let transport = MemoryCloud(); transport.reply = LibraryCloudReply(revision: 4, data: expected)
        let path = file()
        let sync = DeviceLibrarySync(file: path, read: { DeviceLibrarySnapshot() }, apply: { _ in throw CocoaError(.fileWriteOutOfSpace) }, connect: { transport })
        await sync.flush()
        XCTAssertFalse(sync.lastSyncSucceeded)
        XCTAssertEqual(transport.writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(transport.reply.data, expected)
    }

    func testRestoredLibraryRetainsRecommendationsAcrossCacheClear() throws {
        let path = file()
        let library = LibraryStore(file: path), a = track("repeat"), b = track("skip")
        library.toggleFavorite(a); library.record(a, event: "manualPlay", listened: 0, duration: 120)
        library.record(a, event: "replay", listened: 0, duration: 120)
        library.record(b, event: "skip", listened: 5, duration: 120)
        library.reduceStyle(of: b, tags: ["摇滚"])
        _ = library.createPlaylist("Favorites", tracks: [a,b])
        let restored = LibraryStore(file: file())
        try restored.restore(library.snapshot)
        XCTAssertEqual(restored.snapshot, library.snapshot)
        GDClient.shared.clearCache()
        XCTAssertEqual(restored.snapshot, library.snapshot)
        XCTAssertEqual(restored.seedTracks, library.seedTracks)
        XCTAssertEqual(restored.recommendations(from: [a,b]), library.recommendations(from: [a,b]))
    }

    func testCorruptOrMissingLocalFileCannotOverwriteAcknowledgedCloudLibrary() async throws {
        let a = track("saved"), b = track("new-after-recovery")
        for missing in [false, true] {
            let libraryPath = file(), journalPath = file(), transport = MemoryCloud()
            var library = LibraryStore(file: libraryPath)
            library.toggleFavorite(a)
            let first = DeviceLibrarySync(file: journalPath,
                read: { DeviceLibrarySnapshot(library: library.snapshot) },
                apply: { try library.restore($0.library) },
                needsLibraryRecovery: { library.needsCloudRecovery }, connect: { transport })
            await first.flush()
            let beforeWrites = transport.writes
            if missing { try FileManager.default.removeItem(at: libraryPath) }
            else { try Data("corrupt library".utf8).write(to: libraryPath) }
            library = LibraryStore(file: libraryPath)
            XCTAssertTrue(library.needsCloudRecovery)
            if !missing {
                library.toggleFavorite(b)
                library = LibraryStore(file: libraryPath)
                XCTAssertTrue(library.needsCloudRecovery, "A relaunch before cloud recovery must not mistake a partial local file for deliberate deletions")
            }
            let restart = DeviceLibrarySync(file: journalPath,
                read: { DeviceLibrarySnapshot(library: library.snapshot) },
                apply: { try library.restore($0.library) },
                needsLibraryRecovery: { library.needsCloudRecovery }, connect: { transport })
            await restart.flush()
            XCTAssertTrue(restart.lastSyncSucceeded)
            XCTAssertFalse(library.needsCloudRecovery)
            XCTAssertTrue(library.isFavorite(a))
            if missing { XCTAssertEqual(transport.writes, beforeWrites) }
            else { XCTAssertTrue(library.isFavorite(b)) }
            XCTAssertEqual(transport.reply.data?.library.favorites, library.favorites)
        }
    }

    func testFailedLocalSaveCannotAdvanceWritableJournalOrCloud() async throws {
        let libraryPath = file(), journalPath = file(), transport = MemoryCloud()
        let library = LibraryStore(file: libraryPath)
        library.toggleFavorite(track("before"))
        let sync = DeviceLibrarySync(file: journalPath,
            read: { DeviceLibrarySnapshot(library: library.snapshot) },
            apply: { try library.restore($0.library) },
            needsLibraryRecovery: { library.needsCloudRecovery },
            needsDurableLibraryWrite: { library.storageError != nil }, connect: { transport })
        await sync.flush()
        let acknowledged = try Data(contentsOf: journalPath), writes = transport.writes
        let oldFile = libraryPath.appendingPathExtension("qa-original")
        try FileManager.default.moveItem(at: libraryPath, to: oldFile)
        try FileManager.default.createDirectory(at: libraryPath, withIntermediateDirectories: false)
        library.toggleFavorite(track("disk-failure"))
        XCTAssertNotNil(library.storageError)
        await sync.flush()
        XCTAssertFalse(sync.lastSyncSucceeded)
        XCTAssertEqual(transport.writes, writes)
        XCTAssertEqual(try Data(contentsOf: journalPath), acknowledged)
        try FileManager.default.removeItem(at: libraryPath)
        try FileManager.default.moveItem(at: oldFile, to: libraryPath)
        await sync.flush()
        XCTAssertTrue(sync.lastSyncSucceeded)
        XCTAssertEqual(LibraryStore(file: libraryPath).favorites, library.favorites)
        XCTAssertEqual(transport.reply.data?.library.favorites, library.favorites)
    }

    func testDiskFailureDuringUploadStopsNextUnpersistedSnapshot() async throws {
        let libraryPath = file(), transport = MemoryCloud()
        // Use a real library path and independently writable journal.
        let store = LibraryStore(file: libraryPath)
        store.toggleFavorite(track("first"))
        let oldFile = libraryPath.appendingPathExtension("qa-original")
        transport.onSave = {
            try! FileManager.default.moveItem(at: libraryPath, to: oldFile)
            try! FileManager.default.createDirectory(at: libraryPath, withIntermediateDirectories: false)
            store.toggleFavorite(self.track("not-durable"))
        }
        let sync = DeviceLibrarySync(file: file(), read: { DeviceLibrarySnapshot(library: store.snapshot) },
            apply: { try store.restore($0.library) }, needsLibraryRecovery: { store.needsCloudRecovery },
            needsDurableLibraryWrite: { store.storageError != nil }, connect: { transport })
        await sync.flush()
        XCTAssertFalse(sync.lastSyncSucceeded)
        XCTAssertEqual(transport.writes, 1)
        XCTAssertEqual(transport.reply.data?.library.favorites.map(\.title), ["first"])
        try FileManager.default.removeItem(at: libraryPath)
        try FileManager.default.moveItem(at: oldFile, to: libraryPath)
        await sync.flush()
        XCTAssertTrue(sync.lastSyncSucceeded)
        XCTAssertEqual(LibraryStore(file: libraryPath).favorites, store.favorites)
        XCTAssertEqual(transport.reply.data?.library.favorites, store.favorites)
    }

    func testOldQQPreferenceAndExpandedProviderRoundTrip() throws {
        var old = DeviceLibrarySnapshot(); old.qqSearch = true
        let oldData = try JSONEncoder().encode(old)
        XCTAssertEqual(try JSONDecoder().decode(DeviceLibrarySnapshot.self, from: oldData).effectiveProvider, "qq")
        for provider in ["all", "qq", "wy", "jx", "kw"] {
            var expanded = old; expanded.selectedProvider = provider; expanded.qqSearch = provider == "qq"
            XCTAssertEqual(try JSONDecoder().decode(DeviceLibrarySnapshot.self, from: JSONEncoder().encode(expanded)).effectiveProvider, provider)
        }
    }

    func testRecoveryIsStableAndSeparateFromInstallationIdentity() throws {
        try XCTSkipUnless(LocalStorage.testID != nil)
        let before = try CentralServer.installation()
        let first = try CentralServer.libraryRecovery(), second = try CentralServer.libraryRecovery()
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertEqual(try CentralServer.installation().id, before.id)
        XCTAssertFalse(first.contains(before.id.uuidString))
    }
}
