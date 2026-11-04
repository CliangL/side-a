import Foundation
import SwiftUI

// UI tests exercise relaunch and cache clearing without touching a listener's library.
enum LocalStorage {
    static let testID: String? = {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let value = env["SIDEA_TEST_STORAGE"], let id = UUID(uuidString: value) { return id.uuidString }
        if env["XCTestConfigurationFilePath"] != nil { return "unit-tests" }
#endif
        return nil
    }()
    static var defaults: UserDefaults {
        if let testID { return UserDefaults(suiteName: "SideA.tests." + testID) ?? .standard }
        return .standard
    }
    static func directory(_ kind: FileManager.SearchPathDirectory, name: String) -> URL {
        if let testID {
            return FileManager.default.temporaryDirectory.appendingPathComponent("SideA-tests").appendingPathComponent(testID).appendingPathComponent(name)
        }
        return FileManager.default.urls(for: kind, in: .userDomainMask)[0].appendingPathComponent(name)
    }
}

struct Track: Codable, Hashable, Identifiable, Sendable {
    let source: String
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let pictureID: String
    let lyricID: String
    var artworkURL: URL? = nil
    var genres: [String] = []
    // Nil is the original GD endpoint, including tracks saved before custom catalogs existed.
    var catalogEndpoint: URL? = nil
    var managedCatalog: Bool? = nil
    var providerName: String? = nil
    // Set only after an official original-song reference matches the recording details.
    var verifiedCatalogOriginal: Bool? = nil
    var apiEndpoint: URL { catalogEndpoint ?? SearchCatalog.gdEndpoint }
    var catalogLabel: String {
        if managedCatalog == true {
            if trackID.hasPrefix("qq.") { return "QQ 音乐" }
            if let providerName, !providerName.isEmpty { return providerName }
            if trackID.hasPrefix("wy.") { return "网易云音乐" }
            if trackID.hasPrefix("kw.") { return "酷我音乐" }
            if trackID.hasPrefix("jx.") { return "JOOX" }
            return "统一曲库"
        }
        if apiEndpoint != SearchCatalog.gdEndpoint { return [apiEndpoint.host, source].compactMap { $0 }.joined(separator: " · ") }
        return SearchCatalog.builtIns.first { $0.source == source }?.name ?? source
    }
    var usesNetEaseCatalog: Bool { apiEndpoint == SearchCatalog.gdEndpoint && source == "netease" }
    var id: String {
        let recording = source + ":" + trackID
        return apiEndpoint == SearchCatalog.gdEndpoint ? recording : apiEndpoint.absoluteString + "|" + recording
    }

    static let starterTracks: [Track] = {
        guard let url = Bundle.main.url(forResource: "starter", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }()

    var localArtworkURL: URL? {
        guard usesNetEaseCatalog, !trackID.isEmpty, trackID.allSatisfy(\.isNumber) else { return nil }
        let file = "cover-" + trackID
        return Bundle.main.url(forResource: file, withExtension: "jpg") ??
               Bundle.main.url(forResource: file, withExtension: "jpg", subdirectory: "StarterArt")
    }
}

struct UserPlaylist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tracks: [Track] = []
    var cover: Track? = nil
}

struct ListeningDay: Codable, Equatable {
    var track: Track
    var date: Date
    var choices = 0
    var replays = 0
    var completions = 0
    var quickSkips = 0
}

struct SavedLibrary: Codable, Equatable {
    var playlists: [UserPlaylist] = []
    var favorites: [Track] = []
    var recent: [Track] = []
    var trackingEnabled = true
    var listening: [ListeningDay] = []
    var hidden: Set<String> = []
    var genres: [String: [String]]? = nil
    var mutedStyles: Set<String>? = nil
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var playlists: [UserPlaylist]
    @Published private(set) var favorites: [Track]
    @Published private(set) var recent: [Track]
    @Published var trackingEnabled: Bool { didSet { if oldValue != trackingEnabled { save() } } }
    @Published private(set) var storageError: String?
    @Published private var listening: [ListeningDay]
    @Published private var hidden: Set<String>
    private var styleTask: Task<Void, Never>?
    @Published private var genres: [String: [String]]
    @Published private var mutedStyles: Set<String>
    private var sessionSkips: [String: Date] = [:]
    private let file: URL
    var onPersist: (() -> Void)?
    private var applyingCloud = false
    private(set) var needsCloudRecovery = true

    init(file: URL? = nil) {
        self.file = file ?? LocalStorage.directory(.applicationSupportDirectory, name: "SideA").appendingPathComponent("library.json")
        var saved = SavedLibrary()
        var loadError: String?
        if FileManager.default.fileExists(atPath: self.file.path) {
            do {
                saved = try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: self.file))
                needsCloudRecovery = FileManager.default.fileExists(atPath: self.file.appendingPathExtension("recover").path)
            }
            catch {
                loadError = "资料库暂时无法读取，已保留原文件。"
                let backup = self.file.deletingLastPathComponent().appendingPathComponent("library-recovery-" + UUID().uuidString + ".json")
                try? FileManager.default.copyItem(at: self.file, to: backup)
            }
        }
        playlists = saved.playlists
        favorites = saved.favorites
        recent = saved.recent
        trackingEnabled = saved.trackingEnabled
        listening = saved.listening
        hidden = saved.hidden
        genres = saved.genres ?? [:]
        mutedStyles = saved.mutedStyles ?? []
        storageError = loadError
    }

    var snapshot: SavedLibrary {
        SavedLibrary(playlists: playlists, favorites: favorites, recent: recent,
                     trackingEnabled: trackingEnabled, listening: listening, hidden: hidden,
                     genres: genres, mutedStyles: mutedStyles)
    }

    // The complete file is saved before publishing restoration, so a failed disk write never
    // advances the cloud baseline or replaces the visible local library.
    func restore(_ saved: SavedLibrary) throws {
        try write(saved)
        let marker = file.appendingPathExtension("recover")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        applyingCloud = true
        defer { applyingCloud = false }
        playlists = saved.playlists; favorites = saved.favorites; recent = saved.recent
        trackingEnabled = saved.trackingEnabled; listening = saved.listening; hidden = saved.hidden
        genres = saved.genres ?? [:]; mutedStyles = saved.mutedStyles ?? []
        storageError = nil
        needsCloudRecovery = false
    }

    private func write(_ saved: SavedLibrary) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func save() {
        guard !applyingCloud else { return }
        do {
            if needsCloudRecovery {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: file.appendingPathExtension("recover"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try write(snapshot)
            storageError = nil
            onPersist?()
        } catch {
            storageError = "资料库保存失败，请检查可用空间。"
        }
    }

    func isFavorite(_ track: Track) -> Bool { favorites.contains { $0.id == track.id } }

    func toggleFavorite(_ track: Track) {
        if isFavorite(track) { favorites.removeAll { $0.id == track.id } }
        else { favorites.insert(track, at: 0); hidden.remove(track.id) }
        save()
    }

    @discardableResult func createPlaylist(_ name: String, tracks: [Track] = []) -> UUID? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var seen = Set<String>()
        let item = UserPlaylist(name: title, tracks: tracks.filter { seen.insert($0.id).inserted })
        playlists.insert(item, at: 0)
        save()
        return item.id
    }

    func renamePlaylist(_ id: UUID, name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = title
        save()
    }

    func deletePlaylist(_ id: UUID) { playlists.removeAll { $0.id == id }; save() }
    func add(_ track: Track, to id: UUID) {
        add([track], to: id)
    }
    func add(_ tracks: [Track], to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        var existing = Set(playlists[i].tracks.map(\.id))
        let fresh = tracks.filter { existing.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        playlists[i].tracks.append(contentsOf: fresh)
        save()
    }
    func remove(_ track: Track, from id: UUID) {
        remove([track.id], from: id)
    }
    func remove(_ ids: Set<String>, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.removeAll { ids.contains($0.id) }
        if let cover = playlists[i].cover, ids.contains(cover.id) { playlists[i].cover = nil }
        save()
    }
    func setCover(_ track: Track?, for id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        if let track, !playlists[i].tracks.contains(where: { $0.id == track.id }) { return }
        playlists[i].cover = track
        save()
    }
    func reorder(_ id: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !from.isEmpty,
              (from.max() ?? -1) < playlists[i].tracks.count, (0...playlists[i].tracks.count).contains(to) else { return }
        playlists[i].tracks.move(fromOffsets: from, toOffset: to)
        save()
    }

    func record(_ track: Track, event: String, listened: Double, duration: Double, date: Date = Date()) {
        let starts = ["manualPlay", "autoPlay", "replay"].contains(event)
        if starts {
            recent.removeAll { $0.id == track.id }
            recent.insert(track, at: 0)
            recent = Array(recent.prefix(100))
        }
        guard trackingEnabled else { if starts { save() }; return }
        // Only directly observed listening choices are used; a failed request or paused track supplies no negative signal.
        guard event != "autoPlay" else { save(); return }
        let day = Calendar.current.startOfDay(for: date)
        let index = listening.lastIndex { $0.track.id == track.id && $0.date == day }
        var entry = index.map { listening[$0] } ?? ListeningDay(track: track, date: day)
        switch event {
        case "manualPlay": entry.choices = min(3, entry.choices + 1)
        case "replay": entry.replays = min(2, entry.replays + 1)
        case "complete" where listened >= min(45, max(8, duration * 0.6)): entry.completions = 1
        case "skip" where listened > 0 && listened < 12 && (duration <= 0 || listened < duration * 0.25):
            entry.quickSkips = min(2, entry.quickSkips + 1)
            sessionSkips[track.id] = date
        default: return
        }
        if event == "manualPlay" || event == "replay" { sessionSkips.removeValue(forKey: track.id) }
        if let index { listening[index] = entry } else { listening.append(entry) }
        let cutoff = day.addingTimeInterval(-120 * 86_400)
        listening.removeAll { $0.date < cutoff }
        save()
    }

    func dislike(_ track: Track) { hidden.insert(track.id); save() }
    func reduceStyle(of track: Track, tags: [String]) {
        guard !tags.isEmpty else { return }
        let keys = tags.map { $0.lowercased() }
        mutedStyles.formUnion(keys)
        genres[track.id] = Array(Set((genres[track.id] ?? []) + tags)).sorted()
        save()
    }
    func resetPreferences() {
        styleTask?.cancel()
        listening.removeAll(); hidden.removeAll(); sessionSkips.removeAll(); genres.removeAll(); mutedStyles.removeAll()
        save()
    }

    func learnStyle(of track: Track, from discovery: DiscoveryStore) {
        guard trackingEnabled, genres[track.id] == nil else { return }
        styleTask?.cancel()
        styleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            let tags = track.genres.isEmpty ? await discovery.genres(for: track) : track.genres
            guard let self, !Task.isCancelled, self.trackingEnabled, !tags.isEmpty else { return }
            self.genres[track.id] = tags
            self.save()
        }
    }

    private func weights() -> [String: Double] {
        guard trackingEnabled else { return [:] }
        var result = Dictionary(uniqueKeysWithValues: favorites.map { ($0.id, 4.0) })
        let skippedDays = Dictionary(grouping: listening.filter { $0.quickSkips > 0 }, by: { $0.track.id })
        for day in listening {
            let age = max(0, Date().timeIntervalSince(day.date)) / 86400
            let decay = exp(-age / 35)
            let engagement = 0.7 * Double(day.choices) + 1.8 * Double(day.replays) + 0.5 * Double(day.completions)
            let repeatsAcrossDays = (skippedDays[day.track.id]?.count ?? 0) > 1
            let penalty = repeatsAcrossDays ? 0.8 * Double(day.quickSkips) : 0
            result[day.track.id, default: 0] += decay * (engagement - penalty)
        }
        return result
    }

    var seedTracks: [Track] {
        guard trackingEnabled else { return [] }
        let w = weights()
        var seen = Set<String>()
        return (favorites + recent + listening.reversed().map(\.track))
            .filter { seen.insert($0.id).inserted && !hidden.contains($0.id) && (w[$0.id] ?? 0) > 0 }
            .sorted { (w[$0.id] ?? 0) > (w[$1.id] ?? 0) }
    }

    var reason: String {
        guard let seed = seedTracks.first else { return "从几张唱片开始，听见新的声音" }
        let days = listening.filter { $0.track.id == seed.id && $0.choices + $0.replays > 0 }.count
        if days > 1 { return "因为你有 \(days) 天主动听了《\(seed.title)》" }
        if isFavorite(seed) { return "因为你收藏了《\(seed.title)》" }
        return "沿着《\(seed.title)》继续发现"
    }

    func recommendations(from candidates: [Track]) -> [Track] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted && !hidden.contains($0.id) }
        guard trackingEnabled else { return Array(unique.prefix(24)) }
        let now = Date()
        let w = weights()
        var artist = [String: Double](), genre = [String: Double]()
        var indexed = Set<String>()
        for t in favorites + recent + listening.map(\.track) where indexed.insert(t.id).inserted {
            let value = min(7, max(-3, w[t.id] ?? 0))
            artist[t.artist.lowercased(), default: 0] += value
            for tag in genres[t.id] ?? t.genres { genre[tag.lowercased(), default: 0] += value }
        }
        let justHeard = Set(recent.prefix(8).map(\.id))
        var scored: [(Track, Double, Int)] = []
        for (index, candidate) in unique.enumerated() {
            let familiar = min(4, artist[candidate.artist.lowercased()] ?? 0)
            let labels = (genres[candidate.id] ?? candidate.genres).map { $0.lowercased() }
            let style = labels.compactMap { genre[$0] }.max() ?? 0
            let stylePenalty: Double = mutedStyles.isDisjoint(with: labels) ? 0 : 12
            let recentlySkipped = sessionSkips[candidate.id].map { now.timeIntervalSince($0) < 3_600 } ?? false
            let repetition: Double = recentlySkipped ? 12 : (justHeard.contains(candidate.id) ? 4 : 0)
            let affinity = familiar + min(3.0, style) * 0.7
            let score = affinity - repetition - stylePenalty + 2.0 / Double(index+1)
            scored.append((candidate, score, index))
        }
        let ordered = scored.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
        var counts = [String: Int](), result = [Track](), extras = [Track]()
        for (t, _, _) in ordered {
            let key = t.artist.lowercased()
            if counts[key, default: 0] < 2 { result.append(t) } else { extras.append(t) }
            counts[key, default: 0] += 1
        }
        return Array((result + extras).prefix(24))
    }
}
