import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var catalogs: SearchCatalogSettings
    var target: UUID? = nil
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var discovery: DiscoveryStore
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var loading = false
    @State private var loadMore = 0
    @State private var pages = SearchPages()
    @State private var activeRequest: SearchRequest?
    @State private var pendingAdds: [Track] = []
    @FocusState private var focused: Bool
    private var cleaned: String { query.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var initial: [Track] {
        let sources = catalogs.activeCatalogs
        let stored = library.favorites.isEmpty ? (library.recent.isEmpty ? Track.starterTracks : library.recent) : library.favorites
        return catalogs.selectedProvider != "all" ? stored.filter { t in sources.contains { $0.contains(t) } } : stored
    }
    private struct SearchRequest: Equatable { let text: String; let source: SearchCatalog }
    private struct SearchJob: Equatable { let request: SearchRequest; let batch: Int }
    private var searchRequest: SearchRequest { .init(text: cleaned, source: catalogs.selectedCatalog) }
    private var failed: Bool { pages.entries[searchRequest.source]?.error != nil }
    private var hasMore: Bool { pages.nextPage(for: searchRequest.source) != nil && !failed }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Image(systemName:"magnifyingglass")
                        TextField("歌曲、歌手、专辑",text:$query).accessibilityIdentifier("search.input").focused($focused)
                            .submitLabel(.search).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { focused = false }
                        if !cleaned.isEmpty { Button { query = ""; focused = true } label: { Image(systemName:"xmark.circle.fill") }.accessibilityLabel("清空搜索") }
                    }.padding(.horizontal,14).frame(height:46).glassPlate(23)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Picker("搜索范围", selection: Binding(get: { catalogs.selectedProvider }, set: { catalogs.selectProvider($0) })) {
                            ForEach(SearchCatalogSettings.scopes) { scope in Text(scope.title).tag(scope.id) }
                        }.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("search.scope")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !cleaned.isEmpty || !initial.isEmpty {
                        Text(cleaned.isEmpty ? (!library.favorites.isEmpty ? "你的收藏" : (library.recent.isEmpty ? "从这些歌开始" : "最近播放")) : "搜索结果").font(.headline)
                    }
                    if !cleaned.isEmpty, results.isEmpty, loading { ProgressView().frame(maxWidth:.infinity).padding(.vertical,20) }
                    else if !cleaned.isEmpty && results.isEmpty && !failed { EmptyHint(symbol:"magnifyingglass",title:"没有找到歌曲",detail:"换一个歌名或歌手试试。") }
                    else {
                        let items = cleaned.isEmpty ? initial : (activeRequest == searchRequest ? results : [])
                        LazyVStack(spacing:2) {
                            ForEach(items) { t in
                                if let target {
                                    let has = library.playlists.first(where: { $0.id == target })?.tracks.contains(where:{ $0.id == t.id }) == true
                                    let queued = pendingAdds.contains { $0.id == t.id }
                                    Button {
                                        if queued { pendingAdds.removeAll { $0.id == t.id } }
                                        else { pendingAdds.append(t) }
                                    } label: {
                                        HStack { ArtView(track:t).frame(width:42,height:42).clipShape(RoundedRectangle(cornerRadius:7))
                                            VStack(alignment:.leading,spacing:3) { Text(t.title).font(.body); Text(subtitle(for: t)).font(.caption).foregroundStyle(Ink.quiet) }; Spacer(); Image(systemName:has ? "checkmark" : (queued ? "checkmark.circle.fill" : "circle")) }
                                    }.buttonStyle(.plain).disabled(has).padding(.vertical,4)
                                } else {
                                    TrackRow(track:t,queue:items,subtitle:subtitle(for: t),afterPlay:{ dismiss() })

                                }
                            }
                        }
                    }
                    if !cleaned.isEmpty {
                        if failed {
                            Text("暂时无法搜索").font(.footnote).foregroundStyle(Ink.quiet)
                            Button("重新搜索") { loadMore += 1 }
                                .disabled(loading).accessibilityIdentifier("search.retrySources")
                        }
                        if loading && !results.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                        if !loading && !results.isEmpty && hasMore {
                            Button("加载更多") { loadMore += 1 }
                                .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("search.more")
                        }
                    }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively).background { Paper() }
                .navigationTitle(target == nil ? "搜索" : "添加歌曲").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let target {
                        ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                        ToolbarItem(placement:.confirmationAction) {
                            Button("添加 (\(pendingAdds.count))") { library.add(pendingAdds,to:target); dismiss() }.disabled(pendingAdds.isEmpty)
                        }
                    } else { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
                }
        }.presentationDragIndicator(.visible)
            .onAppear { if target == nil { focused = true } }
            .task(id: SearchJob(request: searchRequest, batch: loadMore)) {
                await catalogs.ensureConnected()
                guard !Task.isCancelled else { return }
                await search(input: searchRequest)
            }
            .onChange(of: discovery.hot.map(\.id)) { _,_ in
                if activeRequest == searchRequest { rankResults(for: searchRequest) }
            }
    }

    private func subtitle(for track: Track) -> String {
        let catalog = catalogs.activeCatalogs.first { $0.contains(track) }
        let label = track.managedCatalog == true ? track.catalogLabel : catalog?.name ?? track.catalogLabel
        let badge = cleaned.isEmpty ? nil : RecordingRanking.badge(track, query: cleaned, chart: discovery.hot, evidence: [:])
        return [track.artist, track.verifiedCatalogOriginal == true ? track.album : nil, badge, label]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func rankResults(for input: SearchRequest) {
        results = RecordingRanking.rank(pages.entries[input.source]?.tracks ?? [], query: input.text, chart: discovery.hot, evidence: [:])
    }

    @MainActor private func search(input: SearchRequest) async {
        let first = input != activeRequest
        if first {
            activeRequest = input
            pages = SearchPages(); results = []
        }
        loading = !input.text.isEmpty
        guard loading else { return }
        if first {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        }
        guard let page = pages.nextPage(for: input.source) else { loading = false; return }
        do {
            let hits = try await GDClient.shared.search(RecordingRanking.catalogQuery(input.text), catalog: input.source, page: page)
            guard !Task.isCancelled, activeRequest == input else { return }
            pages.accept(hits, from: input.source, page: page)
        } catch {
            guard !Task.isCancelled, activeRequest == input else { return }
            pages.fail(input.source, message: error.localizedDescription)
        }
        loading = false
        rankResults(for: input)
    }
}

private enum PlaySheet: Int, Identifiable { case queue, add, style, sound; var id:Int { rawValue } }
private enum PlayerPage: Int { case cover, lyrics }

struct PlayingView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var nav: NavigationModel
    @Environment(\.dismiss) var dismiss
    @State private var sheet: PlaySheet?
    @State private var page: PlayerPage = .cover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var lines: [LyricLine] = []
    @State private var loadingLyrics = false
    @State private var scrub: Double? = nil
    @State private var lyricRetry = 0
    @State private var browsingLyrics = false
    @State private var resumeFollow: Task<Void, Never>?
    private var current: Track? { player.track }
    private var lyricTrack: Track? { player.resolvedTrack ?? player.track }
    var body: some View {
        ZStack {
            ZStack {
                Color(red: 0.10, green: 0.19, blue: 0.21)
                ArtView(track: current, embedded: player.embeddedCover)
                    .scaleEffect(1.55).blur(radius: 48).saturation(0.72).opacity(0.68)
                LinearGradient(colors: [.black.opacity(0.16), .black.opacity(0.12),
                                        Color(red: 0.06, green: 0.13, blue: 0.16).opacity(0.86)],
                               startPoint: .top, endPoint: .bottom)
            }.ignoresSafeArea().accessibilityHidden(true)

            VStack(spacing: 0) {
                top
                TabView(selection: $page) {
                    coverPage.tag(PlayerPage.cover)
                    lyricsPage.tag(PlayerPage.lyrics)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 4) {
                    footer
                    console
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 26)
                .padding(.bottom, 5)
            }
        }.foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
            .sheet(item:$sheet) { destination in
                switch destination {
                case .queue: QueueView().preferredColorScheme(.light)
                case .sound: SoundEffectsView()
                case .add: if let current { AddToPlaylistView(track:current).preferredColorScheme(.light) }
                case .style: if let current { StyleFeedbackView(track:current).preferredColorScheme(.light) }
                }
            }
            .task(id: (lyricTrack?.id ?? "") + "#\(lyricRetry)") {
                lines = []
                loadingLyrics = lyricTrack != nil
                guard let real = lyricTrack else { return }
                let values = await GDClient.shared.lyrics(real)
                guard !Task.isCancelled else { return }
                lines = values
                loadingLyrics = false
            }
            .onChange(of: current?.id) { _,_ in scrub = nil; resetLyricBrowsing() }
            .onChange(of: page) { _,_ in resetLyricBrowsing() }
            .onDisappear { resumeFollow?.cancel() }

    }
    private func resetLyricBrowsing() {
        resumeFollow?.cancel()
        browsingLyrics = false
    }

    private func turnPage() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            page = page == .cover ? .lyrics : .cover
        }
    }

    private var coverPage: some View {
        GeometryReader { geo in
            let needsScroll = typeSize.isAccessibilitySize || geo.size.height < 280
            if needsScroll {
                ScrollView {
                    coverContent(sleeveHeight: min(geo.size.width * 0.70, 250))
                        .frame(minHeight: geo.size.height)
                }
            } else {
                coverContent(sleeveHeight: nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.coverPage")
    }

    private func coverContent(sleeveHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Sleeve(track: current, embedded: player.embeddedCover)
                .padding(.horizontal, 24)
                .frame(height: sleeveHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 10) {
                info
                if !lines.isEmpty {
                    Button(action: turnPage) {
                        Text(lines[max(0, activeLyric)].text)
                            .lineLimit(1).font(.subheadline).foregroundStyle(.white.opacity(0.74))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看完整歌词")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: 560, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var lyricsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(current?.title ?? "歌词").font(.title.weight(.semibold)).lineLimit(2)
                Text(current?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.74)).lineLimit(1)
            }
            .padding(.horizontal, 28)
            .padding(.top, 15)
            lyricView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: 560, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.lyricsPage")
    }
    private var top: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName:"chevron.down").frame(width:44,height:44).glassPlate(22) }.accessibilityLabel("收起播放器").accessibilityIdentifier("player.close")
            Spacer()
            Button(action: turnPage) {
                VStack(spacing: 6) {
                    Text(page == .cover ? "正在播放" : "同步歌词").font(.subheadline.weight(.semibold))
                    HStack(spacing: 5) {
                        ForEach([PlayerPage.cover, .lyrics], id: \.self) { item in
                            Capsule().fill(.white.opacity(page == item ? 0.94 : 0.35))
                                .frame(width: page == item ? 14 : 5, height: 4)
                        }
                    }
                }.frame(minWidth: 88, minHeight: 44)
            }.buttonStyle(.plain)
            .accessibilityLabel(page == .cover ? "唱片页，显示歌词" : "歌词页，显示唱片")
            Spacer()
            Menu {
                if let current {
                    Text("曲库 · " + current.catalogLabel)
                    Button("加入歌单",systemImage:"text.badge.plus") { sheet = .add }
                    Button("沿着这首听",systemImage:"dot.radiowaves.left.and.right") { dismiss(); nav.path.append(.related(current)) }
                    Button("少推荐这首",systemImage:"hand.thumbsdown") { library.dislike(current) }
                    Button("少推荐这种风格",systemImage:"slider.horizontal.3") { sheet = .style }
                }
                Menu("睡眠定时") {
                    ForEach([15,30,45,60],id:\.self) { minutes in Button("\(minutes) 分钟") { player.setSleep(minutes:minutes) } }
                    if player.sleepEnd != nil { Button("取消定时") { player.setSleep(minutes:nil) } }
                }
            } label: { Image(systemName:"ellipsis").frame(width:44,height:44).glassPlate(22) }.accessibilityLabel("更多播放选项")
        }.padding(.horizontal,18).padding(.top, 2)
    }
    private var info: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(current?.album.uppercased() ?? "SIDE A").font(.caption2.weight(.semibold)).tracking(1.9).foregroundStyle(.white.opacity(0.77)).lineLimit(1)
            HStack {
                Text(current?.title ?? "还没有正在播放的歌曲").font(Ink.title(36)).lineLimit(2).minimumScaleFactor(0.65)
                Spacer()
                if let current {
                    Button { library.toggleFavorite(current) } label: {
                        Image(systemName:library.isFavorite(current) ? "heart.fill" : "heart")
                            .foregroundStyle(library.isFavorite(current) ? Color(red:1,green:0.75,blue:0.69) : .white).frame(width:42,height:42).glassPlate(21)
                    }.accessibilityLabel(library.isFavorite(current) ? "取消收藏" : "收藏").accessibilityIdentifier("player.favorite")
                }
            }
            HStack(spacing:8) {
                Text(current?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.83)).lineLimit(1)
                if player.resolvedTrack != nil, player.errorMessage == nil {
                    Text(player.quality).font(.caption2.weight(.medium)).lineLimit(1)
                        .padding(.horizontal,7).padding(.vertical,3).background(.white.opacity(0.12),in:Capsule())
                        .accessibilityLabel("当前音质，" + player.quality)
                }
            }
            if player.errorMessage != nil {
                Button(action: retryPlay) { Label("重试播放", systemImage: "arrow.clockwise") }
                    .font(.caption).padding(.top,3)
            } else if player.isLoading { HStack(spacing:5) { ProgressView().controlSize(.small); Text("正在载入音频…").font(.caption) } }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func retryPlay() {
        guard !player.queue.isEmpty else { return }
        player.play(player.queue,at: min(max(0,player.currentIndex),player.queue.count-1))
    }
    private var console: some View {
        VStack(spacing:0) {
            progressBar
            HStack { Text(Self.time(scrub ?? player.elapsed)); Spacer(); Text("−" + Self.time(max(0,player.duration - (scrub ?? player.elapsed)))) }
                .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            HStack {
                modeButton(.shuffle, "shuffle"); Spacer()
                Button { player.previous() } label: { Image(systemName:"backward.end.fill").frame(width:44,height:45) }.accessibilityLabel("上一首")
                Spacer()
                Button { if player.errorMessage != nil { retryPlay() } else { player.toggle() } } label: {
                    Image(systemName:player.isPlaying ? "pause.fill" : "play.fill").font(.title2).foregroundStyle(Ink.forest).frame(width:54,height:54).background(Ink.cream,in:Circle())
                }.accessibilityLabel(player.isPlaying ? "暂停" : "播放").accessibilityIdentifier("player.toggle")
                Spacer()
                Button { player.next() } label: { Image(systemName:"forward.end.fill").frame(width:44,height:45) }.accessibilityLabel("下一首")
                Spacer(); modeButton(.repeatOne, "repeat.1")
            }.padding(.top, 8)
            if let end = player.sleepEnd { Text("睡眠定时 · \(end.formatted(date:.omitted,time:.shortened))").font(.caption2).padding(.top,6) }
        }
    }

    private var progressBar: some View {
        let duration = max(0, player.duration)
        let position = min(max(scrub ?? player.elapsed, 0), duration)
        let fraction = duration > 0 ? position / duration : 0
        return GeometryReader { geo in
            let inset: CGFloat = 5
            let width = max(1, geo.size.width - 2 * inset)
            let x = CGFloat(fraction) * width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24)).frame(height: 3).padding(.horizontal, inset)
                Capsule().fill(.white.opacity(0.94)).frame(width: x, height: 3).offset(x: inset)
                Circle().fill(.white).frame(width: scrub == nil ? 8 : 12, height: scrub == nil ? 8 : 12)
                    .position(x: inset + x, y: geo.size.height / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { touch in
                    guard duration > 0 else { return }
                    scrub = duration * Double(min(1, max(0, (touch.location.x - inset) / width)))
                }
                .onEnded { touch in
                    if duration > 0 { player.seek(duration * Double(min(1, max(0, (touch.location.x - inset) / width)))) }
                    scrub = nil
                })
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue(Self.time(position) + "，共" + Self.time(duration))
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else { return }
            player.seek(min(duration, max(0, position + (direction == .increment ? 5 : -5))))
        }
        .disabled(duration <= 0)
    }
    private func modeButton(_ mode: PlaybackMode,_ icon:String) -> some View {
        Button { player.mode = player.mode == mode ? .sequence : mode } label: {
            Image(systemName:icon).foregroundStyle(player.mode == mode ? Color(red:1, green:0.76, blue:0.6) : .white.opacity(0.7)).frame(width:44,height:44)
        }.accessibilityLabel(mode == .shuffle ? "随机播放" : "单曲循环")
        .accessibilityAddTraits(player.mode == mode ? .isSelected : [])
    }
    private var footer: some View {
        HStack {
            Button(action: turnPage) { Label(page == .lyrics ? "唱片" : "歌词", systemImage: page == .lyrics ? "opticaldisc" : "quote.bubble").frame(minHeight: 44) }.accessibilityIdentifier("player.lyrics")
            Spacer()
            Menu {
                Text("当前 · " + player.quality)
                Toggle("优先请求无损",isOn:$player.preferLossless)
                Toggle("仅播放无损",isOn:$player.losslessOnly)
                Toggle("移动网络省流",isOn:$player.cellularDataSaver).disabled(player.losslessOnly)
            } label: { Label("音质",systemImage:"waveform").frame(minHeight: 44) }
            Spacer()
            Button { sheet = .sound } label: { Label("音效", systemImage: "slider.horizontal.3").frame(minHeight: 44) }.accessibilityIdentifier("player.sound")
            Spacer(); Button { sheet = .queue } label: { Label("待播",systemImage:"list.bullet").frame(minHeight: 44) }.accessibilityIdentifier("player.queue")
        }.font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.82)).buttonStyle(.plain)
    }
    private var activeLyric: Int { lines.lastIndex(where:{ $0.time <= player.elapsed }) ?? -1 }
    @ViewBuilder private var lyricView: some View {
        if loadingLyrics && lines.isEmpty { ProgressView("读取歌词…") }
        else if lines.isEmpty {
            VStack(spacing:12) { Text("暂未找到歌词").font(.headline); Button("重新加载") { lyricRetry += 1 }.font(.caption) }
        } else {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Button { resetLyricBrowsing(); player.seek(line.time) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(line.text).font(.title2.weight(i == activeLyric ? .bold : .medium))
                                        if let translation = line.translation, !translation.isEmpty {
                                            Text(translation).font(.subheadline)
                                        }
                                    }
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.white.opacity(i == activeLyric ? 1 : 0.62))
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("player.lyricLine." + String(i))
                                .accessibilityAddTraits(i == activeLyric ? .isSelected : [])
                                .id(i)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                        .padding(.bottom, geo.size.height * 0.46)
                    }
                    .scrollIndicators(.hidden)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: .white, location: 0.045),
                        .init(color: .white, location: 0.90), .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting {
                            resumeFollow?.cancel()
                            browsingLyrics = true
                        } else if phase == .idle, browsingLyrics {
                            resumeFollow?.cancel()
                            resumeFollow = Task {
                                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                                browsingLyrics = false
                            }
                        }
                    }
                    .onChange(of: activeLyric, initial: true) { _, i in
                        if page == .lyrics && !browsingLyrics { followLyric(i, with: proxy) }
                    }
                    .onChange(of: browsingLyrics) { _, browsing in
                        if !browsing && page == .lyrics { followLyric(activeLyric, with: proxy) }
                    }
                    .onChange(of: page) { _, newPage in
                        if newPage == .lyrics { followLyric(activeLyric, with: proxy) }
                    }
                }
            }
        }
    }
    private func followLyric(_ index: Int, with proxy: ScrollViewProxy) {
        guard index >= 0 else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { proxy.scrollTo(index, anchor: .center) }
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let v = Int(max(0,min(seconds,1_000_000)))
        return String(format:"%d:%02d",v/60,v%60)
    }
}

struct QueueView: View {
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                if player.queue.isEmpty { EmptyHint(title:"待播为空",detail:"从搜索结果或歌单中加入一首歌。").listRowBackground(Color.clear) }
                ForEach(Array(player.queue.enumerated()),id:\.offset) { index,track in
                    Button { player.play(player.queue,at:index) } label: {
                        HStack(spacing:12) {
                            ArtView(track:track).frame(width:40,height:40).clipShape(RoundedRectangle(cornerRadius:7))
                            VStack(alignment:.leading,spacing:3) { Text(track.title).font(.body); Text(track.artist).font(.caption).foregroundStyle(Ink.quiet) }
                            Spacer(); if index == player.currentIndex { Image(systemName:"waveform").foregroundStyle(Ink.teal) }
                        }.foregroundStyle(Ink.dark)
                    }.listRowBackground(Color.clear)
                }.onDelete { player.removeQueue(at:$0) }.onMove { player.moveQueue(from:$0,to:$1) }
            }.scrollContentBackground(.hidden).background { Paper() }
            .navigationTitle("待播列表 · \(player.queue.count)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarLeading) { EditButton() }; ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
    }
}
