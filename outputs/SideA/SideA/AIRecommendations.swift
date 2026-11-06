import Foundation
import CryptoKit

// Only bounded listening summaries and catalog metadata leave the device. Playable
// Track objects remain here: a model can reorder existing songs, never create URLs.
enum AIRecommendations {
    struct Candidate: Codable { let id: String; let title: String; let artist: String; let album: String; let familiar: Bool?; let recent: Bool?; let shown: Bool? }
    struct Signal: Codable {
        let title: String; let artist: String
        var choices = 0; var replays = 0; var completions = 0; var quick_skips = 0
    }
    struct Profile: Codable { let favorites: [Signal]; let listening: [Signal]; let muted_styles: [String] }
    struct Input: Codable { let profile: Profile; let candidates: [Candidate] }
    struct Ranked: Codable { let id: String; let reason: String }
    struct Result: Codable { let profile_summary: String; let ranked: [Ranked] }
    struct TaskReply: Decodable {
        struct Job: Decodable { let id: String; let status: String; let result: Result? }
        let task: Job
    }
    struct Cache: Codable { let fingerprint: String; let expires: Date; let result: Result; var revision: String? = nil }
    struct Configuration: Decodable { let revision: String; let enabled: Bool; let min_interval_seconds: Int? }
    struct Pending: Codable {
        let id: String; let fingerprint: String; let revision: String; let created: Date; let input: Input
        var expired: Bool { Date().timeIntervalSince(created) > 21600 }
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func encoded(_ input: Input) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(input)
    }
    static func input(saved: SavedLibrary, candidates: [Track], shown: [String] = []) -> Input {
        func signal(_ track: Track) -> Signal { Signal(title: String(track.title.prefix(60)), artist: String(track.artist.prefix(60))) }
        var grouped = [String: Signal](), order = [String]()
        // Last 30 days; network failures and pauses were never recorded as skips.
        for day in saved.listening.reversed() where day.date > Date().addingTimeInterval(-30 * 86400) {
            if grouped[day.track.id] == nil { order.append(day.track.id); grouped[day.track.id] = signal(day.track) }
            grouped[day.track.id]!.choices += day.choices; grouped[day.track.id]!.replays += day.replays
            grouped[day.track.id]!.completions += day.completions; grouped[day.track.id]!.quick_skips += day.quickSkips
        }
        let recentIDs = saved.recent.map(\.id)
        var seen = Set<String>()
        order = (recentIDs + order).filter { grouped[$0] != nil && seen.insert($0).inserted }
        let known = knownKeys(saved), recent = Set(saved.recent.prefix(12).map(recordingKey)), displayed = Set(shown)
        let profile = Profile(favorites: saved.favorites.prefix(10).map(signal),
                              listening: order.prefix(12).compactMap { grouped[$0] },
                              muted_styles: Array((saved.mutedStyles ?? []).sorted().prefix(12)).map { String($0.prefix(30)) })
        return Input(profile: profile, candidates: candidates.prefix(60).map {
            Candidate(id: hash($0.id), title: String($0.title.prefix(80)), artist: String($0.artist.prefix(80)), album: String($0.album.prefix(80)), familiar: known.contains(recordingKey($0)), recent: recent.contains(recordingKey($0)), shown: displayed.contains(recordingKey($0)))
        })
    }
    static func recordingKey(_ t: Track) -> String {
        func clean(_ s: String) -> String { s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined() }
        return clean(t.title) + "|" + clean(t.artist)
    }
    static func knownKeys(_ saved: SavedLibrary) -> Set<String> {
        Set((saved.favorites + saved.recent + saved.listening.map(\.track)).map(recordingKey))
    }
    // Prefer unshown recordings; within each pool preserve model order while
    // reserving three of every four places for unheard music when available.
    static func discoveryOrder(_ tracks: [Track], saved: SavedLibrary, shown: [String], limit: Int) -> [Track] {
        let known = knownKeys(saved), displayed = Set(shown)
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert(recordingKey($0)).inserted }
        var result = [Track]()
        for pool in [unique.filter { !displayed.contains(recordingKey($0)) }, unique.filter { displayed.contains(recordingKey($0)) }] {
            let fresh = pool.filter { !known.contains(recordingKey($0)) }, familiar = pool.filter { known.contains(recordingKey($0)) }
            var n = 0, f = 0, slot = 0
            while result.count < limit && (n < fresh.count || f < familiar.count) {
                if n < fresh.count && (slot % 4 != 3 || f >= familiar.count) { result.append(fresh[n]); n += 1 }
                else if f < familiar.count { result.append(familiar[f]); f += 1 }
                slot += 1
            }
        }
        return result
    }
    static func reorder(_ candidates: [Track], result: Result) -> [Track] {
        let map = Dictionary(candidates.map { (hash($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let ranked = result.ranked.compactMap { item -> Track? in
            guard seen.insert(item.id).inserted else { return nil }; return map[item.id]
        }
        return ranked + candidates.filter { !seen.contains(hash($0.id)) }
    }
    static func configuration(server: PairedServer, using session: URLSession) async throws -> Configuration {
        struct Reply: Decodable { let config: Configuration }
        var request = URLRequest(url: server.base.appending(path: "v1/ai/config"))
        request.setValue("Bearer " + server.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2048 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Reply.self, from: data).config
    }
    private static func jobRequest(_ path: String, body: Data? = nil, server: PairedServer, using session: URLSession) async throws -> TaskReply.Job {
        var request = URLRequest(url: server.base.appending(path: path))
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue("Bearer " + server.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 65536 else { throw URLError(.badServerResponse) }
        let job = try JSONDecoder().decode(TaskReply.self, from: data).task
        guard validID(job.id) else { throw URLError(.badServerResponse) }
        return job
    }
    static func validID(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil }
    static func submit(_ input: Input, server: PairedServer, using session: URLSession) async throws -> TaskReply.Job {
        try await jobRequest("v1/ai/recommend", body: encoded(input), server: server, using: session)
    }
    static func poll(_ id: String, server: PairedServer, using session: URLSession) async throws -> TaskReply.Job {
        guard validID(id) else { throw URLError(.badURL) }
        return try await jobRequest("v1/ai/tasks/" + id, server: server, using: session)
    }
    static func cancel(_ id: String, server: PairedServer, using session: URLSession) async -> Bool {
        guard validID(id) else { return true }
        var request = URLRequest(url: server.base.appending(path: "v1/ai/tasks/" + id + "/cancel"))
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("Bearer " + server.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await session.data(for: request), let code = (response as? HTTPURLResponse)?.statusCode else { return false }
        return code == 200 || code == 404
    }
}
