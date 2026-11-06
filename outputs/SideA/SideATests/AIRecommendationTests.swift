import XCTest
@testable import SideA

final class AIRecommendationTests: XCTestCase {
    private func song(_ id: String) -> Track {
        Track(source: "netease", trackID: id, title: id, artist: "Artist", album: "Album", pictureID: "", lyricID: id)
    }
    func testRankingRejectsInventedTracksAndDuplicatesPreservingNativeMetadata() {
        let a = song("a"), b = song("b"), c = song("c")
        let result = AIRecommendations.Result(profile_summary: "", ranked: [
            .init(id: AIRecommendations.hash(b.id), reason: "repeat preference"),
            .init(id: "invented", reason: "unknown"), .init(id: AIRecommendations.hash(b.id), reason: "duplicate")])
        XCTAssertEqual(AIRecommendations.reorder([a,b,c], result: result), [b,a,c])
    }
    func testSummaryAggregatesBehaviorWithoutSendingPlaybackURLs() throws {
        var track = song("private"); track.catalogEndpoint = URL(string: "https://catalog.invalid/private")
        let old = ListeningDay(track: track,date:Date().addingTimeInterval(-40*86400),replays:100)
        let recent = ListeningDay(track: track,date:Date(),choices:2,replays:1,completions:1,quickSkips:1)
        let input = AIRecommendations.input(saved: SavedLibrary(favorites:[track],listening:[old,recent,recent]),candidates:[track])
        XCTAssertEqual(input.profile.listening.first?.replays,2)
        XCTAssertEqual(input.profile.listening.first?.quick_skips,2)
        let data = try XCTUnwrap(AIRecommendations.encoded(input))
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("catalog.invalid"))
        XCTAssertEqual(input.candidates.first?.id.count,64)
    }
    func testDiscoveryReservesUnheardPlacesAndRotatesPastShownRecordings() {
        let familiar = (0..<8).map { song("known-\($0)") }, fresh = (0..<24).map { song("new-\($0)") }
        let saved = SavedLibrary(favorites: familiar)
        let first = AIRecommendations.discoveryOrder(familiar + fresh, saved: saved, shown: [], limit: 24)
        XCTAssertEqual(first.filter { !familiar.contains($0) }.count, 18)
        XCTAssertEqual(first.prefix(4).map(\.title), ["new-0", "new-1", "new-2", "known-0"])
        let next = AIRecommendations.discoveryOrder(familiar + fresh, saved: saved, shown: first.map(AIRecommendations.recordingKey), limit: 8)
        XCTAssertTrue(Set(next.map(\.id)).isDisjoint(with: first.map(\.id)))
        let duplicate = Track(source:"qq",trackID:"other-source",title:fresh[0].title,artist:fresh[0].artist,album:"Album",pictureID:"",lyricID:"")
        XCTAssertEqual(AIRecommendations.discoveryOrder([fresh[0], duplicate], saved: saved, shown: [], limit: 24).count, 1)
        XCTAssertEqual(AIRecommendations.discoveryOrder(familiar, saved: saved, shown: [], limit: 24).count, 8)
    }
    func testLatestPlayedTrackAndFlagsReachModelEvenWhenDailyRowIsOld() {
        let tracks = (0..<15).map { song("song-\($0)") }
        let saved = SavedLibrary(favorites: [tracks[0]], recent: [tracks[0]], listening: tracks.map { ListeningDay(track:$0,date:Date(),choices:1) })
        let input = AIRecommendations.input(saved:saved,candidates:[tracks[0],song("new")],shown:[AIRecommendations.recordingKey(tracks[0])])
        XCTAssertEqual(input.profile.listening.first?.title, tracks[0].title)
        XCTAssertEqual(input.candidates.first?.familiar,true)
        XCTAssertEqual(input.candidates.first?.recent,true)
        XCTAssertEqual(input.candidates.first?.shown,true)
        XCTAssertEqual(input.candidates.last?.familiar,false)
    }
    func testPendingFromPreviousVersionWithoutDiscoveryFlagsStillDecodes() throws {
        let pending = AIRecommendations.Pending(id:"legacy",fingerprint:"f",revision:"r",created:Date(),input:AIRecommendations.input(saved:SavedLibrary(),candidates:[song("old")]))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(pending)) as? [String:Any])
        var input = raw["input"] as! [String:Any]
        input["candidates"] = [["id":"legacy-song","title":"Old","artist":"Artist","album":"Album"]]
        raw["input"] = input
        let decoded = try JSONDecoder().decode(AIRecommendations.Pending.self,from:JSONSerialization.data(withJSONObject:raw))
        XCTAssertEqual(decoded.id,"legacy")
        XCTAssertNil(decoded.input.candidates.first?.familiar)
    }
    @MainActor func testManualRefreshAvoidsPreviousBatchAndPersistsAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("library.json")
        let library = LibraryStore(file:file), tracks = (0..<60).map { song("track-\($0)") }
        let first = library.recommendations(from:tracks)
        library.nextRecommendations(from:tracks)
        let next = library.recommendations(from:tracks)
        XCTAssertTrue(Set(next.map(\.id)).isDisjoint(with:first.map(\.id)))
        library.nextRecommendations(from:tracks)
        XCTAssertEqual(library.recommendationTurn,1)
        XCTAssertEqual(LibraryStore(file:file).recommendations(from:tracks),next)
    }
    func testSlowJobPersistsAndResumesByIDWithoutAnotherModelRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowAIProtocol.self]
        let server = PairedServer(base: URL(string: "https://music.test")!, token: "synthetic")
        let firstSession = CentralServer.session(configuration: configuration)
        let input = AIRecommendations.input(saved: SavedLibrary(favorites:[song("a")]), candidates:[song("b")])
        let job = try await AIRecommendations.submit(input, server:server, using:firstSession)
        XCTAssertEqual(job.status,"queued")
        let pending = AIRecommendations.Pending(id:job.id,fingerprint:"snapshot",revision:"revision",created:Date(),input:input)
        let durable = try JSONEncoder().encode(pending)
        firstSession.invalidateAndCancel() // Simulated background/process boundary.
        let recovered = try JSONDecoder().decode(AIRecommendations.Pending.self,from:durable)
        let resumedSession = CentralServer.session(configuration:configuration)
        defer { resumedSession.invalidateAndCancel() }
        XCTAssertFalse(recovered.expired)
        let running = try await AIRecommendations.poll(recovered.id,server:server,using:resumedSession)
        XCTAssertEqual(running.status,"running")
        let complete = try await AIRecommendations.poll(recovered.id,server:server,using:resumedSession)
        XCTAssertEqual(complete.status,"succeeded")
        XCTAssertEqual(SlowAIProtocol.counts().posts,1)
        XCTAssertEqual(SlowAIProtocol.counts().polls,2)
        XCTAssertTrue(AIRecommendations.Pending(id:"expired",fingerprint:"",revision:"",created:Date().addingTimeInterval(-21601),input:input).expired)
    }
    @MainActor func testCachedRankingSurvivesListeningChangesButHonorsExplicitFeedback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let a = song("a"), b = song("b"), c = song("c")
        let result = AIRecommendations.Result(profile_summary: "",ranked:[.init(id:AIRecommendations.hash(b.id),reason:"preferred")])
        try JSONEncoder().encode(AIRecommendations.Cache(fingerprint:"old listening snapshot",expires:Date().addingTimeInterval(3600),result:result,revision:"test"))
            .write(to:file.appendingPathExtension("ai"))
        let library = LibraryStore(file:file)
        library.record(a,event:"manualPlay",listened:0,duration:180)
        XCTAssertEqual(library.recommendations(from:[a,b,c]).first?.id,b.id)
        library.record(b,event:"skip",listened:4,duration:180)
        XCTAssertFalse(library.recommendations(from:[a,b,c]).contains(b))
        library.dislike(c)
        XCTAssertFalse(library.recommendations(from:[a,b,c]).contains(c))
        library.trackingEnabled = false
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.appendingPathExtension("ai").path))
        XCTAssertEqual(library.recommendations(from:[a,b,c]).first?.id,a.id)
    }

}

private final class SlowAIProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var posts = 0, polls = 0
    static func counts() -> (posts: Int,polls: Int) { lock.lock(); defer { lock.unlock() }; return (posts,polls) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        if request.httpMethod == "POST" { Self.posts += 1 } else { Self.polls += 1 }
        let status = request.httpMethod == "POST" ? "queued" : (Self.polls == 1 ? "running" : "succeeded")
        Self.lock.unlock()
        var job: [String:Any] = ["id":"synthetic-task","status":status]
        if status == "succeeded" { job["result"] = ["profile_summary":"synthetic","ranked":[["id":AIRecommendations.hash("netease:b"),"reason":"synthetic"]]] }
        let data = try! JSONSerialization.data(withJSONObject:["task":job])
        let response = HTTPURLResponse(url:url,statusCode:request.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic" ? 200 : 401,httpVersion:nil,headerFields:nil)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
