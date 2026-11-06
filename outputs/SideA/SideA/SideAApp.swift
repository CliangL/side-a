import SwiftUI
import Combine

// Phone and CarPlay scenes can connect in either order. They share one audio session and queue.
@MainActor
final class SideASession {
    static let shared = SideASession()
    let library: LibraryStore
    let player: Player
    let discovery: DiscoveryStore
    let catalogs = SearchCatalogSettings()
    let cloud: DeviceLibrarySync
    private var listeningAI: Task<Void, Never>?
    private var playingSubscription: AnyCancellable?

    private init() {
        library = LibraryStore()
        discovery = DiscoveryStore()
        player = Player()
        let library = self.library, player = self.player, catalogs = self.catalogs
        cloud = DeviceLibrarySync(read: {
            DeviceLibrarySnapshot(library: library.snapshot, playback: player.cloudSnapshot, qqSearch: catalogs.isQQ, selectedProvider: catalogs.selectedProvider)
        }, apply: { saved in
            try library.restore(saved.library)
            player.restoreCloud(saved.playback)
            if catalogs.selectedProvider != saved.effectiveProvider { catalogs.selectProvider(saved.effectiveProvider) }
        }, needsLibraryRecovery: { library.needsCloudRecovery },
        needsDurableLibraryWrite: { library.storageError != nil }, connect: {
            await catalogs.ensureConnected()
#if DEBUG
            if LocalStorage.testID != nil && ProcessInfo.processInfo.environment["SIDEA_TEST_AUTO_ENROLL"] != "1" { return nil }
#endif
            guard let server = try CentralServer.read() else { return nil }
            return CentralLibraryTransport(server: server, recovery: try CentralServer.libraryRecovery())
        })
        library.onPersist = { [weak cloud] in cloud?.changed() }
        player.onPersist = { [weak cloud] in cloud?.changed(after: 15) }
        catalogs.onPersist = { [weak cloud] in cloud?.changed() }
        playingSubscription = player.$isPlaying.removeDuplicates().sink { [weak self] playing in
            guard let self else { return }
            self.listeningAI?.cancel()
            self.listeningAI = playing ? Task { await library.observeAI(owner: "playback") } : nil
        }
        player.onEvent = { [weak library, discovery] track, event, listened, duration in
            library?.record(track, event: event, listened: listened, duration: duration)
            if event == "manualPlay" || event == "replay" {
                library?.learnStyle(of: track, from: discovery)
            }
        }
    }
}

@main
@MainActor
struct SideAApp: App {
    private let session = SideASession.shared

    var body: some Scene {
        WindowGroup {
            SideAPhoneView(session: session)
        }
    }
}

private struct SideAPhoneView: View {
    let session: SideASession
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var library: LibraryStore

    init(session: SideASession) {
        self.session = session
        _library = ObservedObject(wrappedValue: session.library)
    }

    var body: some View {
        ContentView()
            .environmentObject(library)
            .environmentObject(session.player)
            .environmentObject(session.discovery)
            .environmentObject(session.catalogs)
            .task(id: scenePhase) {
                if scenePhase == .active { await session.cloud.flush() }
                if scenePhase == .background {
                    let background = LibraryBackgroundSave(sync: session.cloud)
                    await session.cloud.flush()
                    background.finish()
                }
            }
            .task(id: scenePhase) {
                if scenePhase == .active { await library.observeAI(owner: "phone") }
            }
            .task(id: library.seedTracks.first?.id) {
                if let track = library.seedTracks.first { library.learnStyle(of: track, from: session.discovery) }
            }
    }
}

@MainActor private final class LibraryBackgroundSave {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private weak var sync: DeviceLibrarySync?
    private var timeout: Task<Void, Never>?
    init(sync: DeviceLibrarySync) {
        self.sync = sync
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save listening library") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.expire()
        }
    }
    private func expire() { sync?.cancelCurrent(); finish() }
    func finish() {
        timeout?.cancel(); timeout = nil
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
    }
}
