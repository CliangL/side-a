import SwiftUI

enum SectionRoute: Hashable {
    case playlist(UUID), favorites, recent, cache, mix(Int), related(Track)
}
enum UISheet: Identifiable {
    case search, queue, add(Track)
    var id: String {
        switch self { case .search: "search"; case .queue: "queue"; case let .add(t): "add-" + t.id }
    }
}
@MainActor final class NavigationModel: ObservableObject {
    @Published var tab = 0
    @Published var path: [SectionRoute] = []
    @Published var sheet: UISheet?
    @Published var playerOpen = false
    func tab(_ value: Int) { path = []; tab = value }
}
struct ContentView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var discovery: DiscoveryStore
    @StateObject private var nav = NavigationModel()
    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $nav.path) {
                Group { if nav.tab == 0 { HomeView() } else { LibraryView() } }
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: SectionRoute.self) { route in
                        Group {
                            switch route {
                            case .cache: SettingsView()
                            default: CollectionView(route: route)
                            }
                        }.toolbarBackground(Ink.paper, for: .navigationBar).navigationBarTitleDisplayMode(.inline)
                    }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                if player.track != nil { MiniView().padding(.horizontal, 13).padding(.top, 4) }
                HStack(spacing: 68) {
                    tabButton("首页", icon: "house", tab: 0)
                    tabButton("我的", icon: "books.vertical", tab: 1)
                }.padding(.top, 3).frame(height: 46).frame(maxWidth:.infinity)
                    .background { Ink.paper.ignoresSafeArea(edges:.bottom) }
            }.frame(maxWidth: .infinity).background {
                LinearGradient(colors: [Ink.paper.opacity(0.6), Ink.paper], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom)
            }
        }
        .sheet(item: $nav.sheet) { sheet in
            switch sheet {
            case .search: SearchView()
            case .queue: QueueView()
            case let .add(track): AddToPlaylistView(track: track)
            }
        }
        .fullScreenCover(isPresented: $nav.playerOpen) { PlayingView() }
        .environmentObject(nav).tint(Ink.teal)
        .task { await discovery.refresh() }
    }
    private func tabButton(_ title: String, icon: String, tab: Int) -> some View {
        Button { nav.tab(tab) } label: {
            Label(title, systemImage: icon + (nav.tab == tab ? ".fill" : ""))
                .font(.system(size: 14, weight: nav.tab == tab ? .semibold : .regular))
                .foregroundStyle(nav.tab == tab ? Ink.teal : Ink.quiet).frame(minHeight: 42)
        }.buttonStyle(.plain).accessibilityIdentifier(tab == 0 ? "tab.home" : "tab.library")
    }
}

private struct HomeView: View {
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: Player
    @EnvironmentObject var discovery: DiscoveryStore
    @State private var recentTab = false
    @State private var page: Int? = 0
    @State private var batch = 0
    @State private var neighbors: [Track] = []
    private var seed: Track? { library.seedTracks.first }
    private var candidates: [Track] { discovery.explored + neighbors + discovery.newReleases + discovery.hot + Track.starterTracks }
    private var personal: [Track] { library.recommendations(from: candidates) }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Button { nav.sheet = .search } label: {
                        Label("搜索歌曲、歌手、专辑", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading).font(.subheadline).foregroundStyle(Ink.quiet)
                            .padding(.horizontal, 16).frame(height: 41).glassPlate(24)
                    }.buttonStyle(.plain).padding(.horizontal, 20).accessibilityIdentifier("home.search")
                    HStack(spacing: 23) {
                        segment("推荐", value: false); segment("最近常听", value: true)
                    }.padding(.horizontal, 20)
                    if recentTab {
                        recentContent
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(0..<3, id: \.self) { i in
                                    let items = i == 0 ? personal : (i == 1 ? discovery.hot : discovery.newReleases)
                                    FeatureCard(title: ["为你选的", "最近热歌", "近七天新歌"][i],
                                                subtitle: ["按你的收听偏好选曲", discovery.hotSource, discovery.newSource][i],
                                                side: ["Side A", "Side B", "Side C"][i], caption: ["私人电台", "热歌唱片", "新发行"][i],
                                                track: items.first, open: { nav.path.append(.mix(i)) },
                                                play: { player.play(items); nav.playerOpen = true }, playable: !items.isEmpty)
                                    .frame(width: max(230, min(460, geometry.size.width - 62))).id(i)
                                }
                            }.scrollTargetLayout()
                        }.contentMargins(.horizontal, 20, for: .scrollContent).scrollIndicators(.hidden)
                            .scrollTargetBehavior(.viewAligned).scrollPosition(id: $page)
                        HStack(spacing: 5) {
                            ForEach(0..<3, id: \.self) { i in Capsule().fill(i == (page ?? 0) ? Ink.teal : Ink.quiet.opacity(0.26)).frame(width: i == (page ?? 0) ? 15 : 4, height: 4) }
                        }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                SectionTitle(title: "顺着你的口味", note: library.reason)
                                Button("换一批") { library.nextRecommendations(from: candidates); batch = 0 }.font(.caption).accessibilityIdentifier("home.refreshSuggestions")
                            }
                            ForEach(batchItems) { t in TrackRow(track: t, queue: batchItems, showMenu: false) }
                            if personal.isEmpty { EmptyHint(title: "从一首喜欢的歌开始", detail: "搜歌、重播或收藏后，这里会慢慢长出你的口味。") }
                            HStack {
                                SectionTitle(title: "最近常听")
                                if !library.recent.isEmpty { Button("全部") { nav.path.append(.recent) }.font(.caption) }
                            }.padding(.top, 13)
                            if let last = library.recent.first { TrackRow(track: last, queue: library.recent, showMenu: false) }
                            else { Text("听过的歌曲会在这里留下唱片印记。").font(.footnote).foregroundStyle(Ink.quiet).padding(.vertical, 7) }
                        }.padding(.horizontal, 20)
                    }
                }.padding(.top, 5).padding(.bottom, 18)
            }.refreshable { library.nextRecommendations(from: candidates); batch = 0; await discovery.refresh(force: true) }.background { Paper() }
        }
        .task(id: library.aiRequestKey(from: candidates)) { library.requestAI(from: candidates) }
        .task(id: library.seedTracks.prefix(2).map(\.id).joined(separator: "|") + String(library.recommendationTurn)) {
            let found = await discovery.explore(seeds: library.seedTracks, turn: library.recommendationTurn)
            if !Task.isCancelled { discovery.explored = found }
        }
        .task(id: seed?.id) {
            neighbors = []
            if let seed { let result = await discovery.related(to: seed); if !Task.isCancelled { neighbors = result } }
        }
    }
    private var batchItems: [Track] {
        let all = personal
        guard !all.isEmpty else { return [] }
        let start = (batch * 3) % all.count
        return (0..<min(3, all.count)).map { all[(start + $0) % all.count] }
    }
    private func segment(_ title: String, value: Bool) -> some View {
        Button(title) { withAnimation(.easeOut(duration: 0.15)) { recentTab = value } }
            .font(recentTab == value ? .title2.bold() : .subheadline)
            .foregroundStyle(recentTab == value ? Ink.dark : Ink.quiet).buttonStyle(.plain)
    }
    private var recentContent: some View {
        VStack { if library.recent.isEmpty { EmptyHint(title: "还没有收听记录", detail: "点一首歌开始听，最近播放会出现在这里。") }
            ForEach(library.recent) { TrackRow(track: $0, queue: library.recent) }
        }.padding(.horizontal, 20)
    }
}

struct MiniView: View {
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: Player
    var body: some View {
        if let track = player.track {
            HStack(spacing: 5) {
                Button { nav.playerOpen = true } label: {
                    HStack(spacing: 11) {
                        ArtView(track: track, embedded: player.embeddedCover).frame(width: 43, height: 43).clipShape(RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(player.isLoading ? "正在载入…" : track.artist).font(.caption2).foregroundStyle(Ink.quiet).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("mini.open")
                FavoriteButton(track: track)
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 34, height: 42) }
                    .accessibilityLabel(player.isPlaying ? "暂停" : "播放").accessibilityIdentifier("mini.toggle")
                Button { nav.sheet = .queue } label: { Image(systemName: "list.bullet").frame(width: 32, height: 42) }.accessibilityLabel("待播列表")
            }.foregroundStyle(Ink.dark).buttonStyle(.plain).padding(.leading, 6).padding(.trailing, 7).frame(height: 56)
                .glassPlate(18).shadow(color: Ink.dark.opacity(0.11), radius: 7, y: 2)
        }
    }
}

struct FavoriteButton: View {
    @EnvironmentObject var library: LibraryStore
    let track: Track
    var body: some View {
        let selected = library.isFavorite(track)
        Button { library.toggleFavorite(track) } label: { Image(systemName: selected ? "heart.fill" : "heart").frame(width: 34, height: 43).foregroundStyle(selected ? Ink.rose : Ink.quiet) }
            .buttonStyle(.plain).accessibilityLabel(selected ? "取消收藏" : "收藏").accessibilityIdentifier("favorite." + track.id)
    }
}

struct TrackRow: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var nav: NavigationModel
    let track: Track
    var queue: [Track]
    var subtitle: String? = nil
    var playlistID: UUID? = nil
    var showMenu = true
    var afterPlay: (() -> Void)? = nil
    @State private var addOpen = false
    @State private var styleOpen = false
    var body: some View {
        HStack(spacing: 4) {
            Button {
                player.play(queue, at: queue.firstIndex(where: { $0.id == track.id }) ?? 0)
                afterPlay?()
            } label: {
                HStack(spacing: 12) {
                    ArtView(track: track).frame(width: 43, height: 43).clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 16, weight: .medium)).foregroundStyle(player.track?.id == track.id ? Ink.teal : Ink.dark)
                        Text(subtitle ?? track.artist).font(.caption).foregroundStyle(Ink.quiet).lineLimit(subtitle == nil ? 1 : 2)
                    }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("track.play." + track.id)
            FavoriteButton(track: track)
            if showMenu {
                Menu { actions } label: { Image(systemName: "ellipsis").font(.body).frame(width: 28, height: 44).foregroundStyle(Ink.quiet) }.accessibilityLabel("更多歌曲操作")
            }
        }.padding(.vertical, 3).contextMenu { actions }
            .sheet(isPresented: $addOpen) { AddToPlaylistView(track: track) }
            .sheet(isPresented: $styleOpen) { StyleFeedbackView(track:track) }
    }
    @ViewBuilder private var actions: some View {
        Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(track, next: true) }
        Button("加入待播", systemImage: "text.append") { player.enqueue(track, next: false) }
        Button("加入歌单", systemImage: "text.badge.plus") { addOpen = true }
        Button("沿着这首听", systemImage: "dot.radiowaves.left.and.right") {
            nav.sheet = nil; nav.playerOpen = false; nav.path.append(.related(track))
        }
        Button("少推荐这首", systemImage: "hand.thumbsdown") { library.dislike(track) }
        Button("少推荐这种风格",systemImage:"slider.horizontal.3") { styleOpen = true }
        if let playlistID { Button("从此歌单移除", systemImage: "minus.circle", role: .destructive) { library.remove(track, from: playlistID) } }
    }
}

struct StyleFeedbackView: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var discovery: DiscoveryStore
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String] = []
    @State private var loading = true
    @State private var request = 0
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading { ProgressView("查找歌曲的风格标签…") }
                    else if tags.isEmpty {
                        Text("没有找到《\(track.title)》的可用风格标签。").font(.footnote).foregroundStyle(Ink.quiet)
                        Button("再试一次") { request += 1 }
                        Button("只少推荐这首歌") { library.dislike(track); dismiss() }
                    } else {
                        ForEach(tags,id:\.self) { tag in
                            Button {
                                library.reduceStyle(of:track,tags:[tag]); dismiss()
                            } label: { HStack { Text(tag); Spacer(); Image(systemName:"minus.circle") } }
                        }
                    }
                } header: { Text(track.title) }
                footer: { Text("选择你希望少听的风格。反馈会调整「为你选的」，保留原有收藏。") }
            }.scrollContentBackground(.hidden).background { Paper() }
                .navigationTitle("少推荐这种风格").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
        }.presentationDetents([.medium,.large])
        .task(id:request) {
            loading = true
            let values = track.genres.isEmpty ? await discovery.genres(for:track) : track.genres
            if !Task.isCancelled {
                tags = Array(Set(values.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                loading = false
            }
        }
    }
}
