import Foundation
import CryptoKit

struct CloudPlayback: Codable, Equatable {
    struct Resume: Codable, Equatable {
        var queue: [Track] = []
        var index = 0
        var position: Double = 0
    }
    var mode = "sequence"
    var preferLossless = true
    var cellularDataSaver = true
    var losslessOnly = false
    var resume = Resume()
}

struct DeviceLibrarySnapshot: Codable, Equatable {
    var schema = 1
    var library = SavedLibrary(genres: [:], mutedStyles: [])
    var playback = CloudPlayback()
    var qqSearch = false
    var selectedProvider: String? = nil
    var effectiveProvider: String { selectedProvider ?? (qqSearch ? "qq" : "all") }

    static func merge(base: Self, local: Self, remote: Self) -> Self {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        var result = local
        let b = base.library, l = local.library, r = remote.library
        result.library.favorites = ordered(b.favorites, l.favorites, r.favorites, key: { $0.id })
        result.library.recent = Array(ordered(b.recent, l.recent, r.recent, key: { $0.id }).prefix(100))
        result.library.playlists = ordered(b.playlists, l.playlists, r.playlists, key: { $0.id.uuidString }) { b,l,r in
            guard let b else { return l }
            var value = l
            value.name = choose(b.name, l.name, r.name)
            value.tracks = ordered(b.tracks, l.tracks, r.tracks, key: { $0.id })
            value.cover = choose(b.cover, l.cover, r.cover)
            if let cover = value.cover, !value.tracks.contains(where: { $0.id == cover.id }) { value.cover = nil }
            return value
        }
        result.library.listening = ordered(b.listening, l.listening, r.listening, key: { $0.track.id + "|" + String($0.date.timeIntervalSince1970) }) { _,l,r in
            var value = l
            value.choices = max(l.choices, r.choices); value.replays = max(l.replays, r.replays)
            value.completions = max(l.completions, r.completions); value.quickSkips = max(l.quickSkips, r.quickSkips)
            return value
        }
        result.library.hidden = set(b.hidden, l.hidden, r.hidden)
        result.library.mutedStyles = set(b.mutedStyles ?? [], l.mutedStyles ?? [], r.mutedStyles ?? [])
        result.library.genres = dictionary(b.genres ?? [:], l.genres ?? [:], r.genres ?? [:])
        result.library.trackingEnabled = choose(b.trackingEnabled, l.trackingEnabled, r.trackingEnabled)
        let pb = base.playback, pl = local.playback, pr = remote.playback
        result.playback = CloudPlayback(mode: choose(pb.mode, pl.mode, pr.mode),
            preferLossless: choose(pb.preferLossless, pl.preferLossless, pr.preferLossless),
            cellularDataSaver: choose(pb.cellularDataSaver, pl.cellularDataSaver, pr.cellularDataSaver),
            losslessOnly: choose(pb.losslessOnly, pl.losslessOnly, pr.losslessOnly),
            resume: choose(pb.resume, pl.resume, pr.resume))
        result.selectedProvider = choose(base.effectiveProvider, local.effectiveProvider, remote.effectiveProvider)
        result.qqSearch = result.selectedProvider == "qq"
        return result
    }

    private static func choose<T: Equatable>(_ base: T, _ local: T, _ remote: T) -> T { local == base ? remote : local }
    private static func set<T: Hashable>(_ base: Set<T>, _ local: Set<T>, _ remote: Set<T>) -> Set<T> {
        local.union(remote).subtracting(base.subtracting(local)).subtracting(base.subtracting(remote))
    }
    private static func dictionary<T: Equatable>(_ base: [String:T], _ local: [String:T], _ remote: [String:T]) -> [String:T] {
        var value: [String:T] = [:]
        for key in Set(local.keys).union(remote.keys) {
            if base[key] != nil && (local[key] == nil || remote[key] == nil) { continue }
            value[key] = local[key] == base[key] ? remote[key] : local[key] ?? remote[key]
        }
        return value
    }
    // Absence relative to the acknowledged base is a deletion. A union alone would
    // resurrect an unfavorited song or a deleted playlist after a retry or reinstall.
    private static func ordered<T: Equatable>(_ base: [T], _ local: [T], _ remote: [T], key: (T) -> String,
        combine: ((T?, T, T) -> T)? = nil) -> [T] {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        func index(_ values: [T]) -> [String:T] { values.reduce(into: [:]) { $0[key($1)] = $1 } }
        let b = index(base), l = index(local), r = index(remote)
        let preferred = local.map(key) == base.map(key) ? remote + local : local + remote
        var used: Set<String> = []
        return preferred.compactMap { value in
            let id = key(value)
            guard used.insert(id).inserted else { return nil }
            if b[id] != nil && (l[id] == nil || r[id] == nil) { return nil }
            if let lv = l[id], let rv = r[id] {
                if let combine { return combine(b[id], lv, rv) }
                return lv == b[id] ? rv : lv
            }
            return l[id] ?? r[id]
        }
    }
}

struct LibraryCloudReply: Codable {
    var revision: Int
    var data: DeviceLibrarySnapshot?
}

@MainActor protocol LibraryCloudTransport {
    var identity: String { get }
    func bind() async throws -> LibraryCloudReply
    func save(_ data: DeviceLibrarySnapshot, revision: Int) async throws -> LibraryCloudReply
}

@MainActor final class CentralLibraryTransport: LibraryCloudTransport {
    private let server: PairedServer
    private let recovery: String
    private let session: URLSession
    let identity: String

    init(server: PairedServer, recovery: String, session: URLSession = CentralServer.session()) {
        self.server = server; self.recovery = recovery; self.session = session
        identity = server.base.absoluteString + "|" + SHA256.hash(data: Data(recovery.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    deinit { session.invalidateAndCancel() }
    func bind() async throws -> LibraryCloudReply {
        try await request(path: "v1/library/bind", method: "POST", body: JSONEncoder().encode(["recovery": recovery, "platform": "ios"]))
    }
    func save(_ data: DeviceLibrarySnapshot, revision: Int) async throws -> LibraryCloudReply {
        try await request(path: "v1/library", method: "PUT", body: JSONEncoder().encode(LibraryCloudReply(revision: revision, data: data)))
    }
    private func request(path: String, method: String, body: Data) async throws -> LibraryCloudReply {
        guard try CentralServer.read() == server else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: server.base.appending(path: path))
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + server.token, forHTTPHeaderField: "Authorization")
        let (data,response) = try await session.data(for: request)
        guard try CentralServer.read() == server,
              let status = (response as? HTTPURLResponse)?.statusCode,
              status == 200 || (method == "PUT" && status == 409), data.count <= 16 * 1024 * 1024 else {
            throw URLError(.badServerResponse)
        }
        let reply = try JSONDecoder().decode(LibraryCloudReply.self, from: data)
        guard reply.revision >= 0, reply.data?.schema ?? 1 == 1,
              reply.data != nil || reply.revision == 0 else { throw URLError(.cannotParseResponse) }
        return reply
    }
}

@MainActor final class DeviceLibrarySync {
    private struct Journal: Codable {
        var identity: String
        var revision: Int
        var data: DeviceLibrarySnapshot?
    }
    private let file: URL
    private let read: () -> DeviceLibrarySnapshot
    private let apply: (DeviceLibrarySnapshot) throws -> Void
    private let needsLibraryRecovery: () -> Bool
    private let needsDurableLibraryWrite: () -> Bool
    private let connect: () async throws -> (any LibraryCloudTransport)?
    private var journal: Journal?
    private var running: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var scheduledAt: Date?
    private var applying = false
    private(set) var lastSyncSucceeded = false

    init(file: URL? = nil, read: @escaping () -> DeviceLibrarySnapshot,
         apply: @escaping (DeviceLibrarySnapshot) throws -> Void,
         needsLibraryRecovery: @escaping () -> Bool = { false },
         needsDurableLibraryWrite: @escaping () -> Bool = { false },
         connect: @escaping () async throws -> (any LibraryCloudTransport)?) {
        self.file = file ?? LocalStorage.directory(.applicationSupportDirectory, name: "SideA").appendingPathComponent("cloud-library.json")
        self.read = read; self.apply = apply; self.connect = connect
        self.needsLibraryRecovery = needsLibraryRecovery
        self.needsDurableLibraryWrite = needsDurableLibraryWrite
        journal = (try? Data(contentsOf: self.file)).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
    }
    deinit { running?.cancel(); scheduled?.cancel() }

    func changed(after delay: TimeInterval = 1) {
        guard !applying else { return }
        let due = Date().addingTimeInterval(delay)
        if let scheduledAt, scheduledAt <= due { return }
        scheduled?.cancel(); scheduledAt = due
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.scheduled = nil; self.scheduledAt = nil
            await self.flush()
        }
    }

    func flush() async {
        if let running { await running.value; return }
        scheduled?.cancel(); scheduled = nil; scheduledAt = nil
        let runner = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.synchronize()
        }
        running = runner
        await runner.value
        running = nil
    }

    func cancelCurrent() { running?.cancel() }

    private func acknowledge(_ reply: LibraryCloudReply, identity: String) throws {
        let next = Journal(identity: identity, revision: reply.revision, data: reply.data)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        journal = next
    }
    private func receive(_ remote: LibraryCloudReply, identity: String) throws {
        var baseline = (journal?.identity == identity && remote.data != nil ? journal?.data : nil) ?? DeviceLibrarySnapshot()
        // A missing/corrupt local file is not a deliberate "delete all". Keep remote
        // records and merge any new local edits until restoration has reached disk.
        if needsLibraryRecovery() { baseline.library = DeviceLibrarySnapshot().library }
        let merged = DeviceLibrarySnapshot.merge(base: baseline, local: read(), remote: remote.data ?? DeviceLibrarySnapshot())
        if read() != merged || needsLibraryRecovery() || needsDurableLibraryWrite() { try persistLocally(merged) }
        // Always persist local restoration first. After a crash, an old baseline can safely
        // merge again; a new baseline with old local data could undo remote deletions.
        try acknowledge(remote, identity: identity)
    }
    private func persistLocally(_ snapshot: DeviceLibrarySnapshot) throws {
        applying = true
        defer { applying = false }
        try apply(snapshot)
    }
    private func synchronize() async {
        lastSyncSucceeded = false
        do {
            guard let transport = try await connect() else { changed(after: 30); return }
            var remote = try await transport.bind()
            try Task.checkCancellation()
            try receive(remote, identity: transport.identity)
            for _ in 0..<5 {
                try Task.checkCancellation()
                let outgoing = read()
                if remote.data == outgoing || (remote.data == nil && outgoing == DeviceLibrarySnapshot()) {
                    lastSyncSucceeded = true
                    return
                }
                // A write failure can occur during the preceding PUT. Do not let a later
                // cloud baseline get ahead of the actual durable local file.
                if needsDurableLibraryWrite() { try persistLocally(outgoing) }
                let reply = try await transport.save(outgoing, revision: remote.revision)
                if reply.data == outgoing {
                    // An edit made while PUT was in flight remains in read() for the next pass.
                    try acknowledge(reply, identity: transport.identity)
                } else {
                    try receive(reply, identity: transport.identity)
                }
                remote = reply
            }
            changed(after: 2)
        } catch {
            // Keep the durable local library and baseline intact while offline; reactivation
            // and this retry both resume the same merge, without presenting a setup screen.
            changed(after: 30)
        }
    }
}
