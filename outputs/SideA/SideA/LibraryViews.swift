import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var nav: NavigationModel
    @State private var newName = ""
    @State private var creating = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text("Side B").font(Ink.side(22)).foregroundStyle(Ink.quiet)
                            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                                Text("v" + version).font(.caption).foregroundStyle(Ink.quiet).accessibilityIdentifier("library.version")
                            }
                        }
                        Text("我的唱片室").font(Ink.title(32))
                    }
                    Spacer()
                    Button { nav.path.append(.cache) } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).glassPlate(22) }.accessibilityLabel("缓存与偏好设置").accessibilityIdentifier("library.settings")
                }
                NavigationLink(value: SectionRoute.favorites) {
                    HStack(spacing: 15) {
                        ZStack { LinearGradient(colors: [Ink.rose.opacity(0.69), Ink.warm], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "heart.fill").font(.title2).foregroundStyle(.white.opacity(0.87)) }.frame(width: 64,height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) { Text("我的收藏").font(.headline); Text("\(library.favorites.count) 首歌曲").font(.caption).foregroundStyle(Ink.quiet) }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(Ink.quiet)
                    }.padding(12).glassPlate(20)
                }.buttonStyle(.plain).accessibilityIdentifier("library.favorites")
                HStack { SectionTitle(title: "我的歌单"); Button { newName = ""; creating = true } label: { Image(systemName: "plus").frame(width: 38,height: 38).glassPlate(19) }.accessibilityLabel("新建歌单").accessibilityIdentifier("library.newPlaylist") }
                if library.playlists.isEmpty { Text("把适合某个时刻的歌收在一起。").font(.footnote).foregroundStyle(Ink.quiet) }
                ForEach(library.playlists) { list in
                    NavigationLink(value: SectionRoute.playlist(list.id)) {
                        HStack(spacing: 12) {
                            ArtView(track: list.cover ?? list.tracks.first).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) { Text(list.name).font(.body.weight(.medium)); Text("\(list.tracks.count) 首歌曲").font(.caption).foregroundStyle(Ink.quiet) }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }
                    }.buttonStyle(.plain)
                }
                Divider()
                NavigationLink(value: SectionRoute.recent) { Label("最近播放", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity,alignment:.leading) }.buttonStyle(.plain)
            }.padding(20)
        }.background { Paper() }.foregroundStyle(Ink.dark)
            .alert("新建歌单", isPresented: $creating) {
                TextField("歌单名称", text: $newName)
                Button("取消",role:.cancel) {}
                Button("创建") { library.createPlaylist(newName.trimmingCharacters(in: .whitespacesAndNewlines)) }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
    }
}

struct CollectionView: View {
    let route: SectionRoute
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: Player
    @EnvironmentObject var discovery: DiscoveryStore
    @EnvironmentObject var nav: NavigationModel
    @Environment(\.dismiss) private var dismiss
    @State private var related = [Track]()
    @State private var relatedBusy = false
    @State private var editMode = EditMode.inactive
    @State private var naming = false
    @State private var deleting = false
    @State private var newName = ""
    @State private var isAddingSongs = false
    @State private var editSheet: PlaylistEditAction?
    @State private var filter = ""
    @State private var filtering = false
    private var list: UserPlaylist? {
        if case let .playlist(id) = route { return library.playlists.first { $0.id == id } }
        return nil
    }
    private var isExternalMix: Bool { switch route { case .mix(1), .mix(2): true; default:false } }
    private var seed: Track? {
        if case let .related(track) = route { return track }
        if route == .mix(0) { return library.seedTracks.first }
        return nil
    }
    private var aiCandidates: [Track] { discovery.explored + related + discovery.newReleases + discovery.hot + Track.starterTracks }
    private var tracks: [Track] {
        switch route {
        case .playlist: list?.tracks ?? []
        case .favorites: library.favorites
        case .recent: library.recent
        case .mix(1): discovery.hot
        case .mix(2): discovery.newReleases
        case .mix: library.recommendations(from: aiCandidates)
        case .related: related
        default: []
        }
    }
    private var name: String {
        switch route {
        case .playlist: list?.name ?? "歌单"
        case .favorites: "我的收藏"
        case .recent: "最近播放"
        case .mix(1): "最近热歌"
        case .mix(2): "近七天新歌"
        case .mix: "为你选的"
        case .related: "沿着这首听"
        default: ""
        }
    }
    private var note: String {
        switch route {
        case .mix(1): discovery.hotSource
        case .mix(2): discovery.newSource
        case .mix: library.reason
        case let .related(track): "从《\(track.title)》出发"
        default: "\(tracks.count) 首歌曲"
        }
    }
    var body: some View {
        List {
            VStack(spacing: 13) {
                CollectionSleeve(title:name,note:note,tracks:tracks,fallback:seed,selectedCover:list?.cover)
                HStack(spacing: 9) {
                    Button { player.play(tracks) } label: { Label("播放全部", systemImage:"play.fill").frame(maxWidth:.infinity,minHeight:40).background(Ink.forest,in:Capsule()).foregroundStyle(.white) }
                    Button { player.play(tracks.shuffled()) } label: { Label("随机播放", systemImage:"shuffle").frame(maxWidth:.infinity,minHeight:40).background(Ink.teal.opacity(0.08),in:Capsule()) }
                }.font(.subheadline.weight(.medium)).buttonStyle(.plain).disabled(tracks.isEmpty)
                HStack {
                    Text("歌曲").font(.caption).foregroundStyle(Ink.quiet); Spacer()
                    if tracks.count > 1 && editMode != .active { Button { filtering.toggle(); filter = "" } label: { Image(systemName:"magnifyingglass").frame(width:26,height:28) }.accessibilityLabel("在歌单中查找") }
                    if list != nil {
                        Button { isAddingSongs = true } label: { Label("添加歌曲",systemImage:"plus") }
                        Button(editMode == .active ? "完成" : "排序") { withAnimation { filter = ""; filtering = false; editMode = editMode == .active ? .inactive : .active } }
                    } else if case .mix = route, !tracks.isEmpty { Button("保存为歌单") { saveMix() } }
                }.font(.caption).padding(.vertical,4)
                if filtering { TextField("在这张歌单中搜索", text:$filter).autocorrectionDisabled().textInputAutocapitalization(.never).padding(.horizontal,12).frame(height:38).glassPlate(18) }
            }.listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            if isExternalMix, let notice = discovery.notice { Text(notice).font(.caption).foregroundStyle(Ink.quiet).listRowBackground(Color.clear) }
            if tracks.isEmpty {
                VStack {
                    if relatedBusy || (isExternalMix && discovery.isLoading) { ProgressView().padding(24) }
                    else {
                        EmptyHint(title: "暂时没有歌曲",detail: emptyNote)
                        if isExternalMix { Button("重新加载") { Task { await discovery.refresh(force: true) } } }
                        else if let seed { Button("重新查找") { Task { await loadRelated(seed) } } }
                        else if list != nil { Button("添加歌曲") { isAddingSongs = true } }
                        else { Button("搜索音乐") { nav.sheet = .search } }
                    }
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if !tracks.isEmpty && visibleTracks.isEmpty { Text("没有匹配的歌曲").foregroundStyle(Ink.quiet).listRowBackground(Color.clear) }
            ForEach(visibleTracks) { t in
                TrackRow(track: t, queue: tracks,
                         subtitle: route == .mix(2) ? [t.artist, discovery.releaseLabel(for: t)].compactMap { $0 }.joined(separator:" · ") : nil,
                         playlistID: list?.id)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top:0,leading:20,bottom:0,trailing:16)).listRowSeparator(.hidden)
            }.onMove { offsets, to in if let list { library.reorder(list.id, from: offsets, to: to) } }
        }.listStyle(.plain).scrollContentBackground(.hidden).background { Paper() }.environment(\.editMode, $editMode)
            .toolbar {
                if let list {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("重命名",systemImage:"pencil") { newName = list.name; naming = true }
                            Button("更换封面",systemImage:"photo.on.rectangle.angled") { editSheet = .cover }.disabled(tracks.isEmpty && list.cover == nil)
                            Button("批量移除歌曲",systemImage:"checklist") { editSheet = .remove }.disabled(tracks.isEmpty)
                            Button("删除歌单",systemImage:"trash",role:.destructive) { deleting = true }
                        } label: { Image(systemName:"ellipsis.circle") }.accessibilityLabel("编辑歌单").accessibilityIdentifier("playlist.actions")
                    }
                }
            }
            .task(id: library.aiRequestKey(from: aiCandidates)) { if route == .mix(0) { library.requestAI(from: aiCandidates) } }
            .task(id: seed?.id) { if let seed { await loadRelated(seed) } }
            .refreshable { if route == .mix(0) { library.nextRecommendations(from: aiCandidates); discovery.explored = await discovery.explore(seeds: library.seedTracks, turn: library.recommendationTurn) }; if isExternalMix { await discovery.refresh(force: true) }; if let seed { await loadRelated(seed) } }
            .sheet(isPresented: $isAddingSongs) { if let list { SearchView(target: list.id) } }
            .sheet(item:$editSheet) { action in if let list { PlaylistEditingView(id:list.id, action:action) } }
            .alert("重命名歌单", isPresented: $naming) {
                TextField("名称",text:$newName); Button("取消",role:.cancel) {}
                Button("保存") { if let list { library.renamePlaylist(list.id, name: newName) } }.disabled(newName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("删除这张歌单？", isPresented: $deleting) {
                Button("删除歌单",role:.destructive) { if let list { library.deletePlaylist(list.id); dismiss() } }
            }
    }
    private var visibleTracks: [Track] {
        let phrase = filter.trimmingCharacters(in:.whitespacesAndNewlines)
        return phrase.isEmpty ? tracks : tracks.filter { ($0.title + " " + $0.artist).localizedCaseInsensitiveContains(phrase) }
    }
    private var emptyNote: String {
        switch route {
        case .related: "这首歌目前没有匹配到可用的相似曲目。"
        case .mix(1), .mix(2): "可以下拉刷新，或稍后再试。"
        case .favorites: "在歌曲旁点亮爱心，就会收进这里。"
        default: "可以通过搜索找到想听的曲目。"
        }
    }
    private func saveMix() {
        var targetName = name
        var suffix = 1
        while library.playlists.contains(where: { $0.name == targetName }) { suffix += 1; targetName = name + " " + String(suffix) }
        if let id = library.createPlaylist(targetName, tracks:tracks) { nav.path.append(.playlist(id)) }
    }
    private func loadRelated(_ seed: Track) async {
        relatedBusy = true
        let result = await discovery.related(to: seed)
        if !Task.isCancelled { related = result; relatedBusy = false }
    }
}

struct AddToPlaylistView: View {
    let track: Track
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("新歌单") {
                    TextField("歌单名称", text:$name)
                    Button("创建并加入") {
                        let title = name.trimmingCharacters(in:.whitespacesAndNewlines)
                        if let dest = library.playlists.first(where: { $0.name == title }) {
                            library.add(track,to:dest.id); dismiss()
                        } else if library.createPlaylist(title,tracks:[track]) != nil { dismiss() }
                    }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Section("我的歌单") {
                    ForEach(library.playlists) { list in
                        let has = list.tracks.contains { $0.id == track.id }
                        Button { library.add(track,to:list.id); dismiss() } label: {
                            HStack { Text(list.name); Spacer(); Image(systemName: has ? "checkmark" : "plus") }
                        }.disabled(has)
                    }
                }
            }.scrollContentBackground(.hidden).background { Paper() }.navigationTitle("加入歌单").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium,.large])
    }
}

struct SettingsView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: LibraryStore
    @State private var cacheBytes: Int?
    @State private var resetPrompt = false
    @State private var clearing = false

    var body: some View {
        Form {
            Section("播放") {
                Menu { SoundEffectChoices() } label: {
                    HStack { Label("音效", systemImage: "slider.horizontal.3"); Spacer(); Text(player.soundPreset.title).foregroundStyle(.secondary) }
                }.menuOrder(.fixed).accessibilityIdentifier("settings.sound").accessibilityValue(player.soundPreset.title)
            }
            Section("缓存") {
                LabeledContent("已用空间", value: cacheBytes.map { $0 == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…")
                Button("清理缓存") {
                    clearing = true
                    Task {
                        cacheBytes = await Task.detached {
                            GDClient.shared.clearCache()
                            return GDClient.shared.cacheSize()
                        }.value
                        clearing = false
                    }
                }.disabled(clearing).accessibilityIdentifier("settings.clearCache")
            }
            Section("听歌偏好") {
                Toggle("记录听歌偏好",isOn: $library.trackingEnabled)
                Button("重置听歌偏好",role: .destructive) { resetPrompt = true }
                    .accessibilityIdentifier("settings.reset")
            }
        }
        .scrollContentBackground(.hidden).background { Paper() }.navigationTitle("设置")
        .task {
            let size = await Task.detached { GDClient.shared.cacheSize() }.value
            if !clearing && cacheBytes == nil { cacheBytes = size }
        }
        .confirmationDialog("重置听歌偏好？",isPresented: $resetPrompt) {
            Button("重置偏好",role: .destructive) { library.resetPreferences() }
            Button("取消",role: .cancel) {}
        }
    }
}

private enum PlaylistEditAction: String, Identifiable { case cover, remove; var id:String { rawValue } }

private struct PlaylistEditingView: View {
    let id: UUID
    let action: PlaylistEditAction
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State private var selected: Set<String> = []
    @State private var confirm = false
    private var playlist: UserPlaylist? { library.playlists.first { $0.id == id } }
    var body: some View {
        NavigationStack {
            List {
                if action == .cover {
                    Button {
                        library.setCover(nil,for:id); dismiss()
                    } label: {
                        HStack { Label("自动跟随歌单首曲",systemImage:"square.stack"); Spacer(); if playlist?.cover == nil { Image(systemName:"checkmark") } }
                    }
                } else {
                    Button(selected.count == playlist?.tracks.count ? "取消全选" : "全选") {
                        selected = selected.count == playlist?.tracks.count ? [] : Set((playlist?.tracks ?? []).map(\.id))
                    }
                }
                ForEach(playlist?.tracks ?? []) { track in
                    Button {
                        if action == .cover {
                            library.setCover(track,for:id); dismiss()
                        } else if selected.contains(track.id) { selected.remove(track.id) } else { selected.insert(track.id) }
                    } label: {
                        HStack(spacing:12) {
                            ArtView(track:track).frame(width:40,height:40).clipShape(RoundedRectangle(cornerRadius:7))
                            VStack(alignment:.leading) {
                                Text(track.title).font(.body).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(Ink.quiet).lineLimit(1)
                            }
                            Spacer()
                            if action == .cover {
                                if playlist?.cover?.id == track.id { Image(systemName:"checkmark") }
                            } else { Image(systemName:selected.contains(track.id) ? "checkmark.circle.fill" : "circle") }
                        }
                    }.foregroundStyle(Ink.dark)
                }
            }.scrollContentBackground(.hidden).background { Paper() }
                .navigationTitle(action == .cover ? "选择歌单封面" : "选择要移除的歌曲").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } }
                    if action == .remove { ToolbarItem(placement:.confirmationAction) { Button("移除 (\(selected.count))",role:.destructive) { confirm = true }.disabled(selected.isEmpty) } }
                }
                .confirmationDialog("从本歌单移除 \(selected.count) 首歌曲？",isPresented:$confirm) {
                    Button("移除歌曲",role:.destructive) { library.remove(selected,from:id); dismiss() }
                } message: { Text("其他歌单和收藏仍会保留这些歌曲。") }
        }
    }
}
