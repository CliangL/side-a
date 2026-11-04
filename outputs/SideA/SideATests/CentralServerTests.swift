import XCTest
@testable import SideA

private final class CentralFixture: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        var code = 200
        var data = Data("{}".utf8)
        switch url.path {
        case "/v1/enroll":
            if request.httpMethod != "POST" || auth != "SideA-Setup fixture-ticket" { code = 400 }
            data = Data(#"{"token":"device-test-credential"}"#.utf8)
        case "/v1/music":
            if auth != "Bearer device-test-credential" || param("name") == "revoked" { code = 401 }
            else if param("types") == "url", param("id") == "unavailable" {
                code = 502; data = Data(#"{"error":"QQ 音乐未授予当前账号该录音的所选音质"}"#.utf8)
            }
            else if param("types") == "search" {
                Self.lock.lock(); Self.requests += 1; let n = Self.requests; Self.lock.unlock()
                data = Data(#"[{"name":"Central N","artist":["Test"],"source":"central","id":"opaque.1","pic_id":"pic","lyric_id":"lyr"}]"#.replacingOccurrences(of: "Central N", with: "Central \(n)").utf8)
            } else if param("types") == "lyric" {
                data = Data(#"{"lyric":"[00:01.00]Hello"}"#.utf8)
            } else if param("types") == "url" {
                data = Data(#"{"url":"https://cdn.test/tone.flac","br":999}"#.utf8)
            }
        case "/plain":
            // A custom catalog on the *same host* must never get device credentials.
            code = auth == nil ? 200 : 403
            data = Data("[]".utf8)
        case "/tone.flac":
            code = url.host == "cdn.test" && auth == nil ? 206 : 403
            data = Data("fLaC".utf8) + Data(repeating: 0, count: 38)
        default: code = 404
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class CentralServerTests: XCTestCase {
    func testPairAndFetchCurrentCatalogWithIsolatedCredentials() async throws {
        try XCTSkipUnless(LocalStorage.testID != nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CentralFixture.self]
        let session = CentralServer.session(configuration: config)
        defer { session.invalidateAndCancel() }
        let server = try await CentralServer.enroll(.init(id: UUID(), automatic: true), ticket: "fixture-ticket", name: "iPhone", using: session)
        let previous = try CentralServer.read()
        defer {
            if let previous { try? CentralServer.save(previous) } else { try? CentralServer.remove() }
        }
        try CentralServer.save(server)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SearchCatalogSettings(defaults: defaults)
        XCTAssertEqual(settings.activeCatalogs.map(\.endpoint), [server.endpoint])
        XCTAssertEqual(settings.activeCatalogs.map(\.provider), [nil])

        let api = GDClient(configuration: config)
        let first = try await api.search("test", catalog: server.catalog)
        let second = try await api.search("test", catalog: server.catalog)
        let track = try XCTUnwrap(first.first)
        XCTAssertEqual(track.id, second.first?.id)
        XCTAssertNotEqual(track.title, second.first?.title)
        XCTAssertEqual(track.managedCatalog, true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(track), as: UTF8.self).contains(server.token))
        let lyric = await api.lyrics(track)
        XCTAssertEqual(lyric.first?.text, "Hello")
        let stream = try await api.stream(track, bitrate: 999)
        XCTAssertTrue(stream.isFLAC)
        let denied = Track(source: "central", trackID: "unavailable", title: "Unavailable", artist: "Test", album: "", pictureID: "", lyricID: "",
                           catalogEndpoint: server.endpoint, managedCatalog: true)
        do {
            _ = try await api.stream(denied, bitrate: 999)
            XCTFail("restricted recording returned a stream")
        } catch { XCTAssertEqual(error.localizedDescription, "QQ 音乐未授予当前账号该录音的所选音质") }
        let plain = try SearchCatalog.custom(name: "Custom", source: "central", address: "https://music.cliang.top/plain")
        let custom = try await api.search("test", catalog: plain)
        XCTAssertTrue(custom.isEmpty)
        do {
            _ = try await api.search("revoked", catalog: server.catalog)
            XCTFail("revoked device obtained data")
        } catch { XCTAssertTrue(error.localizedDescription.contains("授权已失效")) }
        try CentralServer.remove()
        do {
            _ = try await api.search("test", catalog: server.catalog)
            XCTFail("unpaired device used cached results")
        } catch { XCTAssertTrue(error.localizedDescription.contains("尚未连接")) }
    }

    func testRejectPlainHTTPURLsWithSecretsOrQuery() {
        for url in ["http://host", "https://user:pass@host/private", "https://host/?token=secret", "https://host/#frag"] {
            XCTAssertThrowsError(try CentralServer.base(url))
        }
    }
}
