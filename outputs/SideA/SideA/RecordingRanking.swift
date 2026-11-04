import Foundation

struct RecordingEvidence: Equatable, Sendable {
    enum Attribution: Sendable { case original, originalSinger, cover, unknown }
    var attribution: Attribution = .unknown
    var popularity: Int?
    var originalTitle: String = ""
    var originalArtists: [String] = []
    var published: Int64?
    var referencedOriginal = false
}

enum RecordingRanking {
    // These are recording annotations, not claims about songwriting, copyright or an earliest release.
    struct CatalogSong: Decodable, Sendable {
        struct Artist: Decodable, Sendable { let name: String; let id: Int64? }
        struct Album: Decodable, Sendable {
            let name: String?
            let picUrl: String?
            let pic: Int64?
        }
        struct Original: Decodable, Sendable {
            let songId: Int64?
            let name: String?
            let artists: [Artist]?
            let albumMeta: Album?
        }
        let id: Int64
        let name: String
        let ar: [Artist]?
        let al: Album?
        let pop: Double?
        let originCoverType: Int?
        let originSongSimpleData: Original?
        let publishTime: Int64?
    }

    private struct SearchReply: Decodable {
        struct Result: Decodable { let songs: [CatalogSong]? }
        let code: Int
        let result: Result?
    }
    private struct DetailReply: Decodable { let code: Int; let songs: [CatalogSong]? }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    private static func catalogReply<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem]) async -> T? {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "music.163.com"; parts.path = path; parts.queryItems = query
        guard let url = parts.url, !Task.isCancelled else { return nil }
        let cache = GDClient.shared
        let key = "original-v1/" + url.absoluteString
        if let saved = cache.cachedData(key: key, maxAge: 86_400),
           let reply = try? JSONDecoder().decode(T.self, from: saved) { return reply }
        let generation = cache.cacheGeneration
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(type, from: data) else { return nil }
        if (reply as? SearchReply)?.code == 200 || (reply as? DetailReply)?.code == 200 {
            cache.cacheData(data, key: key, generation: generation)
        }
        return reply
    }

    private static func details(_ ids: [Int64]) async -> [CatalogSong] {
        guard !ids.isEmpty else { return [] }
        let c = "[" + ids.prefix(250).map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        let reply = await catalogReply(DetailReply.self, path: "/api/v3/song/detail", query: [URLQueryItem(name: "c", value: c)])
        return reply?.code == 200 ? reply?.songs ?? [] : []
    }

    static func catalogQuery(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundary = #"^原唱(?:\s*[:：]\s*|\s+)|(?:\s*[:：]\s*|\s+)原唱$"#
        let stripped = text.replacingOccurrences(of: boundary, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? text : stripped
    }

    private static func wanted(_ name: String, artists: [CatalogSong.Artist]?, for intent: Intent) -> Bool {
        let title = titleKey(name)
        let names = artistSet(artists)
        guard !title.isEmpty, !names.isEmpty, intent.text == title || names.contains(where: {
            intent.text == title + $0 || intent.text == $0 + title
        }) else { return false }
        let markers = versions(name)
        return markers.isEmpty || markers.contains(where: intent.versions.contains)
    }

    struct CatalogMetadata: Sendable {
        var search: [CatalogSong] = []
        var details: [CatalogSong] = []
        var records: [CatalogSong] { details + search }
    }

    static func metadata(for query: String) async -> CatalogMetadata {
        let reply = await catalogReply(SearchReply.self, path: "/api/cloudsearch/pc", query: [
            URLQueryItem(name: "s", value: query), URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: "0")
        ])
        let rows = reply?.code == 200 ? reply?.result?.songs ?? [] : []
        // Fetch the detail even when the original is already in the catalog's metadata search.
        let intent = Intent(query)
        let linked = rows.compactMap { $0.originSongSimpleData?.songId }.filter { $0 > 0 }
        let declared = rows.filter { $0.originCoverType == 1 && wanted($0.name, artists: $0.ar, for: intent) }.prefix(8).map(\.id)
        let ids = Set(linked + declared)
        return CatalogMetadata(search: rows, details: await details(ids.sorted()))
    }

    static func enrich(_ metadata: CatalogMetadata, for tracks: [Track]) async -> CatalogMetadata {
        var enriched = metadata
        let visible = Set(tracks.compactMap { $0.usesNetEaseCatalog ? Int64($0.trackID) : nil })
        let missing = visible.subtracting(metadata.records.map(\.id))
        guard !missing.isEmpty, !Task.isCancelled else { return enriched }
        let additional = await details(missing.sorted())
        enriched.details += additional
        let references = Set(additional.compactMap { $0.originSongSimpleData?.songId })
        enriched.details += await details(references.subtracting(enriched.details.map(\.id)).sorted())
        return enriched
    }

    /// Return only corroborated recordings in the listener's search scope. No stream URL is inferred.
    static func originalTracks(query: String, metadata: CatalogMetadata, includeNetEase: Bool) -> [Track] {
        guard includeNetEase else { return [] }
        let intent = Intent(query)
        let detailsByID = Dictionary(metadata.details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int64>()
        let linked = metadata.records.compactMap { song -> CatalogSong? in
            guard let ref = song.originSongSimpleData, let id = ref.songId, id > 0, id != song.id,
                  let record = detailsByID[id], let title = ref.name, key(title) == key(record.name),
                  sameArtists(ref.artists, record.ar) else { return nil }
            return record
        }
        // A catalog may expose an original directly without a cover reference. Require the same
        // title, artist, ID and explicit declaration on both the search row and the detail.
        let declared = metadata.search.compactMap { hit -> CatalogSong? in
            guard hit.originCoverType == 1, let record = detailsByID[hit.id], record.originCoverType == 1,
                  key(hit.name) == key(record.name), sameArtists(hit.ar, record.ar) else { return nil }
            return record
        }
        return (linked + declared).compactMap { record in
            let id = record.id
            guard id > 0, !seen.contains(id), record.originCoverType != 2,
                  record.originSongSimpleData?.songId.map({ $0 != id }) != true,
                  wanted(record.name, artists: record.ar, for: intent), let artists = record.ar?.map(\.name) else { return nil }
            seen.insert(id)
            let art = record.al?.picUrl.flatMap { URL(string: $0) }.flatMap { url -> URL? in
                guard url.scheme == "https", url.host?.hasSuffix(".music.126.net") == true else { return nil }
                return url
            }
            return Track(source: SearchCatalog.netease.source, trackID: String(id), title: record.name,
                         artist: artists.joined(separator: " / "), album: record.al?.name ?? "",
                         pictureID: record.al?.pic.map(String.init) ?? "", lyricID: String(id),
                         artworkURL: art, verifiedCatalogOriginal: true)
        }
    }

    static func sameRelease(_ first: Track, _ second: Track) -> Bool {
        let artist = artistSet(first.artist)
        let album = key(first.album)
        return !artist.isEmpty && !album.isEmpty && !key(first.title).isEmpty
            && key(first.title) == key(second.title) && artist == artistSet(second.artist) && album == key(second.album)
    }

    private static func folded(_ text: String) -> String {
        if let existing = forms.object(forKey: text as NSString) { return existing as String }
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        let result = simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        forms.setObject(result as NSString, forKey: text as NSString)
        return result
    }
    private static let forms: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2048
        return cache
    }()
    private static func key(_ value: String) -> String {
        folded(value).components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    // Only strip parentheses that actually annotate a version. Legitimate title subtitles survive.
    private static func titleKey(_ text: String) -> String {
        let value = folded(text)
        let annotations = #"\s*[(\[【]([^()\[\]【】]*?(?:live|现场|翻唱|原唱|cover|伴奏|inst\.|instrumental|纯音乐|remix|混音|钢琴版|演奏版|重制版|remaster|加速版|降速版)[^()\[\]【】]*)[)\]】]"#
        return key(value.replacingOccurrences(of: annotations, with: "", options: .regularExpression))
    }
    private static func artistSet(_ value: String) -> Set<String> {
        Set(value.components(separatedBy: " / ").map(key).filter { !$0.isEmpty })
    }
    private static func artistSet(_ values: [CatalogSong.Artist]?) -> Set<String> {
        Set((values ?? []).map { key($0.name) }.filter { !$0.isEmpty })
    }
    private static func sameArtists(_ left: [CatalogSong.Artist]?, _ right: [CatalogSong.Artist]?) -> Bool {
        guard let left, let right, !left.isEmpty, left.count == right.count else { return false }
        // Preserve punctuation in handles (周杰伦♚ is a different account), and check artist IDs when present.
        func names(_ values: [CatalogSong.Artist]) -> Set<String> {
            Set(values.map { folded($0.name).components(separatedBy: .whitespacesAndNewlines).joined() })
        }
        let expected = names(left)
        guard !expected.contains(""), expected == names(right) else { return false }
        let leftIDs = left.compactMap(\.id), rightIDs = right.compactMap(\.id)
        return leftIDs.count != left.count || rightIDs.count != right.count || Set(leftIDs) == Set(rightIDs)
    }
    private struct Reference {
        let id: Int64
        let title: String
        let artists: Set<String>
    }
    static func matchedEvidence(for tracks: [Track], records: [CatalogSong]) -> [String: RecordingEvidence] {
        let index = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let refs = records.compactMap { song -> Reference? in
            guard let origin = song.originSongSimpleData, let id = origin.songId, let title = origin.name else { return nil }
            return Reference(id: id, title: titleKey(title), artists: artistSet(origin.artists))
        }
        // Normalize catalog attributes once, not for each result-to-result comparison.
        let aligned = records.map { ($0, titleKey($0.name), artistSet($0.ar), key($0.al?.name ?? ""), key($0.name)) }
        let originals = Set(records.compactMap { song -> Int64? in
            guard let ref = song.originSongSimpleData, let id = ref.songId, song.id != id,
                  let original = index[id], let title = ref.name, key(title) == key(original.name),
                  sameArtists(ref.artists, original.ar) else { return nil }
            return id
        })
        var output = [String: RecordingEvidence]()
        for t in tracks {
            if t.usesNetEaseCatalog, let id = Int64(t.trackID), let song = index[id] {
                let relation = song.originSongSimpleData
                let a: RecordingEvidence.Attribution
                if (relation?.songId != nil && relation?.songId != id) || song.originCoverType == 2 { a = .cover }
                else if song.originCoverType == 1 || originals.contains(id) { a = .original }
                else { a = .unknown }
                output[t.id] = RecordingEvidence(attribution: a, popularity: heat(song.pop), originalTitle: relation?.name ?? "",
                        originalArtists: relation?.artists?.map(\.name) ?? [], published: song.publishTime,
                        referencedOriginal: a == .original && originals.contains(id))
                continue
            }
            // A Bilibili artist field credits the uploader; a matching account name is not evidence.
            guard t.source != "bilibili", !t.usesNetEaseCatalog else { continue }
            let title = titleKey(t.title), artists = artistSet(t.artist), album = key(t.album), full = key(t.title)
            guard !title.isEmpty, !artists.isEmpty else { continue }
            let candidates = aligned.filter { $0.1 == title && $0.2 == artists }
            let hasOriginal = candidates.contains { $0.0.originCoverType == 1 || originals.contains($0.0.id) }
                || refs.contains { $0.title == title && $0.artists == artists }
            let exact = candidates.filter { !album.isEmpty && $0.3 == album && $0.4 == full }
            // Even identical title, artist and album across catalogs do not establish the same master.
            // Treat this as corroborated singer identity, not proof of the earliest recording.
            let unambiguous = Set(exact.map { $0.0.id }).count == 1 ? exact.first?.0 : nil
            let relation = unambiguous?.originSongSimpleData
            let isCover = unambiguous?.originCoverType == 2 || relation?.songId.map { $0 != unambiguous?.id } == true
            let conflictingCover = candidates.contains { item in
                item.0.originCoverType == 2 || item.0.originSongSimpleData?.songId.map { $0 != item.0.id } == true
            }
            let explicitOriginal = unambiguous.map { $0.originCoverType == 1 || originals.contains($0.id) } == true
            let corroborated = explicitOriginal || (hasOriginal && !conflictingCover)
            let attribution: RecordingEvidence.Attribution = isCover ? .cover : corroborated ? .originalSinger : .unknown
            if attribution != .unknown || unambiguous != nil {
                output[t.id] = RecordingEvidence(attribution: attribution, popularity: heat(unambiguous?.pop),
                        originalTitle: relation?.name ?? "", originalArtists: relation?.artists?.map(\.name) ?? [],
                        published: unambiguous?.publishTime)
            }
        }
        return output
    }
    private static func heat(_ pop: Double?) -> Int? {
        guard let pop, pop.isFinite, (0...100).contains(pop) else { return nil }
        return Int(pop.rounded())
    }

    private enum Version: String, CaseIterable {
        case live = "现场", instrumental = "伴奏/演奏", remix = "改编", cover = "翻唱"
        var pattern: String {
            switch self {
            case .live: #"(?:\blive\b|live版|演唱会|现场)"#
            case .instrumental: #"(?:伴奏|纯音乐|钢琴版|演奏版|\binstrumental\b|\binst\.)"#
            case .remix: #"(?:混音|重制版|加速版|降速版|\bremix\b|\bremaster(?:ed)?\b)"#
            case .cover: #"(?:翻唱|\bcover\b)"#
            }
        }
    }
    private static func versions(_ value: String) -> [Version] {
        let folded = folded(value)
        return Version.allCases.filter { version in
            let token = version.pattern
            // English words such as “Live” and “Cover” may be the title itself. Require release-note
            // context (parenthesis, conventional suffix or a separated version descriptor).
            let annotation = #"[\(\[【][^()\[\]【】]*"# + token + #"[^()\[\]【】]*[\)\]】]"#
            let suffix = #".+?\s*"# + token + #"(?:\s*(?:版|版本|version))?\s*$"#
            let descriptor = #".+?\s[-–—]\s*"# + token + #"(?:\s+|$)"#
            return [annotation, suffix, descriptor].contains { folded.range(of: $0, options: .regularExpression) != nil }
        }
    }
    private struct Intent {
        let text: String
        let versions: [Version]
        init(_ raw: String) {
            versions = RecordingRanking.versions(raw)
            let stem = versions.reduce(folded(raw)) { $0.replacingOccurrences(of: $1.pattern, with: "", options: .regularExpression) }
            text = key(catalogQuery(stem))
        }
    }
    private static func relevance(_ q: String, _ track: Track, _ e: RecordingEvidence?) -> Int {
        if q.isEmpty { return 0 }
        let title = titleKey(track.title), artists = artistSet(track.artist)
        let artistMatch = artists.contains(q) || key(track.artist) == q
        if q == title || artistMatch || artists.contains(where: { q == title + $0 || q == $0 + title }) { return 5 }
        if !title.isEmpty {
            let fragment: String
            if q.hasPrefix(title) { fragment = String(q.dropFirst(title.count)) }
            else if q.hasSuffix(title) { fragment = String(q.dropLast(title.count)) }
            else { fragment = "" }
            if fragment.count >= 2 && artists.contains(where: { $0.contains(fragment) }) { return 4 }
        }
        if let e, !e.originalTitle.isEmpty {
            let work = titleKey(e.originalTitle)
            if q == work || e.originalArtists.contains(where: { q == work + key($0) || q == key($0) + work }) { return 4 }
        }
        if key(track.title) == q { return 5 }
        if q.count >= 2, (title.contains(q) || (!title.isEmpty && q.contains(title))) { return 3 }
        if artists.contains(where: { !$0.isEmpty && ($0.contains(q) || q.contains($0)) }) { return 2 }
        return 0
    }
    private struct Ranked {
        let track: Track
        let relevance, wanted, version, chart, popularity: Int
        let referenced: Bool
        let released: Int64
        let index: Int
    }
    static func rank(_ tracks: [Track], query: String, chart: [Track], evidence: [String: RecordingEvidence]) -> [Track] {
        let intent = Intent(query)
        let positions = Dictionary(chart.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        let scored = tracks.enumerated().map { i, t -> Ranked in
            let e = evidence[t.id]; var markers = versions(t.title)
            if e?.attribution == .cover && !markers.contains(.cover) { markers.append(.cover) }
            let wanted = intent.versions.filter(markers.contains).count
            let category: Int
            if markers.contains(.cover) { category = 0 }
            else if markers.isEmpty {
                switch e?.attribution { case .original, .originalSinger: category = 6; default: category = 3 }
            } else { category = e?.attribution == .original || e?.attribution == .originalSinger ? 2 : 1 }
            let release = e?.published ?? 0
            return Ranked(track: t, relevance: relevance(intent.text,t,e), wanted: wanted, version: category,
                          chart: positions[t.id] ?? Int.max, popularity: e?.popularity ?? -1, referenced: e?.referencedOriginal == true,
                          released: category >= 5 && release > 0 ? release : .max, index: i)
        }
        return scored.sorted { a,b in
            if a.relevance != b.relevance { return a.relevance > b.relevance }
            if a.wanted != b.wanted { return a.wanted > b.wanted }
            if a.version != b.version { return a.version > b.version }
            if a.referenced != b.referenced { return a.referenced }
            if a.chart != b.chart { return a.chart < b.chart }
            if a.popularity != b.popularity { return a.popularity > b.popularity }
            if a.released != b.released { return a.released < b.released }
            return a.index < b.index
        }.map(\.track)
    }
    static func badge(_ track: Track, query: String, chart: [Track], evidence: [String: RecordingEvidence]) -> String? {
        let entry = evidence[track.id]
        var notes = [String]()
        switch entry?.attribution {
        case .original: if !versions(track.title).contains(.cover) { notes.append(versions(track.title).isEmpty ? "原唱" : "原唱歌手") }
        case .originalSinger: if !versions(track.title).contains(.cover) { notes.append("原唱歌手") }
        case .cover: notes.append("翻唱")
        default: break
        }
        for variant in versions(track.title) where !notes.contains(variant.rawValue) { notes.append(variant.rawValue) }
        if let rank = chart.firstIndex(where: { $0.id == track.id }) { notes.append("网易热歌榜 #\(rank+1)") }
        else if let pop = entry?.popularity { notes.append("网易热度 \(pop)") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}
