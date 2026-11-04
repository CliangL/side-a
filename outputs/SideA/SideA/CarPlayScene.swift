import CarPlay
import Combine
import UIKit

/// The car and phone share a single player, queue and library. Disconnecting the car only releases its UI.
@objc(CarPlaySceneDelegate)
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    enum Page {
        case discover, library, personal, hot, newMusic, favorites, recent, playlists, playlist(UUID), queue
    }

    private let session = SideASession.shared
    private weak var controller: CPInterfaceController?
    private var roots: [CPListTemplate] = []
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var similarTask: Task<Void, Never>?
    private var seedID: String?
    private var neighbors: [Track] = []

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
        observeChanges()
        refresh()
        refreshTask = Task { [weak self] in
            await self?.session.cloud.flush()
            await self?.session.discovery.refresh()
        }
    }

    func makeRootTemplate() -> CPTabBarTemplate {
        let discover = makeList(.discover, title: "发现")
        discover.tabImage = UIImage(systemName: "music.note.list")
        let library = makeList(.library, title: "我的")
        library.tabImage = UIImage(systemName: "books.vertical")
        roots = [discover, library]
        return CPTabBarTemplate(templates: roots)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        guard controller === interfaceController else { return }
        controller = nil
        roots.removeAll()
        subscriptions.removeAll()
        refreshTask?.cancel()
        similarTask?.cancel()
        neighbors.removeAll()
        seedID = nil
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
    }

    private func observeChanges() {
        let player = session.player
        // Observe changes that affect the lists, without rebuilding them for each progress tick.
        let changes: [AnyPublisher<Void, Never>] = [
            session.library.objectWillChange.eraseToAnyPublisher(),
            session.discovery.objectWillChange.eraseToAnyPublisher(),
            player.$track.map { _ in () }.eraseToAnyPublisher(),
            player.$isPlaying.map { _ in () }.eraseToAnyPublisher(),
            player.$queue.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        player.$errorMessage
            .dropFirst().compactMap { $0 }.receive(on: RunLoop.main)
            .sink { [weak self] error in self?.showPlaybackError(error) }
            .store(in: &subscriptions)
    }

    private func refresh() {
        guard let controller else { return }
        let seed = session.library.seedTracks.first
        if seedID != seed?.id {
            similarTask?.cancel()
            seedID = seed?.id
            neighbors = []
            if let seed {
                similarTask = Task { [weak self, discovery = session.discovery] in
                    let matches = await discovery.related(to: seed)
                    guard !Task.isCancelled, let self, self.seedID == seed.id else { return }
                    self.neighbors = matches
                    self.refresh()
                }
            }
        }
        // CarPlay keeps only the active tab's stack in templates; root lists are always kept current.
        var visited = Set<ObjectIdentifier>()
        for list in roots + controller.templates.compactMap({ $0 as? CPListTemplate }) {
            if visited.insert(ObjectIdentifier(list)).inserted, let page = list.userInfo as? Page {
                populate(list, page: page)
            }
        }
        updateFavoriteButton()
    }

    func makeList(_ page: Page, title: String) -> CPListTemplate {
        let result = CPListTemplate(title: title, sections: [])
        result.userInfo = page
        populate(result, page: page)
        return result
    }

    private func populate(_ list: CPListTemplate, page: Page) {
        let library = session.library
        let discovery = session.discovery
        var items: [CPListItem]
        var empty = "暂时没有歌曲"
        var detail = ""
        switch page {
        case .discover:
            items = [
                folder("为你选的", detail: library.reason, icon: "sparkles", page: .personal),
                folder("最近热歌", detail: discovery.hotSource, icon: "chart.line.uptrend.xyaxis", page: .hot),
                folder("近七天新歌", detail: discovery.newSource, icon: "music.note", page: .newMusic)
            ]
        case .library:
            items = [
                folder("我的收藏", detail: "\(library.favorites.count) 首", icon: "heart", page: .favorites),
                folder("我的歌单", detail: "\(library.playlists.count) 张歌单", icon: "music.note.list", page: .playlists),
                folder("最近播放", detail: nil, icon: "clock", page: .recent),
                folder("待播列表", detail: nil, icon: "list.bullet", page: .queue)
            ]
            if let current = session.player.track {
                let now = CPListItem(text: "正在播放", detailText: current.title, image: UIImage(systemName: "waveform"))
                now.handler = { [weak self] _, done in
                    guard let self else { done(); return }
                    self.showNowPlaying(completion: done)
                }
                items.insert(now, at: 0)
            }
        case .playlists:
            items = library.playlists.prefix(CPListTemplate.maximumItemCount).map {
                folder($0.name, detail: "\($0.tracks.count) 首", icon: "music.note.list", page: .playlist($0.id))
            }
            empty = "还没有歌单"
            detail = "可以在 iPhone 上创建歌单。"
        case .personal:
            items = songItems(library.recommendations(from: neighbors + Track.starterTracks + discovery.newReleases + discovery.hot))
        case .hot, .newMusic:
            let isHot: Bool
            if case .hot = page { isHot = true } else { isHot = false }
            items = songItems(isHot ? discovery.hot : discovery.newReleases)
            empty = discovery.isLoading ? "正在读取榜单" : "暂时没有可用歌曲"
            detail = discovery.notice ?? ""
            if items.isEmpty, !discovery.isLoading, discovery.notice != nil {
                let retry = CPListItem(text: "重新载入榜单", detailText: nil)
                retry.handler = { [weak self] _, done in
                    guard let self else { done(); return }
                    self.refreshTask?.cancel()
                    self.refreshTask = Task { [weak self] in await self?.session.discovery.refresh(force: true) }
                    done()
                }
                items = [retry]
            }
        case .favorites:
            items = songItems(library.favorites)
            empty = "还没有收藏"
            detail = "听到喜欢的歌，可以在播放页点爱心。"
        case .recent:
            items = songItems(library.recent)
            empty = "还没有播放记录"
        case .playlist(let id):
            items = songItems(library.playlists.first { $0.id == id }?.tracks ?? [])
        case .queue:
            items = songItems(session.player.queue)
            empty = "待播列表为空"
        }
        list.emptyViewTitleVariants = [empty]
        list.emptyViewSubtitleVariants = detail.isEmpty ? [] : [detail]
        list.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    private func folder(_ title: String, detail: String?, icon: String, page: Page) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: UIImage(systemName: icon))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, done in
            guard let self, let controller = self.controller else { done(); return }
            controller.pushTemplate(self.makeList(page, title: title), animated: true) { _, _ in done() }
        }
        return item
    }

    private func songItems(_ songs: [Track]) -> [CPListItem] {
        songs.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, track in
            let item = CPListItem(text: track.title, detailText: track.artist)
            item.isPlaying = session.player.isPlaying && track.id == session.player.track?.id
            item.handler = { [weak self] _, done in
                guard let self, self.controller != nil else { done(); return }
                self.session.player.play(songs, at: index)
                self.showNowPlaying(completion: done)
            }
            return item
        }
    }

    private func showNowPlaying(completion: @escaping () -> Void) {
        guard let controller else { completion(); return }
        let now = CPNowPlayingTemplate.shared
        if controller.topTemplate === now { completion(); return }
        if controller.templates.contains(where: { $0 === now }) {
            controller.pop(to: now, animated: true) { _, _ in completion() }
        } else {
            controller.pushTemplate(now, animated: true) { _, _ in completion() }
        }
    }

    private func updateFavoriteButton() {
        guard let track = session.player.track,
              let image = UIImage(systemName: session.library.isFavorite(track) ? "heart.fill" : "heart") else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }
        let button = CPNowPlayingImageButton(image: image) { [weak self] _ in
            guard let self, let current = self.session.player.track else { return }
            self.session.library.toggleFavorite(current)
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([button])
    }

    private func showPlaybackError(_ message: String) {
        guard let controller, controller.presentedTemplate == nil, let track = session.player.track else { return }
        let retry = CPAlertAction(title: "重试", style: .default) { [weak self] _ in
            guard let self, self.session.player.track?.id == track.id else { return }
            let player = self.session.player
            player.play(player.queue, at: player.currentIndex)
        }
        let dismiss = CPAlertAction(title: "关闭", style: .cancel) { _ in }
        let alert = CPAlertTemplate(titleVariants: [message, "当前歌曲无法播放"], actions: [retry, dismiss])
        controller.presentTemplate(alert, animated: true, completion: nil)
    }
}
