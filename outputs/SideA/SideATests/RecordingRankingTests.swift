import XCTest
@testable import SideA

final class RecordingRankingTests: XCTestCase {
    private func track(_ source: String, _ id: String, _ title: String, _ artist: String, _ album: String = "") -> Track {
        Track(source: source, trackID: id, title: title, artist: artist, album: album, pictureID: "", lyricID: "")
    }
    private func rows(_ json: String) throws -> [RecordingRanking.CatalogSong] {
        try JSONDecoder().decode([RecordingRanking.CatalogSong].self, from: Data(json.utf8))
    }

    func testCoverReferenceFindsOriginalSingerAcrossCatalogsAndDoesNotTrustUploaderOrIDCollision() throws {
        let data = try rows(#"""
        [{"id":2668397359,"name":"晴天 (原唱 周杰伦)","ar":[{"name":"RyaVocal"}],"al":{"name":"晴天"},"pop":100,
          "originCoverType":2,"originSongSimpleData":{"songId":186016,"name":"晴天","artists":[{"name":"周杰伦"}],"albumMeta":{"name":"叶惠美"}}}]
        """#)
        let original = track("joox","opaque","晴天","周杰倫","葉惠美")
        let cover = track("netease","2668397359","晴天 (原唱 周杰伦)","RyaVocal")
        let unconfirmed = track("joox","2668397359","晴天","另一位歌手")
        let uploader = track("bilibili","BV1","晴天","周杰伦")
        let all = [cover,unconfirmed,uploader,original]
        let evidence = RecordingRanking.matchedEvidence(for: all, records: data)
        XCTAssertEqual(evidence[cover.id]?.attribution,.cover)
        XCTAssertEqual(evidence[original.id]?.attribution,.originalSinger)
        XCTAssertNil(evidence[original.id]?.popularity)
        XCTAssertNil(evidence[unconfirmed.id])
        XCTAssertNil(evidence[uploader.id])
        XCTAssertEqual(RecordingRanking.rank(all, query:"周杰伦 晴天",chart:[cover],evidence:evidence).first?.id,original.id)
    }

    func testMissingOriginalUsesConfirmedDetailsAndOutranksSameTitleTracks() throws {
        let search = try rows(#"""
        [{"id":5254423,"name":"菊花台","ar":[{"name":"张晴"}],"originCoverType":2,
          "originSongSimpleData":{"songId":185894,"name":"菊花台","artists":[{"name":"周杰伦"}]}},
         {"id":2648947832,"name":"菊花台(原唱：周杰伦)","originCoverType":2,
          "originSongSimpleData":{"songId":185894,"name":"菊花台","artists":[{"name":"周杰伦"}]}},
         {"id":2692083586,"name":"菊花台","ar":[{"name":"Kevin Yang Wu"}],"originCoverType":1,"pop":100},
         {"id":359234,"name":"菊花台","originCoverType":2,
          "originSongSimpleData":{"songId":185725,"name":"菊花台(Live)","artists":[{"name":"周杰伦"}]}}]
        """#)
        let details = try rows(#"""
        [{"id":185894,"name":"菊花台","ar":[{"name":"周杰伦"}],"al":{"name":"依然范特西","pic":7980255395852522,
          "picUrl":"https://p1.music.126.net/image.jpg"},"originCoverType":1,"pop":95},
         {"id":185725,"name":"菊花台(Live)","ar":[{"name":"周杰伦"}],"originCoverType":0}]
        """#)
        let data = RecordingRanking.CatalogMetadata(search: search, details: details)
        for query in ["菊花台", "周杰倫 菊花台", "菊花台 周杰伦 原唱"] {
            let found = RecordingRanking.originalTracks(query: query, metadata: data, includeNetEase: true)
            XCTAssertEqual(found.map(\.trackID), ["185894"])
            let original = try XCTUnwrap(found.first)
            XCTAssertEqual(original.album, "依然范特西")
            XCTAssertEqual(original.verifiedCatalogOriginal, true)
            let another = track("netease", "2692083586", "菊花台", "Kevin Yang Wu")
            let cover = track("netease", "5254423", "菊花台", "张晴")
            let tracks = [another, cover, original]
            let evidence = RecordingRanking.matchedEvidence(for: tracks, records: data.records)
            XCTAssertEqual(RecordingRanking.rank(tracks, query: query, chart: [another], evidence: evidence).first?.id, original.id)
        }
        XCTAssertTrue(RecordingRanking.originalTracks(query: "菊花台", metadata: data, includeNetEase: false).isEmpty)
        XCTAssertTrue(RecordingRanking.originalTracks(query: "菊花台 张晴", metadata: data, includeNetEase: true).isEmpty)
        XCTAssertTrue(RecordingRanking.originalTracks(query: "菊花台", metadata: .init(search: search), includeNetEase: true).isEmpty)
        let mismatched = try rows(#"[{"id":185894,"name":"菊花台","ar":[{"name":"周杰伦♚"}],"originCoverType":1}]"#)
        XCTAssertTrue(RecordingRanking.originalTracks(query: "菊花台", metadata: .init(search: search, details: mismatched), includeNetEase: true).isEmpty)
        let mistranscribed = try rows(#"[{"id":185894,"name":"菊花台(Live)","ar":[{"name":"周杰伦"}],"originCoverType":1}]"#)
        XCTAssertTrue(RecordingRanking.originalTracks(query: "菊花台", metadata: .init(search: search, details: mistranscribed), includeNetEase: true).isEmpty)
        var customTrack = try XCTUnwrap(RecordingRanking.originalTracks(query: "菊花台", metadata: data, includeNetEase: true).first)
        customTrack.catalogEndpoint = URL(string:"https://example.org/api.php")
        XCTAssertFalse(customTrack.usesNetEaseCatalog)
    }

    func testSearchModifiersPreserveTitleAndDeclaredOriginalRequiresMatchingDetail() throws {
        XCTAssertEqual(RecordingRanking.catalogQuery("原唱：周杰伦 菊花台"), "周杰伦 菊花台")
        XCTAssertEqual(RecordingRanking.catalogQuery("菊花台 原唱"), "菊花台")
        XCTAssertEqual(RecordingRanking.catalogQuery("原唱"), "原唱")
        XCTAssertEqual(RecordingRanking.catalogQuery("寻找原唱"), "寻找原唱")
        let hit = try rows(#"[{"id":55,"name":"原唱","ar":[{"id":8,"name":"歌手"}],"originCoverType":1}]"#)
        let conflict = try rows(#"[{"id":55,"name":"原唱","ar":[{"id":9,"name":"歌手"}],"originCoverType":1}]"#)
        XCTAssertEqual(RecordingRanking.originalTracks(query: "原唱", metadata: .init(search: hit, details: hit), includeNetEase: true).map(\.trackID), ["55"])
        XCTAssertTrue(RecordingRanking.originalTracks(query: "原唱", metadata: .init(search: hit, details: conflict), includeNetEase: true).isEmpty)
    }

    func testExplicitLiveIntentAndStableDefaultStudioPriority() throws {
        let studio = track("netease","156772","再度重相逢","伍佰 & China Blue","泪桥")
        let live = track("netease","531777628","再度重相逢（Live）","伍佰 & China Blue")
        let cover = track("netease","333","再度重相逢","孙露")
        let another = track("netease","111","挪威的森林","伍佰 & China Blue")
        let data: [String: RecordingEvidence] = [
            studio.id: RecordingEvidence(attribution:.original,popularity:80),
            live.id: RecordingEvidence(attribution:.original,popularity:100),
            cover.id: RecordingEvidence(attribution:.cover,popularity:100),
            another.id: RecordingEvidence(attribution:.original,popularity:100)
        ]
        let input = [cover,live,another,studio]
        XCTAssertEqual(RecordingRanking.rank(input,query:"再度重相逢",chart:[cover,live,another],evidence:data).first?.id,studio.id)
        XCTAssertEqual(RecordingRanking.rank(input,query:"再度重相逢 Live",chart:[studio],evidence:data).first?.id,live.id)
        XCTAssertEqual(RecordingRanking.rank(input,query:"再度重相逢 翻唱",chart:[studio],evidence:data).first?.id,cover.id)
        XCTAssertTrue(RecordingRanking.badge(live,query:"再度重相逢",chart:[],evidence:data)?.hasPrefix("原唱歌手 · 现场") == true)
        for title in ["Live Forever", "Cover Me"] {
            let t = track("netease", "1111", title, "Artist")
            XCTAssertEqual(RecordingRanking.badge(t,query:title,chart:[],evidence:[:]), nil)
        }
    }

    func testSameTitleDifferentArtistAndHeatOnlyOnUnambiguousEquivalent() throws {
        let data = try rows(#"""
        [{"id":42,"name":"海浪","ar":[{"name":"deca joins"}],"al":{"name":"Go Slow"},"pop":93,"originCoverType":1},
         {"id":43,"name":"海浪","ar":[{"name":"黄品源"}],"al":{"name":"海浪"},"pop":95,"originCoverType":1}]
        """#)
        let a = track("joox","a","海浪","Deca Joins","Go Slow")
        let b = track("joox","b","海浪","黃品源","海浪")
        let c = track("joox","c","海浪 (Live)","黃品源","海浪")
        let unknown = track("joox","x","海浪","Others")
        let unknown2 = track("custom","z","海浪","Others")
        let all = [unknown,unknown2,c,b,a]
        let evidence = RecordingRanking.matchedEvidence(for:all,records:data)
        XCTAssertEqual(evidence[a.id]?.attribution,.originalSinger)
        XCTAssertEqual(evidence[b.id]?.attribution,.originalSinger)
        XCTAssertEqual(evidence[a.id]?.popularity,93)
        XCTAssertNil(evidence[c.id]?.popularity)
        XCTAssertEqual(RecordingRanking.rank(all,query:"海浪",chart:[],evidence:evidence).first?.id,b.id)
        XCTAssertEqual(RecordingRanking.rank([unknown,unknown2],query:"海浪",chart:[],evidence:evidence),[unknown,unknown2])
    }
}
