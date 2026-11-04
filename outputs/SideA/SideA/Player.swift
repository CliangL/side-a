import AVFoundation
import MediaPlayer
import Network
import Combine
import UIKit

enum PlaybackMode: String, CaseIterable { case sequence, shuffle, repeatOne }

private actor PlaybackSession {
    static let shared = PlaybackSession()
    // Reserve the sequence on the UI actor before scheduling the audio operation.
    // A delayed release from an earlier pause must not silence a subsequent play.
    @MainActor private static var sequence: UInt64 = 0
    @MainActor static func nextRequest() -> UInt64 {
        sequence += 1
        return sequence
    }

    private var latestRequest: UInt64 = 0
    private var ownsSession = false

    func activate(request: UInt64) throws {
        guard request > latestRequest else { throw CancellationError() }
        latestRequest = request
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try Task.checkCancellation()
        try session.setActive(true)
        ownsSession = true
    }

    func release(request: UInt64) {
        guard request > latestRequest else { return }
        latestRequest = request
        guard ownsSession else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        } catch {
            // Retain ownership so another idle transition can retry a busy session.
        }
    }
}

@MainActor
final class Player: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var resolvedTrack: Track?
    @Published private(set) var embeddedCover: Data?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var quality = "等待音源"
    @Published var errorMessage: String?
    @Published var mode: PlaybackMode = .sequence {
        didSet { LocalStorage.defaults.set(mode.rawValue, forKey: "sidea.playMode"); if !applyingCloud { onPersist?() } }
    }
    @Published var preferLossless = true {
        didSet { LocalStorage.defaults.set(preferLossless, forKey: "sidea.preferLossless"); if !applyingCloud { onPersist?() } }
    }
    @Published var cellularDataSaver = true {
        didSet { LocalStorage.defaults.set(cellularDataSaver, forKey: "sidea.cellularDataSaver"); if !applyingCloud { onPersist?() } }
    }
    @Published var losslessOnly = false {
        didSet { LocalStorage.defaults.set(losslessOnly, forKey: "sidea.losslessOnly"); if !applyingCloud { onPersist?() } }
    }
    @Published var soundPreset: SoundPreset = .original {
        didSet {
            guard soundPreset != oldValue else { return }
            LocalStorage.defaults.set(soundPreset.rawValue, forKey: "sidea.soundPreset")
            soundTask?.cancel()
            soundStatus = soundPreset == .original ? "原声 · 未启用音效" : "播放时应用"
            if let item = engine.currentItem {
                let identity = token
                soundTask = Task { [weak self] in await self?.configureSound(item, identity: identity) }
            }
            if !applyingCloud { onPersist?() }
        }
    }
    @Published private(set) var soundStatus = "原声 · 未启用音效"
    @Published private(set) var sleepEnd: Date?

    var onPersist: (() -> Void)?
    private var applyingCloud = false
    var onEvent: ((Track, String, Double, Double) -> Void)?
    private let engine = AVPlayer()
    private let networkPath = NWPathMonitor()
    private var loadTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var artTask: Task<Void, Never>?
    private var kuwoLoader: KuwoResourceLoader?
    private var soundTask: Task<Void, Never>?
    private var soundTap: SoundTap?
    private var soundWaitingSince: TimeInterval?
    private var sleepTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var token = UUID()
    private var itemObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var tickObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var notices: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var intentToPlay = false
    private var started = false
    private var startEvent = "manualPlay"
    private var listened: Double = 0
    private var lastActiveTick: TimeInterval?
    private var refreshedURL = false
    private var resumeAfterInterruption = false
    private var resumePosition: Double = 0
    private var nowArtwork: MPMediaItemArtwork?
    private var lastSaved = 0
    private struct Resume: Codable {
        let queue: [Track]
        let index: Int
        let position: Double
    }

    init() {
        let defaults = LocalStorage.defaults
        preferLossless = defaults.object(forKey: "sidea.preferLossless") as? Bool ?? true
        losslessOnly = defaults.bool(forKey: "sidea.losslessOnly")
        cellularDataSaver = defaults.object(forKey: "sidea.cellularDataSaver") as? Bool ?? true
        soundPreset = SoundPreset.restored(defaults.string(forKey: "sidea.soundPreset"))
        soundStatus = soundPreset == .original ? "原声 · 未启用音效" : "播放时应用"
        networkPath.start(queue: DispatchQueue(label: "sidea.network-path", qos: .utility))
        mode = PlaybackMode(rawValue: defaults.string(forKey: "sidea.playMode") ?? "") ?? .sequence
        if let data = defaults.data(forKey: "sidea.resume"), let saved = try? JSONDecoder().decode(Resume.self, from: data),
           saved.queue.indices.contains(saved.index) {
            queue = saved.queue; currentIndex = saved.index; track = saved.queue[saved.index]
            elapsed = max(0, saved.position)
        }
        // Read the live status when the task runs. KVO transitions can be superseded by a rapid skip.
        controlObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.controlDidChange() }
        }
        tickObserver = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.4, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observeSystem()
        wireRemoteCommands()
    }
    deinit {
        networkPath.cancel()
        kuwoLoader?.invalidate()
        if let tickObserver { engine.removeTimeObserver(tickObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        for n in notices { NotificationCenter.default.removeObserver(n) }
        for (c,t) in remoteTargets { c.removeTarget(t) }
        loadTask?.cancel(); activationTask?.cancel(); artTask?.cancel(); sleepTask?.cancel(); stallTask?.cancel(); soundTask?.cancel()
    }
    func play(_ tracks: [Track], at index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        let repeatChoice = tracks[index].id == track?.id
        if !repeatChoice { recordSkip() }
        queue = tracks
        select(index, reason: repeatChoice ? "replay" : "manualPlay")
    }
    func play() {
        guard !isPlaying else { return }
        if track == nil {
            if !queue.isEmpty { select(0, reason: "manualPlay") }
            return
        }
        intentToPlay = true
        if engine.currentItem == nil && !isLoading {
            select(currentIndex, reason: "manualPlay", position: elapsed)
        } else if let item = engine.currentItem, item.status == .readyToPlay {
            startReadyItem(item)
        }
    }
    func toggle() {
        if intentToPlay && (isPlaying || isLoading || engine.rate > 0 || engine.timeControlStatus == .waitingToPlayAtSpecifiedRate) { pause() }
        else { play() }
    }
    func pause() {
        accumulate()
        intentToPlay = false; resumeAfterInterruption = false
        activationTask?.cancel(); activationTask = nil
        engine.pause()
        releaseAudioSession()
        isPlaying = false
        if engine.currentItem?.status == .readyToPlay { isLoading = false }
        lastActiveTick = nil
        stallTask?.cancel(); stallTask = nil
        persist(); updateNowPlaying()
    }
    func next() {
        guard !queue.isEmpty else { return }
        recordSkip()
        select(nextIndex(shuffle: mode == .shuffle), reason: "autoPlay")
    }
    func previous() {
        guard !queue.isEmpty else { return }
        if elapsed > 3 { seek(0); return }
        recordSkip()
        select((currentIndex + queue.count - 1) % queue.count, reason: "autoPlay")
    }
    private func nextIndex(shuffle: Bool) -> Int {
        if shuffle && queue.count > 1 { return (currentIndex + Int.random(in: 1..<queue.count)) % queue.count }
        return (currentIndex + 1) % max(queue.count, 1)
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let t = max(0, duration > 0 ? min(seconds, duration) : seconds)
        elapsed = t
        if engine.currentItem?.status == .readyToPlay {
            engine.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else { resumePosition = t }
        persist(); updateNowPlaying()
    }
    func enqueue(_ song: Track, next: Bool = false) {
        if queue.isEmpty {
            queue = [song]; currentIndex = 0; track = song; elapsed = 0
        } else { queue.insert(song, at: next ? min(currentIndex + 1, queue.count) : queue.count) }
        persist()
    }
    func removeQueue(at offsets: IndexSet) {
        let valid = offsets.filter { queue.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let removesCurrent = valid.contains(currentIndex), old = currentIndex
        let shouldPlay = intentToPlay || isPlaying
        for offset in valid.reversed() { queue.remove(at: offset) }
        if queue.isEmpty {
            resetItem(); currentIndex = 0; track = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else {
            currentIndex = min(old - valid.filter { $0 < old }.count, queue.count - 1)
            if removesCurrent {
                if shouldPlay { select(currentIndex, reason: "autoPlay") }
                else { resetItem(); track = queue[currentIndex]; updateNowPlaying() }
            }
        }
        persist()
    }
    func moveQueue(from offsets: IndexSet, to destination: Int) {
        let indexes = Array(queue.indices)
        let moving = indexes.filter(offsets.contains)
        var order = indexes.filter { !offsets.contains($0) }
        let start = min(max(0, destination - moving.filter { $0 < destination }.count), order.count)
        order.insert(contentsOf: moving, at: start)
        let newIndex = order.firstIndex(of: currentIndex) ?? 0
        let oldQueue = queue
        queue = order.map { oldQueue[$0] }; currentIndex = newIndex; persist()
    }
    func setSleep(minutes: Int?) {
        sleepTask?.cancel(); sleepEnd = nil
        guard let minutes, (1...1440).contains(minutes) else { return }
        sleepEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000) } catch { return }
            self?.pause(); self?.sleepEnd = nil
        }
    }
    private func releaseAudioSession() {
        let request = PlaybackSession.nextRequest()
        Task { await PlaybackSession.shared.release(request: request) }
    }

    private func resetItem(keepingAudioSession: Bool = false) {
        token = UUID()
        activationTask?.cancel(); activationTask = nil
        loadTask?.cancel(); artTask?.cancel(); stallTask?.cancel(); stallTask = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        intentToPlay = false; lastActiveTick = nil
        engine.pause(); engine.replaceCurrentItem(with: nil)
        soundTask?.cancel(); soundTask = nil; soundTap = nil; soundWaitingSince = nil
        soundStatus = soundPreset == .original ? "原声 · 未启用音效" : "播放时应用"
        kuwoLoader?.invalidate(); kuwoLoader = nil
        if !keepingAudioSession { releaseAudioSession() }
        started = false; listened = 0; duration = 0; elapsed = 0; isPlaying = false; isLoading = false
        resolvedTrack = nil; quality = "等待音源"; embeddedCover = nil; nowArtwork = nil
    }
    private func select(_ index: Int, reason: String, position: Double = 0) {
        guard queue.indices.contains(index) else { return }
        resetItem(keepingAudioSession: true)
        currentIndex = index; let chosen = queue[index]
        track = chosen; startEvent = reason; elapsed = position; resumePosition = position
        refreshedURL = false; intentToPlay = true; isLoading = true; errorMessage = nil
        updateNowPlaying(); persist()
        prepare(chosen)
    }
    private func prepare(_ chosen: Track) {
        let identity = token
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard token == identity, !Task.isCancelled else { return }
                let (recording, stream) = try await playableRecording(chosen)
                guard token == identity, !Task.isCancelled else { return }
                resolvedTrack = recording
                quality = stream.quality
                var options: [String:Any] = [AVURLAssetHTTPUserAgentKey: "Mozilla/5.0"]
                // Some GD CDN endpoints label FLAC data as audio/mpeg. Trust the checked file header.
                if stream.isFLAC { options[AVURLAssetOverrideMIMETypeKey] = "audio/flac" }
                let asset: AVURLAsset
                if KuwoResourceLoader.supports(stream.url) {
                    let loader = KuwoResourceLoader(url: stream.url)
                    self.kuwoLoader = loader
                    asset = loader.asset()
                } else { asset = AVURLAsset(url: stream.url, options: options) }
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 8
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                await configureSound(item, identity: identity)
                guard token == identity, !Task.isCancelled else { return }
                install(item, asset: asset, identity: identity)
            } catch {
                guard token == identity, !Task.isCancelled else { return }
                fail(error)
            }
        }
    }
    private func configureSound(_ item: AVPlayerItem, identity: UUID) async {
        guard token == identity, !Task.isCancelled else { return }
        if soundPreset == .original {
            item.audioMix = nil; soundTap = nil; soundWaitingSince = nil
            soundStatus = "原声 · 未启用音效"; return
        }
        soundStatus = "正在准备音效"
        do {
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            guard token == identity, !Task.isCancelled else { return }
            // Re-read after loading: selecting another scene must not apply a stale scene.
            guard soundPreset != .original else {
                item.audioMix = nil; soundTap = nil; soundStatus = "原声 · 未启用音效"; return
            }
            guard let audio = tracks.first else { throw MusicFailure.message("没有可处理的音轨") }
            let effect = try SoundTap(preset: soundPreset)
            item.audioMix = effect.mix(track: audio)
            soundTap = effect; soundWaitingSince = nil
            soundStatus = "等待播放应用音效"
        } catch {
            guard token == identity, !Task.isCancelled else { return }
            item.audioMix = nil; soundTap = nil; soundWaitingSince = nil
            soundStatus = "当前音源暂不支持音效，继续原声播放"
        }
    }
    private func updateSoundStatus() {
        guard soundPreset != .original, let soundTap else { return }
        if soundTap.processor.formatStatus.load(ordering: .acquiring) == -2 {
            soundStatus = "立体环绕需要双声道音源，继续原声播放"
        } else if soundTap.processor.formatStatus.load(ordering: .acquiring) < 0 {
            soundStatus = "当前音源暂不支持音效，继续原声播放"
        } else if soundTap.processor.framesProcessed.load(ordering: .relaxed) > 0 {
            soundStatus = soundPreset.title + " · 已开启"
            soundWaitingSince = nil
        } else if isPlaying {
            let now = ProcessInfo.processInfo.systemUptime
            if soundWaitingSince == nil { soundWaitingSince = now }
            if now - (soundWaitingSince ?? now) > 4 {
                soundStatus = "当前音源暂不支持音效，继续原声播放"
            }
        }
    }
    private func playableRecording(_ song: Track) async throws -> (Track, StreamInfo) {
        do { return (song, try await chooseStream(for: song)) }
        catch {
            try Task.checkCancellation()
            // Old favorites and playlists keep their original IDs. On source failure
            // only substitute a recording with matching title, artists, and release.
            guard song.managedCatalog != true, song.apiEndpoint == SearchCatalog.gdEndpoint,
                  let server = try? CentralServer.read(),
                  let hits = try? await GDClient.shared.search(song.title, catalog: server.catalog) else { throw error }
            for hit in hits where RecordingRanking.sameRelease(song, hit) {
                try Task.checkCancellation()
                if let stream = try? await chooseStream(for: hit) { return (hit, stream) }
            }
            throw error
        }
    }
    private func chooseStream(for song: Track) async throws -> StreamInfo {
        let client = GDClient.shared
        let path = networkPath.currentPath
        // Before the first path update, take the lower-bandwidth choice when savings is enabled.
        let saveData = cellularDataSaver && (path.usesInterfaceType(.cellular) || path.status != .satisfied)
        if !losslessOnly && (!preferLossless || saveData) {
            return try await client.stream(song, bitrate: 320)
        }
        var bestCompressed: StreamInfo?, lastError: Error?
        for bitrate in [999, 740] {
            try Task.checkCancellation()
            do {
                let candidate = try await client.stream(song, bitrate: bitrate)
                if candidate.isFLAC { return candidate }
                if candidate.bitrate >= (bestCompressed?.bitrate ?? 0) { bestCompressed = candidate }
            } catch { lastError = error }
        }
        try Task.checkCancellation()
        if losslessOnly {
            if bestCompressed == nil, let lastError { throw lastError }
            throw MusicFailure.message("这首歌当前没有可验证的无损版本。")
        }
        if let bestCompressed { return bestCompressed }
        return try await client.stream(song, bitrate: 320)
    }
    private func install(_ item: AVPlayerItem, asset: AVURLAsset, identity: UUID) {
        engine.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.token == identity, self.engine.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    if item.duration.seconds.isFinite { self.duration = max(0, item.duration.seconds) }
                    if self.resumePosition > 0 {
                        let p = self.resumePosition; self.resumePosition = 0
                        self.engine.seek(to: CMTime(seconds: p, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    if self.intentToPlay {
                        self.startReadyItem(item)
                    } else { self.isLoading = false }
                case .failed: self.recover(item.error)
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in guard self?.token == identity else { return }; self?.completed() }
        }
        watchStall()
        artTask = Task { [weak self] in
            let metadata = try? await asset.load(.commonMetadata)
            let entry = metadata.flatMap { AVMetadataItem.metadataItems(from: $0, filteredByIdentifier: .commonIdentifierArtwork).first }
            let embedded = try? await entry?.load(.dataValue)
            guard let self, self.token == identity, !Task.isCancelled, let track = self.track else { return }
            if let embedded, embedded.count < 12_000_000 { self.embeddedCover = embedded }
            var cover = self.embeddedCover
            if cover == nil { cover = await GDClient.shared.coverData(track) }
            guard self.token == identity, !Task.isCancelled, let data = cover, let ui = UIImage(data: data) else { return }
            self.nowArtwork = MPMediaItemArtwork(boundsSize: ui.size) { _ in ui }
            self.updateNowPlaying()
        }
    }
    private func startReadyItem(_ item: AVPlayerItem) {
        guard activationTask == nil, intentToPlay, engine.currentItem === item else { return }
        let identity = token
        let request = PlaybackSession.nextRequest()
        isLoading = true
        activationTask = Task { [weak self] in
            do {
                try await PlaybackSession.shared.activate(request: request)
                guard let self, !Task.isCancelled, self.token == identity, self.intentToPlay,
                      self.engine.currentItem === item, item.status == .readyToPlay else { return }
                self.activationTask = nil
                self.engine.play()
            } catch {
                guard let self, !Task.isCancelled, self.token == identity, self.intentToPlay,
                      self.engine.currentItem === item else { return }
                self.activationTask = nil
                self.fail(error)
            }
        }
    }
    private func watchStall() {
        guard stallTask == nil, intentToPlay else { return }
        let identity = token
        stallTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            guard let self, self.token == identity, self.intentToPlay, !self.isPlaying else { return }
            self.recover(MusicFailure.message("播放缓冲超时，请检查网络后重试。"))
        }
    }
    private func recover(_ error: Error?) {
        guard !refreshedURL, intentToPlay, let track else {
            fail(error ?? MusicFailure.message("无法播放这首歌，请换一个版本。")); return
        }
        refreshedURL = true
        let position = elapsed, wasStarted = started, priorListened = listened
        resetItem(keepingAudioSession: true); resumePosition = position; elapsed = position; started = wasStarted; listened = priorListened
        intentToPlay = true; isLoading = true; prepare(track)
    }
    private func fail(_ error: Error) {
        pause()
        token = UUID(); itemObservation = nil
        engine.replaceCurrentItem(with: nil); isLoading = false
        errorMessage = error.localizedDescription
    }
    private func accumulate() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastActiveTick { listened += max(0, now - lastActiveTick); self.lastActiveTick = now }
    }
    private func controlDidChange() {
        let playing = engine.timeControlStatus == .playing && intentToPlay
        if !playing { accumulate(); lastActiveTick = nil }
        else if lastActiveTick == nil { lastActiveTick = ProcessInfo.processInfo.systemUptime }
        isPlaying = playing
        if playing {
            isLoading = false; stallTask?.cancel(); stallTask = nil
            if !started, let track {
                started = true; onEvent?(track, startEvent, 0, duration)
            }
        } else if engine.timeControlStatus == .waitingToPlayAtSpecifiedRate && intentToPlay {
            isLoading = true; watchStall()
        }
        updateNowPlaying()
    }
    private func tick() {
        updateSoundStatus()
        guard let item = engine.currentItem, item.status == .readyToPlay else { return }
        let p = engine.currentTime().seconds, total = item.duration.seconds
        if p.isFinite { elapsed = max(0,p) }
        if total.isFinite { duration = max(0,total) }
        accumulate()
        let mark = Int(elapsed)/5
        if mark != lastSaved { lastSaved = mark; persist() }
    }
    private func recordSkip() {
        accumulate()
        if started, !isLoading, errorMessage == nil, let track { onEvent?(track,"skip",listened,duration) }
    }
    private func completed() {
        accumulate()
        if started, let track { onEvent?(track,"complete",listened,duration) }
        if mode == .repeatOne { select(currentIndex, reason: "autoPlay") }
        else if currentIndex < queue.count-1 || mode == .shuffle { select(nextIndex(shuffle: mode == .shuffle), reason: "autoPlay") }
        else { resetItem(); persist(); updateNowPlaying() }
    }
    var cloudSnapshot: CloudPlayback {
        CloudPlayback(mode: mode.rawValue, preferLossless: preferLossless, cellularDataSaver: cellularDataSaver,
                      losslessOnly: losslessOnly, resume: CloudPlayback.Resume(queue: queue, index: currentIndex, position: elapsed), soundPreset: soundPreset.rawValue)
    }

    func restoreCloud(_ saved: CloudPlayback) {
        applyingCloud = true
        defer { applyingCloud = false }
        mode = PlaybackMode(rawValue: saved.mode) ?? .sequence
        soundPreset = SoundPreset.restored(saved.soundPreset)
        preferLossless = saved.preferLossless; cellularDataSaver = saved.cellularDataSaver; losslessOnly = saved.losslessOnly
        // Cloud restoration must never interrupt a song the listener has already started.
        if !intentToPlay && !isPlaying && !isLoading, cloudSnapshot.resume != saved.resume {
            resetItem()
            queue = saved.resume.queue
            currentIndex = queue.indices.contains(saved.resume.index) ? saved.resume.index : 0
            track = queue.isEmpty ? nil : queue[currentIndex]
            elapsed = saved.resume.position.isFinite ? max(0, saved.resume.position) : 0
            persist(); updateNowPlaying()
        }
    }

    private func persist() {
        defer { if !applyingCloud { onPersist?() } }
        let defaults = LocalStorage.defaults
        guard !queue.isEmpty else { defaults.removeObject(forKey: "sidea.resume"); return }
        if let data = try? JSONEncoder().encode(Resume(queue: queue, index: currentIndex, position: elapsed)) {
            defaults.set(data, forKey: "sidea.resume")
        }
    }
    private func updateNowPlaying() {
        guard let track else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String:Any] = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album, MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let nowArtwork { info[MPMediaItemPropertyArtwork] = nowArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func observeSystem() {
        let center = NotificationCenter.default, session = AVAudioSession.sharedInstance()
        notices.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
            let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    let active = self.intentToPlay; self.pause(); self.resumeAfterInterruption = active
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    let resume = self.resumeAfterInterruption; self.resumeAfterInterruption = false
                    if resume && AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) { self.play() }
                }
            }
        })
        notices.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] n in
            if (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        notices.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.persist() }
        })
    }
    private func wireRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in Task { @MainActor in action() }; return .success }
            remoteTargets.append((command,target))
        }
        add(c.playCommand) { [weak self] in self?.play() }
        add(c.pauseCommand) { [weak self] in self?.pause() }
        add(c.togglePlayPauseCommand) { [weak self] in self?.toggle() }
        add(c.nextTrackCommand) { [weak self] in self?.next() }
        add(c.previousTrackCommand) { [weak self] in self?.previous() }
        c.changePlaybackPositionCommand.isEnabled = true
        let position = c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let value = e.positionTime
            Task { @MainActor in self?.seek(value) }; return .success
        }
        remoteTargets.append((c.changePlaybackPositionCommand,position))
    }
}
