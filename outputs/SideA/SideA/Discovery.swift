import Foundation
import Combine

// NetEase is a GD playback source. Its public charts and similar-song lists carry the
// same recording IDs, including distinct live, remastered and original versions.
@MainActor
final class DiscoveryStore: ObservableObject {
    @Published private(set) var hot: [Track] = []
    @Published private(set) var newReleases: [Track] = []
    @Published private(set) var hotSource = "网易云音乐 · 热歌榜"
    @Published private(set) var newSource = "网易云音乐 · 近七天发行"
    @Published private(set) var notice: String?
    @Published private(set) var isLoading = false

    private var genreRequests = [String: Task<[String], Never>]()
    private var releaseDates = [String: Date]()
    private var loaded = [Chart: Date]()
    private let session: URLSession
    private enum Chart: Int, CaseIterable {
        case hot = 3_778_678
        case new = 3_779_629
        var key: String { "chart/v1/\(rawValue)" }
        var name: String { self == .hot ? "热歌榜" : "新歌榜" }
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 9
        config.timeoutIntervalForResource = 16
        session = URLSession(configuration: config)
        for chart in Chart.allCases {
            if let data = GDClient.shared.cachedData(key: chart.key, maxAge: 7 * 86_400),
               let snapshot = try? JSONDecoder().decode(ChartSnapshot.self, from: data) {
                apply(snapshot, to: chart)
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        let needed = Chart.allCases.filter { force || Date().timeIntervalSince(loaded[$0] ?? .distantPast) > 3_600 }
        guard !needed.isEmpty else { return }
        let generation = GDClient.shared.cacheGeneration
        isLoading = true
        defer { isLoading = false }
        await withTaskGroup(of: (Chart, ChartSnapshot?).self) { group in
            for chart in needed {
                group.addTask { [session] in
                    do {
                        let data = try await Self.request(path: "/api/playlist/detail", items: [
                            URLQueryItem(name: "id", value: String(chart.rawValue))
                        ], session: session)
                        let reply = try JSONDecoder().decode(ChartReply.self, from: data)
                        guard reply.code == 200, reply.result.id == chart.rawValue else { return (chart, nil) }
                        let entries = reply.result.tracks.compactMap(\.entry)
                        guard !entries.isEmpty else { return (chart, nil) }
                        let snapshot = ChartSnapshot(entries: entries, updated: Self.asDate(reply.result.updateTime), fetched: Date())
                        return (chart, snapshot)
                    } catch { return (chart, nil) }
                }
            }
            var failed = [String]()
            for await (chart, snapshot) in group {
                if let snapshot {
                    apply(snapshot, to: chart)
                    if let data = try? JSONEncoder().encode(snapshot) {
                        GDClient.shared.cacheData(data, key: chart.key, generation: generation)
                    }
                } else if !Task.isCancelled {
                    failed.append(chart.name)
                }
            }
            if !Task.isCancelled {
                notice = failed.isEmpty ? nil : "未能刷新" + failed.joined(separator: "、") + "，请下拉重试。已有列表保留上次更新时间。"
            }
        }
    }

    private func apply(_ snapshot: ChartSnapshot, to chart: Chart) {
        loaded[chart] = snapshot.fetched
        let stamp = snapshot.updated.map(Self.dateLabel) ?? Self.dateLabel(snapshot.fetched)
        let suffix = snapshot.updated == nil ? "读取" : "更新"
        var seen = Set<String>()
        let entries = snapshot.entries.filter { seen.insert($0.track.id).inserted }
        if chart == .hot {
            hot = entries.map(\.track)
            hotSource = "网易云热歌榜 · \(stamp)\(suffix)"
        } else {
            let today = Self.calendar.startOfDay(for: Date())
            let cutoff = Self.calendar.date(byAdding: .day, value: -6, to: today) ?? today
            let qualified = entries.filter { item in
                guard let date = item.released else { return false }
                return date >= cutoff && date <= Date()
            }
            releaseDates = Dictionary(uniqueKeysWithValues: qualified.compactMap { item in
                item.released.map { (item.track.id, $0) }
            })
            newReleases = qualified.map(\.track)
            newSource = "网易云新歌榜 · \(stamp)\(suffix)"
        }
    }

    func releaseLabel(for track: Track) -> String? {
        releaseDates[track.id].map { Self.dateLabel($0) + " 发行" }
    }

    // A seed and its few nearest neighbors are enriched on demand. Do not query
    // hundreds of individual song-info pages when a full chart first appears.
    func genres(for track: Track) async -> [String] {
        guard track.usesNetEaseCatalog, Int64(track.trackID) != nil else { return track.genres }
        let key = "chart/genre/v1/" + track.id
        if let data = GDClient.shared.cachedData(key: key, maxAge: 30 * 86_400),
           let stored = try? JSONDecoder().decode([String].self, from: data) { return stored }
        if let task = genreRequests[key] { return await task.value }
        let generation = GDClient.shared.cacheGeneration
        let task = Task { [session] in
            do {
                let data = try await Self.request(path: "/api/song/play/about/block/page",
                                                  items: [URLQueryItem(name: "songId", value: track.trackID)], session: session)
                let reply = try JSONDecoder().decode(GenreReply.self, from: data)
                guard reply.code == 200 else { return track.genres }
                var seen = Set<String>()
                var tags = [String]()
                for block in reply.data.blocks where block.code == "SONG_PLAY_ABOUT_SONG_BASIC" {
                    for section in block.creatives ?? [] where section.creativeType == "songTag" {
                        for resource in section.resources ?? [] where resource.resourceType == "melody_style" {
                            guard let label = resource.uiElement?.mainTitle?.title else { continue }
                            for part in label.split(separator: "-") {
                                let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !tag.isEmpty && seen.insert(tag).inserted { tags.append(tag) }
                            }
                        }
                    }
                }
                if let data = try? JSONEncoder().encode(tags) { GDClient.shared.cacheData(data, key: key, generation: generation) }
                return tags
            } catch { return track.genres }
        }
        genreRequests[key] = task
        defer { genreRequests.removeValue(forKey: key) }
        return await task.value
    }

    func related(to track: Track) async -> [Track] {
        guard track.usesNetEaseCatalog, Int64(track.trackID) != nil else { return [] }
        let key = "chart/similar/v2/" + track.id
        if let cached = GDClient.shared.cachedData(key: key, maxAge: 86_400),
           let results = try? JSONDecoder().decode([Track].self, from: cached) {
            return results
        }
        let generation = GDClient.shared.cacheGeneration
        do {
            let data = try await Self.request(path: "/api/discovery/simiSong", items: [
                URLQueryItem(name: "songid", value: track.trackID), URLQueryItem(name: "limit", value: "15")
            ], session: session)
            let reply = try JSONDecoder().decode(SimilarReply.self, from: data)
            guard reply.code == 200 else { return [] }
            var seen: Set<String> = [track.id]
            let candidates = reply.songs.compactMap { $0.entry?.track }.filter { seen.insert($0.id).inserted }
            var results = Array(candidates.prefix(6))
            await withTaskGroup(of: (Int, [String]).self) { group in
                for (index, candidate) in results.enumerated() {
                    group.addTask { (index, await self.genres(for: candidate)) }
                }
                for await (index, tags) in group { results[index].genres = tags }
            }
            if !results.isEmpty, let stored = try? JSONEncoder().encode(results) { GDClient.shared.cacheData(stored, key: key, generation: generation) }
            return results
        } catch {
            if let data = GDClient.shared.cachedData(key: key, maxAge: 30 * 86_400),
               let results = try? JSONDecoder().decode([Track].self, from: data) { return results }
            return []
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        return calendar
    }()

    private static func dateLabel(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 1)月\(parts.day ?? 1)日"
    }

    nonisolated fileprivate static func asDate(_ milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    nonisolated private static func request(path: String, items: [URLQueryItem], session: URLSession) async throws -> Data {
        var address = URLComponents()
        address.scheme = "https"
        address.host = "music.163.com"
        address.path = path
        address.queryItems = items
        guard let url = address.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

private struct ChartSnapshot: Codable {
    var entries: [ChartEntry]
    var updated: Date?
    var fetched: Date
}
private struct ChartEntry: Codable {
    var track: Track
    var released: Date?
}
private struct ChartReply: Decodable {
    var code: Int
    var result: Playlist
    struct Playlist: Decodable {
        var id: Int
        var updateTime: Double?
        var tracks: [CatalogRecording]
    }
}
private struct SimilarReply: Decodable {
    var code: Int
    var songs: [CatalogRecording]
}
private struct CatalogRecording: Decodable {
    struct Artist: Decodable { var name: String }
    struct Album: Decodable {
        var name: String
        var picUrl: String?
        var picId_str: String?
        var picId: Int64?
        var type: String?
        var publishTime: Double?
    }
    var id: Int64
    var name: String
    var artists: [Artist]
    var album: Album
    var publishTime: Double?

    var entry: ChartEntry? {
        let artist = artists.map(\.name).filter { !$0.isEmpty }.joined(separator: " / ")
        guard !artist.isEmpty, !name.isEmpty else { return nil }
        let track = Track(source: "netease", trackID: String(id), title: name, artist: artist, album: album.name,
                          pictureID: album.picId_str ?? album.picId.map(String.init) ?? "", lyricID: String(id),
                          artworkURL: cover)
        // An album may be a recent compilation of older recordings. Use an album date
        // as a track release date only when it is the actual single's publication.
        let released = DiscoveryStore.asDate(publishTime) ?? (album.type == "Single" ? DiscoveryStore.asDate(album.publishTime) : nil)
        return ChartEntry(track: track, released: released)
    }

    private var cover: URL? {
        guard let value = album.picUrl, var address = URLComponents(string: value),
              let host = address.host, host.hasSuffix(".music.126.net") else { return nil }
        address.scheme = "https"
        address.queryItems = [URLQueryItem(name: "param", value: "500y500")]
        return address.url
    }
}

private struct GenreReply: Decodable {
    var code: Int
    var data: Contents
    struct Contents: Decodable { var blocks: [Block] }
    struct Block: Decodable { var code: String?; var creatives: [Section]? }
    struct Section: Decodable { var creativeType: String?; var resources: [Resource]? }
    struct Resource: Decodable { var resourceType: String?; var uiElement: Element? }
    struct Element: Decodable { var mainTitle: Title? }
    struct Title: Decodable { var title: String? }
}
