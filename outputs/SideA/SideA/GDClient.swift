import Foundation
import CryptoKit

struct LyricLine: Identifiable {
    let time: Double
    let text: String
    var translation: String?
    var id: Double { time }
}

enum MusicFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// Only catalog replies and artwork go to disk. AVPlayer owns its short-lived audio buffer.
final class MediaCache: @unchecked Sendable {
    private let directory: URL

    init(directory: URL = LocalStorage.directory(.cachesDirectory, name: "SideAMedia")) {
        self.directory = directory
    }
    private let lock = NSLock()
    private var generation = 0

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }
    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
    }
    private func file(_ key: String) -> URL {
        let prefix = key.hasPrefix("image|") ? "c-" : "m-"
        return directory.appendingPathComponent(prefix + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }
    private func bytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    var size: Int { synchronized { files().reduce(0) { $0 + bytes($1) } } }
    var epoch: Int { synchronized { generation } }
    func read(_ key: String, ttl: TimeInterval) -> Data? {
        synchronized {
            let url = file(key)
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  -modified.timeIntervalSinceNow < ttl else { return nil }
            return try? Data(contentsOf: url)
        }
    }
    func write(_ data: Data, key: String, epoch: Int) {
        synchronized {
            guard generation == epoch, !data.isEmpty else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file(key), options: .atomic)
        }
    }
    func clear() {
        synchronized {
            generation += 1
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private actor FetchQueue {
    private var tasks: [String: Task<Data, Error>] = [:]
    private var timestamps: [Date] = []
    func data(for req: URLRequest, using session: URLSession, isGD: Bool, playback: Bool) async throws -> Data {
        let key = req.url!.absoluteString
        if let task = tasks[key] { return try await task.value }
        if isGD {
            let now = Date()
            timestamps.removeAll { now.timeIntervalSince($0) >= 300 }
            guard timestamps.count < (playback ? 50 : 44) else {
                throw MusicFailure.message("音乐源请求较频繁，请稍后重试。")
            }
            timestamps.append(now)
        }
        let task = Task {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                throw MusicFailure.message("曲库暂不可用，请稍后再试。")
            }
            return data
        }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}

struct StreamInfo {
    let url: URL
    let isFLAC: Bool
    let bits: Int?
    let bitrate: Int
    var quality: String {
        if isFLAC {
            return bits.map { "无损 · FLAC \($0)-bit" } ?? "无损 · FLAC"
        }
        return bitrate > 0 ? "\(bitrate) kbps" : "在线音频"
    }
}

final class GDClient: @unchecked Sendable {
    static let shared = GDClient()
    private let session: URLSession
    private let centralSession: URLSession
    private let cache = MediaCache()
    private let queue = FetchQueue()
    init(configuration c: URLSessionConfiguration = .ephemeral) {
        c.timeoutIntervalForRequest = 13
        c.timeoutIntervalForResource = 24
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCredentialStorage = nil
        session = URLSession(configuration: c, delegate: KuwoProbeRedirects(), delegateQueue: nil)
        centralSession = CentralServer.session(configuration: c)
    }
    deinit { session.invalidateAndCancel(); centralSession.invalidateAndCancel() }
    func cacheSize() -> Int { cache.size }
    func cachedData(key: String, maxAge: TimeInterval) -> Data? { cache.read(key, ttl: maxAge) }
    var cacheGeneration: Int { cache.epoch }
    func cacheData(_ data: Data, key: String, generation: Int) {
        cache.write(data, key: key, epoch: generation)
    }
    func cacheData(_ data: Data, key: String) { cacheData(data, key: key, generation: cache.epoch) }
    func clearCache() { cache.clear() }

    static func request(endpoint: URL, params: [String:String]) throws -> URLRequest {
        guard var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else {
            throw MusicFailure.message("曲库接口地址无效。")
        }
        let stock = endpoint == SearchCatalog.gdEndpoint
        c.queryItems = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
        // PHP decodes a literal '+' as a space. JOOX IDs can contain both '+' and '='.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = c.url else { throw MusicFailure.message("无法创建曲库请求。") }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if stock { request.setValue("https://music.gdstudio.xyz/", forHTTPHeaderField: "Referer") }
        return request
    }

    private func api(_ params: [String:String], endpoint: URL, ttl: TimeInterval = 0, managed: Bool = false) async throws -> Data {
        let request = try Self.request(endpoint: endpoint, params: params)
        let key = request.url!.absoluteString, epoch = cache.epoch
        if !managed, ttl > 0, let data = cache.read(key, ttl: ttl) { return data }
        let data: Data
        if managed {
            data = try await CentralServer.data(for: request, endpoint: endpoint, using: centralSession)
        } else {
            data = try await queue.data(for: request, using: session, isGD: endpoint == SearchCatalog.gdEndpoint, playback: params["types"] == "url")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        if let dict = json as? [String:Any], let msg = dict["error"] as? String {
            throw MusicFailure.message(msg)
        }
        if !managed, ttl > 0 { cache.write(data, key: key, epoch: epoch) }
        return data
    }
    private func object(_ data: Data) throws -> [String:Any] {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String:Any] else {
            throw MusicFailure.message("音乐源返回了无法识别的数据。")
        }
        return row
    }
    private func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
    func search(_ query: String, catalog: SearchCatalog = .netease, page: Int = 1) async throws -> [Track] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var params = ["types":"search", "source":catalog.source, "name":text, "count":"25", "pages":String(max(1, page))]
        if catalog.managed == true {
            params["provider"] = catalog.provider
            let data = try await api(params, endpoint: catalog.endpoint, managed: true)
            return try parseSearch(data, catalog: catalog)
        }
        let key = try Self.request(endpoint: catalog.endpoint, params: params).url!.absoluteString
        if let hit = cache.read(key, ttl: 3_600),
           let tracks = try? parseSearch(hit, catalog: catalog), !tracks.isEmpty { return tracks }
        let epoch = cache.epoch
        let data = try await api(params, endpoint: catalog.endpoint)
        let tracks = try parseSearch(data, catalog: catalog)
        if !tracks.isEmpty { cache.write(data, key: key, epoch: epoch) }
        return tracks
    }

    func parseSearch(_ data: Data, catalog: SearchCatalog) throws -> [Track] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String:Any]] else {
            throw MusicFailure.message("搜索未返回 GD 兼容的曲目列表，请核对接口与 source。")
        }
        var ids = Set<String>()
        var unexpectedSources = Set<String>()
        let tracks = rows.compactMap { row -> Track? in
            let id = string(row["id"]), title = string(row["name"])
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let reported = string(row["source"]).lowercased()
            guard reported == catalog.source else {
                unexpectedSources.insert(reported.isEmpty ? "未标明" : reported)
                return nil
            }
            if let provider = catalog.provider {
                guard id.hasPrefix(provider + "."), id.count > provider.count + 1 else { return nil }
                if let reportedProvider = row["provider_id"] as? String, reportedProvider != provider { return nil }
            }
            guard ids.insert(id).inserted else { return nil }
            let artist = (row["artist"] as? [String])?.joined(separator: " / ") ?? string(row["artist"])
            return Track(source: reported, trackID: id, title: title, artist: artist, album: string(row["album"]),
                         pictureID: string(row["pic_id"]), lyricID: string(row["lyric_id"]),
                         catalogEndpoint: catalog.endpoint == SearchCatalog.gdEndpoint ? nil : catalog.endpoint, managedCatalog: catalog.managed, providerName: catalog.managed == true ? row["provider_name"] as? String : nil)
        }
        if tracks.isEmpty && !unexpectedSources.isEmpty {
            throw MusicFailure.message("所选曲库是 \(catalog.source)，接口返回的来源为 \(unexpectedSources.sorted().joined(separator: "、"))。请核对接口或切换曲库。")
        }
        return tracks
    }
    private func httpsURL(_ raw: String) -> URL? {
        guard var c = URLComponents(string: raw), ["http","https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil else { return nil }
        c.scheme = "https"
        return c.url
    }
    func artwork(_ track: Track) async -> URL? {
        if let url = track.artworkURL { return url }
        guard !track.pictureID.isEmpty else { return nil }
        do {
            let data = try await api(["types":"pic","source":track.source,"id":track.pictureID,"size":"500"], endpoint: track.apiEndpoint, ttl: 86_400, managed: track.managedCatalog == true)
            return httpsURL(string(try object(data)["url"]))
        } catch { return nil }
    }
    func coverData(_ track: Track) async -> Data? {
        let key = "image|" + track.id, epoch = cache.epoch
        if track.managedCatalog != true, let stored = cache.read(key, ttl: 604_800) { return stored }
        guard !Task.isCancelled, let url = await artwork(track), !Task.isCancelled else { return nil }
        guard let data = try? await queue.data(for: URLRequest(url: url), using: session, isGD: false, playback: false),
              data.count < 12_000_000 else { return nil }
        if track.managedCatalog != true { cache.write(data, key: key, epoch: epoch) }
        return data
    }
    func lyrics(_ track: Track) async -> [LyricLine] {
        let id = track.lyricID.isEmpty ? track.trackID : track.lyricID
        if let data = try? await api(["types":"lyric", "source":track.source, "id":id], endpoint: track.apiEndpoint, ttl: 604_800, managed: track.managedCatalog == true),
           let row = try? object(data) {
            let lines = lyricLines(original: string(row["lyric"]), translated: string(row["tlyric"]))
            if !lines.isEmpty { return lines }
        }
        // The same NetEase recording ID can supply its first-party LRC when GD has no usable reply.
        guard !Task.isCancelled, track.usesNetEaseCatalog, Int64(id) != nil,
              let url = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=-1&tv=-1") else { return [] }
        let key = "catalog-lrc|" + track.id
        let epoch = cache.epoch
        var data = cache.read(key, ttl: 604_800)
        if data == nil {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            data = try? await queue.data(for: request, using: session, isGD: false, playback: false)
        }
        guard let data, !Task.isCancelled, let row = try? object(data) else { return [] }
        let original = (row["lrc"] as? [String:Any])?["lyric"]
        let translation = (row["tlyric"] as? [String:Any])?["lyric"]
        let lines = lyricLines(original: string(original), translated: string(translation))
        if !lines.isEmpty { cache.write(data, key: key, epoch: epoch) }
        return lines
    }

    private func lyricLines(original: String, translated translationText: String) -> [LyricLine] {
        let translated = parseLRC(translationText)
        return parseLRC(original).map {
            let translation = translated[$0.key]
            return LyricLine(time: Double($0.key)/1000, text: $0.value, translation: translation == $0.value ? nil : translation)
        }.sorted { $0.time < $1.time }
    }
    private func parseLRC(_ raw: String) -> [Int:String] {
        var result = [Int:String]()
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for line in raw.components(separatedBy: .newlines) {
            let s = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: s.length))
            guard let last = matches.last else { continue }
            let content = s.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            for m in matches {
                guard let minutes = Double(s.substring(with: m.range(at: 1))), let seconds = Double(s.substring(with: m.range(at: 2))) else { continue }
                let milliseconds = ((60 * minutes + seconds) * 1000).rounded()
                guard let ms = Int(exactly: milliseconds) else { continue }
                result[ms] = content
            }
        }
        return result
    }
    func stream(_ track: Track, bitrate: Int) async throws -> StreamInfo {
        let data = try await api(["types":"url","source":track.source,"id":track.trackID,"br":String(bitrate)], endpoint: track.apiEndpoint, managed: track.managedCatalog == true)
        let o = try object(data)
        guard let url = httpsURL(string(o["url"])) else { throw MusicFailure.message("没有找到这个版本的可播音源。") }
        var req = KuwoResourceLoader.request(url)
        req.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: req)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MusicFailure.message("播放地址已失效，请重试。")
        }
        var header = [UInt8]()
        for try await byte in bytes {
            header.append(byte); if header.count >= 42 { break }
        }
        try Task.checkCancellation()
        let flac = header.starts(with: [0x66,0x4c,0x61,0x43])
        let bits: Int? = flac && header.count >= 42 && header[4] & 127 == 0
            ? Int((header[20] & 1) << 4 | (header[21] >> 4)) + 1 : nil
        return StreamInfo(url: url, isFLAC: flac, bits: bits, bitrate: Int(string(o["br"])) ?? 0)
    }
}
