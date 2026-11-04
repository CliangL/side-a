import Foundation
import XCTest
@testable import SideA

private final class CatalogFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let type = params.first { $0.name == "types" }?.value
        let source = params.first { $0.name == "source" }?.value
        let id = params.first { $0.name == "id" }?.value
        var status = 200
        let data: Data
        if url.host?.hasSuffix(".example.test") != true { status = 404; data = Data() }
        else if url.path == "/song.flac", request.value(forHTTPHeaderField: "Range") == "bytes=0-63" {
            var header = Data(count: 42)
            header.replaceSubrange(0..<4, with: Data("fLaC".utf8))
            data = header
        } else if url.path != "/api.php" || source != "tencent" { status = 400; data = Data() }
        else {
            let json: String
            switch (type, id) {
            case ("search", nil):
                json = #"[{"name":"Recording","artist":["Test Singer"],"source":"tencent","id":"MID-1","pic_id":"PIC-1","lyric_id":"LRC-1"}]"#
            case ("url", "MID-1"): json = "{\"url\":\"https://\(url.host!)/song.flac\",\"br\":980}"
            case ("pic", "PIC-1"): json = "{\"url\":\"https://\(url.host!)/art.jpg\"}"
            case ("lyric", "LRC-1"): json = #"{"lyric":"[00:07.20]Test lyric"}"#
            default: status = 400; json = "{}"
            }
            data = Data(json.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SearchCatalogTests: XCTestCase {
    @MainActor func testExpandedScopesPersistAndRetainRecordingIdentity() throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchCatalogSettings(defaults: defaults)
        for scope in SearchCatalogSettings.scopes {
            settings.selectProvider(scope.id)
            let restored = SearchCatalogSettings(defaults: defaults)
            XCTAssertEqual(restored.selectedProvider, scope.id)
            XCTAssertEqual(restored.activeCatalogs.first?.provider, scope.id == "all" ? nil : scope.id)
            if scope.id == "all" { continue }
            let data = Data(("[{\"source\":\"central\",\"id\":\"" + scope.id + ".song\",\"name\":\"Song\"},{\"source\":\"central\",\"id\":\"other.song\",\"name\":\"Wrong\"}]").utf8)
            let filtered = try GDClient.shared.parseSearch(data, catalog: restored.selectedCatalog)
            let aggregate = try GDClient.shared.parseSearch(data, catalog: restored.central)
            XCTAssertEqual(filtered.count, 1)
            XCTAssertEqual(filtered.first?.id, aggregate.first?.id)
        }
    }

    @MainActor func testQQScopePersistsAndRejectsOtherCentralRecordings() throws {
        let suite = "qq-scope-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchCatalogSettings(defaults: defaults)
        settings.selectQQ(true)
        let restored = SearchCatalogSettings(defaults: defaults)
        let qq = restored.qqMusic
        XCTAssertTrue(restored.isQQ)
        XCTAssertEqual(restored.activeCatalogs, [qq])
        let central = SearchCatalog(name: "统一曲库", source: "central", endpoint: qq.endpoint, managed: true)
        let data = Data(#"[{"source":"central","id":"wy.abc","name":"Other","provider_name":"网易云音乐"},{"source":"central","id":"qq.def","name":"QQ","provider_name":"QQ 音乐"},{"source":"central","id":"qq.bad","provider_id":"wy","name":"Conflicting"}]"#.utf8)
        let all = try GDClient.shared.parseSearch(data, catalog: central)
        let only = try GDClient.shared.parseSearch(data, catalog: qq)
        XCTAssertEqual(only.map(\.trackID), ["qq.def"])
        XCTAssertEqual(only.first?.id, all[1].id)
        XCTAssertEqual(only.first?.catalogLabel, "QQ 音乐")
        XCTAssertFalse(qq.contains(all[0]))
        XCTAssertTrue(qq.contains(all[1]))
        settings.selectQQ(false)
        XCTAssertFalse(settings.activeCatalogs.contains(qq))
    }

    func testOriginSurvivesReconfigureAndUsesOriginalEndpointForEveryOperation() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CatalogFixture.self]
        let api = GDClient(configuration: cfg)
        let catalog = try SearchCatalog.custom(name: "自己的 QQ 曲库", source: " TENCENT ",
                                               address: "https://\(UUID().uuidString).example.test:443/api.php")
        let tracks = try await api.search("Recording", catalog: catalog)
        let track = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(try XCTUnwrap(tracks.first)))
        XCTAssertEqual(track.catalogEndpoint, catalog.endpoint)
        XCTAssertEqual(track.source, "tencent")
        XCTAssertEqual(track.trackID, "MID-1")
        let artwork = await api.artwork(track)
        XCTAssertEqual(artwork?.host, catalog.endpoint.host)
        let lyrics = await api.lyrics(track)
        XCTAssertEqual(lyrics.first?.text, "Test lyric")
        let stream = try await api.stream(track, bitrate: 999)
        XCTAssertTrue(stream.isFLAC)
        XCTAssertEqual(stream.url.host, catalog.endpoint.host)
    }

    func testGDRequestProtectsOpaqueIDsAndSearchTermsFromFormDecoding() throws {
        let word = "C++ & 声音", tid = "bLnv0PqDX_qAlIqapc+Okw=="
        let req = try GDClient.request(endpoint: SearchCatalog.gdEndpoint, params: ["types":"url", "id":tid, "name":word])
        let url = try XCTUnwrap(req.url)
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        let items = try XCTUnwrap(URLComponents(url:url, resolvingAgainstBaseURL:false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "id" }?.value, tid)
        XCTAssertEqual(items.first { $0.name == "name" }?.value, word)
    }

    func testRejectsWrongSourceAndAmbiguousResults() throws {
        let expected = try SearchCatalog.custom(name:"custom", source:"tencent", address:"https://example.test/api.php")
        for actual in [#"{"id":"1","name":"One","source":"netease"}"#, #"{"id":"1","name":"One"}"#] {
            XCTAssertThrowsError(try GDClient.shared.parseSearch(Data("[\(actual)]".utf8), catalog: expected))
        }
        let rows = Data(#"[{"id":"1","name":"Wrong","source":"netease"},{"id":"1","name":"Right","source":"tencent"}]"#.utf8)
        XCTAssertEqual(try GDClient.shared.parseSearch(rows, catalog: expected).map(\.title), ["Right"])
    }

    func testCatalogIdentityIsBackwardCompatibleAndCustomNetEaseIsIsolated() throws {
        let old = try XCTUnwrap(Track.starterTracks.first)
        let oldData = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(Track.self, from: oldData).catalogEndpoint)
        XCTAssertEqual(old.id, "netease:" + old.trackID)
        var custom = old
        custom.catalogEndpoint = try SearchCatalog.custom(name:"",source:"netease", address:"HTTPS://ExAmPlE.Test:443/api.php").endpoint
        XCTAssertEqual(custom.catalogEndpoint?.absoluteString,"https://example.test/api.php")
        XCTAssertNotEqual(custom.id, old.id)
        XCTAssertFalse(custom.usesNetEaseCatalog)
        XCTAssertNil(custom.localArtworkURL)
    }

    func testProvidersPaginateIndependentlyAndMergeInCatalogOrder() throws {
        let catalogs = SearchCatalog.builtIns
        let a = catalogs[0], b = catalogs[1]
        func song(_ n: String, _ catalog: SearchCatalog) -> Track {
            Track(source: catalog.source, trackID: n, title: n, artist: "Artist", album: "", pictureID: "", lyricID: n)
        }
        let first = song("one", a), other = song("one", b), second = song("two", a)
        var pages = SearchPages()
        pages.fail(b, message: "暂不可用")
        pages.accept([first, second], from: a, page: 1)
        XCTAssertEqual(pages.merged(in: catalogs).map(\.id), [first.id, second.id])
        XCTAssertEqual(pages.nextPage(for: a), 2)
        XCTAssertEqual(pages.nextPage(for: b), 1)
        pages.accept([other], from: b, page: 1)
        XCTAssertNil(pages.entries[b]?.error)
        XCTAssertEqual(pages.merged(in: catalogs).map(\.id), [first.id, other.id, second.id])
        pages.accept([second], from: a, page: 2)
        XCTAssertNil(pages.nextPage(for: a))
        XCTAssertEqual(pages.nextPage(for: b), 2)
    }

    @MainActor func testOldCustomSelectionMigratesToAllAndNeverQueriesPreviousEndpoint() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for selection in ["custom", "all", "managed", "netease", "bilibili", "joox"] {
            defaults.set(Data("""
            {"selected":"\(selection)","custom":{"endpoint":"https://old.example.test/api","source":"a","name":"过去的接口"}}
            """.utf8), forKey: "sidea.search.catalog.v1")
            let settings = SearchCatalogSettings(defaults: defaults)
            XCTAssertFalse(settings.isQQ)
            XCTAssertEqual(settings.activeCatalogs, [settings.central])
        }
    }
}
