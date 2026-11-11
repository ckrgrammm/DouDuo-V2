import SwiftUI
import Combine
import AVFoundation

struct DYLiveStream: Hashable {
    let url: URL
    let quality: String
    let isFLV: Bool
    var cacheMS: Int32 { isFLV ? 800 : 1500 }
}

extension DYLiveRoom {
    /// 优先连续 HTTP-FLV，避免 HLS 播放列表/分片等待；同画质 HLS 保留为兜底。
    var liveStreams: [DYLiveStream] {
        let flv = flv ?? [:]
        let keys = ["HD1", def ?? "", "FULL_HD1", "SD1", "SD2"] + Array(Set(hls.keys).union(flv.keys)).sorted()
        var seen = Set<URL>()
        var result: [DYLiveStream] = []
        #if DEBUG
        let hlsOnly = ProcessInfo.processInfo.environment["DOUDUO_LIVE_HLS"] == "1"
        #else
        let hlsOnly = false
        #endif
        for key in keys where !key.isEmpty {
            for isFLV in [true, false] where !(hlsOnly && isFLV) {
                guard let value = (isFLV ? flv : hls)[key], let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { continue }
                result.append(DYLiveStream(url: url, quality: key, isFLV: isFLV))
            }
        }
        return result
    }
}

@MainActor
final class DYLiveModel: ObservableObject {
    @Published var rooms: [DYLiveRoom] = []
    @Published var currentID: String?
    @Published var error: String?
    @Published var playbackError: String?
    @Published var loading = false
    private(set) var fetchedAt = Date.distantPast
    @Published var ready = false
    @Published var zone: DYLiveZone?
    /// 关注的主播里正在开播的（网页版直播首页顶上那排头像，复用同一个接口）
    @Published var followLive: [DYLiveRoom] = []
    private var followLiveFetchedAt = Date.distantPast
    private var followedOnly = false
    @Published var clean = false
    @Published var entered = false
    /// 「发现更多」面板展开（在挑直播间）：不播任何直播，免得后台挂着一个还在出声
    var browsing = false
    /// 手动选的清晰度（nil = 自动，用抖音给的默认）；全局记住，换直播间也沿用
    @Published var quality: String? = UserDefaults.standard.string(forKey: "douyin_live_quality_v1")
    /// 这个直播间有的清晰度，高到低
    var qualityOptions: [String] {
        let have = Set((roomRef?.liveStreams ?? []).map(\.quality))
        return ["ORIGION", "FULL_HD1", "HD1", "SD1", "SD2"].filter(have.contains)
    }
    static func qualityName(_ q: String) -> String {
        ["ORIGION": "原画", "FULL_HD1": "蓝光", "HD1": "超清", "SD1": "高清", "SD2": "标清"][q] ?? q
    }
    func setQuality(_ q: String?) {
        quality = q
        UserDefaults.standard.set(q, forKey: "douyin_live_quality_v1")
        retry()
    }
    @Published var muted = false { didSet { vlc.mediaPlayer.audio?.isMuted = muted } }
    let vlc = VLCPlayerController()
    private var requestGeneration = UUID()
    private var loadedRoom: String?
    private var roomRef: DYLiveRoom?
    private var sources: [DYLiveStream] = []
    private var retryTask: Task<Void, Never>?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var streamGeneration = UUID()
    private let lifecycleID = UUID()
    private var visible = false

    func activate() {
        visible = true
        DDPlayback.shared.register(lifecycleID, stop: { [weak self] in self?.stop() }, start: { [weak self] in
            guard let self, self.visible else { return }
            self.play(self.roomRef)
        })
        play(roomRef)
    }
    func deactivate() {
        visible = false
        DDPlayback.shared.unregister(lifecycleID)
        stop()
    }

    nonisolated static func log(_ s: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("ddlog.txt")
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        let line = df.string(from: Date()) + " " + s + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    init() {
        vlc.onProgress = { [weak self] time in
            guard let self, !self.ready, self.loadedRoom != nil, time > 0,
                  self.vlc.mediaPlayer.hasVideoOut else { return }
            self.ready = true
            self.retryTask?.cancel()
            Self.log("DDLIVE_READY room=\(self.loadedRoom ?? "-") elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - self.startedAt)) videoOut=true")
        }
        vlc.onError = { [weak self] in self?.tryNextSource(reason: "decoder/network error") }
        vlc.onEnd = { [weak self] in self?.playbackError = "直播已结束或连接中断，可重试或上滑换台" }
    }

    func load(_ bridge: DouyinBridge, reset: Bool = false) async {
        guard !loading, !followedOnly else { return }
        let generation = requestGeneration, requestedZone = zone
        let start = ProcessInfo.processInfo.systemUptime
        loading = true
        defer { if requestGeneration == generation { loading = false } }
        do {
            let r = try await bridge.fetchLive(reset: reset, zone: requestedZone)
            guard requestGeneration == generation, zone == requestedZone else { return }
            if reset { rooms = [] }
            var seen = Set(rooms.map(\.id))
            rooms.append(contentsOf: r.filter { seen.insert($0.id).inserted })
            if !rooms.contains(where: { $0.id == currentID }) { currentID = rooms.first?.id }
            fetchedAt = Date()
            error = rooms.isEmpty ? (zone == nil ? "暂时没有直播" : "这个分类暂时没有直播") : nil
            DDPerf.mark("live.list")
            Self.log("DDLIVE_FEED count=\(r.count) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
        } catch {
            guard requestGeneration == generation else { return }
            if rooms.isEmpty { self.error = error.localizedDescription }
        }
    }

    func play(_ room: DYLiveRoom?) {
        guard let room else { return }
        if loadedRoom == room.id, vlc.mediaPlayer.media != nil { return }
        roomRef = room
        guard !browsing, visible, DDPlayback.shared.appIsActive else { return }
        loadedRoom = room.id
        sources = room.liveStreams
        // 选了清晰度就把它排最前，起不来才退回其他档
        if let q = quality, sources.contains(where: { $0.quality == q }) {
            sources = sources.filter { $0.quality == q } + sources.filter { $0.quality != q }
        }
        startCurrentSource()
    }

    private func startCurrentSource() {
        retryTask?.cancel()
        streamGeneration = UUID()
        let generation = streamGeneration
        ready = false; playbackError = nil
        vlc.stop()
        guard let source = sources.first else {
            playbackError = "没有可用直播线路，请重试或换一个直播间"; return
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        vlc.play(url: source.url, headers: DYMedia.liveHeaders, cachingMs: source.cacheMS)
        vlc.mediaPlayer.audio?.isMuted = muted
        Self.log("DDLIVEPLAY room=\(loadedRoom ?? "-") protocol=\(source.isFLV ? "FLV" : "HLS") q=\(source.quality) cache=\(source.cacheMS) drawable=\(vlc.mediaPlayer.drawable != nil)")
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(source.isFLV ? 6 : 10)) } catch { return }
            guard let self, self.streamGeneration == generation, !self.ready else { return }
            self.tryNextSource(reason: "startup timeout")
        }
    }

    private func tryNextSource(reason: String) {
        guard loadedRoom != nil else { return }
        retryTask?.cancel()
        Self.log("DDLIVE_FALLBACK reason=\(reason) remaining=\(sources.count)")
        if !sources.isEmpty { sources.removeFirst() }
        guard !sources.isEmpty else {
            playbackError = "直播连接失败，请重试或上滑换台"; vlc.stop(); return
        }
        startCurrentSource()
    }

    func retry() {
        guard let room = roomRef else { return }
        loadedRoom = nil; play(room)
    }
    func enterRoom() {
        entered = true; clean = false
        Self.log("DDLIVE_ENTER room=\(currentID ?? "-") reused=true")
    }
    func leaveRoom() {
        entered = false; clean = false
        Self.log("DDLIVE_LEAVE room=\(currentID ?? "-") reused=true")
    }
    func stop() {
        retryTask?.cancel(); streamGeneration = UUID()
        loadedRoom = nil; vlc.stop(); ready = false
    }
    func reset() {
        followedOnly = false
        requestGeneration = UUID(); loading = false
        stop(); rooms = []; currentID = nil; error = nil; playbackError = nil
        entered = false; clean = false
    }
    func select(_ z: DYLiveZone?, _ bridge: DouyinBridge) {
        guard z != zone || rooms.isEmpty else { return }
        zone = z; reset()
        Task { await load(bridge, reset: true) }
    }
    func open(_ room: DYLiveRoom) {
        zone = nil; reset(); rooms = [room]; currentID = room.id; entered = true; fetchedAt = Date()
    }

    /// 「发现更多」里的关注主播：2 分钟节流；未登录或被风控时静默降级为空列表
    func loadFollowLive(_ bridge: DouyinBridge) async {
        guard Date().timeIntervalSince(followLiveFetchedAt) > 120 else { return }
        followLiveFetchedAt = Date()
        if let r = try? await bridge.fetchFollowLive() { followLive = r }
    }

    /// 一级分类「关注」：把整条流换成关注主播的开播列表，仍可上下滑换台
    func openFollowed(_ bridge: DouyinBridge) {
        guard !followLive.isEmpty else { return }
        zone = nil; reset()
        rooms = followLive; currentID = followLive.first?.id
        followedOnly = true // 关注列表到末尾不能混入推荐直播。
        fetchedAt = Date()
        Self.log("DDLIVE_FOLLOWED count=\(followLive.count)")
    }

    /// 一级分类「精选」：不论之前是关注列表还是游戏专区，都回到推荐直播流
    func backToFeatured(_ bridge: DouyinBridge) {
        zone = nil; reset()
        Task { await load(bridge, reset: true) }
    }
}

/// 仅展示已核验真实来源的分类；游戏仍可进一步选择具体专区。
private enum DYLiveCategoryKind {
    case featured, followed, gameZones
    case partition(DYLiveZone)
}
private struct DYLiveCategory: Identifiable {
    let id: String, name: String
    let kind: DYLiveCategoryKind
}
private let ddLiveCategories: [DYLiveCategory] = [
    .init(id: "featured", name: "精选", kind: .featured),
    .init(id: "followed", name: "关注", kind: .followed),
    .init(id: "game", name: "游戏", kind: .gameZones),
    .init(id: "chat", name: "聊天", kind: .partition(.init(id: "101", type: "4", name: "聊天"))),
    .init(id: "music", name: "音乐", kind: .partition(.init(id: "102", type: "4", name: "音乐"))),
    .init(id: "anime", name: "二次元", kind: .partition(.init(id: "104", type: "4", name: "二次元"))),
    .init(id: "dance", name: "舞蹈", kind: .partition(.init(id: "105", type: "4", name: "舞蹈"))),
    .init(id: "culture", name: "文化", kind: .partition(.init(id: "106", type: "4", name: "文化"))),
    .init(id: "life", name: "生活", kind: .partition(.init(id: "107", type: "4", name: "生活"))),
    .init(id: "exercise", name: "运动", kind: .partition(.init(id: "108", type: "4", name: "运动"))),
]

/// 预览和直播间共用同一个 drawable / VLC，不用网页开第二套播放器。
struct DYLiveFeed: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let bridge: DouyinBridge
    @ObservedObject var model: DYLiveModel
    let onWeb: (URL) -> Void
    var active = true
    @StateObject private var chat = DYLiveChat()
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var showCategories = false
    /// 「发现更多」：关注主播开播头像 + 一级分类，收起时不占画面（抖音广场页同款信息层）
    @State private var showDiscover = false
    /// 顶部「关注主播正在直播」：进直播页展开，上滑换直播间收成胶囊，点胶囊再展开。
    @State private var stripExpanded = true
    @State private var selectedCategory = "featured"
    @State private var categoryHint: String?
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var gestureStartID: String?
    @State private var scrollEndTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    @State private var tick = 0
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }
    private var currentRoom: DYLiveRoom? { model.rooms.first { $0.id == model.currentID } }
    private var chatRoom: String? { model.entered && model.ready && danmakuOn ? currentRoom?.webRid : nil }
    /// 顶部头像排的数据源；真机取 model.followLive，模拟器可用合成数据验布局。
    private var stripRooms: [DYLiveRoom] {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["DOUDUO_LIVE_FOLLOW_FIXTURE"] == "1" { return Self.fixtureRooms }
        #endif
        return model.followLive
    }
    #if DEBUG && targetEnvironment(simulator)
    /// 仅模拟器布局测试：合成 8 个直播间，不连网、不进房。
    private static let fixtureRooms: [DYLiveRoom] = (0..<8).map { i in
        DYLiveRoom(id: "fixture-\(i)", webRid: "0", title: "", owner: "合成主播\(i + 1)",
                   avatar: nil, cover: nil, viewers: "0", hls: [:], portrait: true)
    }
    #endif

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VLCPlayerSurface(controller: model.vlc, fillWidth: currentRoom?.portrait == true && geo.size.height > geo.size.width * 1.2)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                if model.rooms.isEmpty { emptyState }
                else { pages }
                if !model.entered {
                    VStack(alignment: .leading, spacing: 0) {
                        discoverBar
                        if !stripRooms.isEmpty {
                            DYFollowLiveStrip(rooms: stripRooms, expanded: stripExpanded,
                                              onOpen: { model.open($0) },
                                              onExpand: { stripExpanded = true })
                                .padding(.top, 10)
                                .animation(.easeOut(duration: 0.22), value: stripExpanded)
                        }
                        if showDiscover {
                            discoverPanel.transition(.opacity.combined(with: .move(edge: .top)))
                                .background(Color.black.ignoresSafeArea())
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 18)
                    .padding(.top, hSize == .compact ? 46 : 74)
                    .animation(.easeInOut(duration: 0.2), value: showDiscover)
                }
                #if DEBUG
                VStack {
                    Text(model.currentID ?? "-").accessibilityIdentifier("live.currentID")
                    Text(String(format: "%.1f", model.vlc.current)).accessibilityIdentifier("live.time")
                    Text(model.ready ? "1" : "0").accessibilityIdentifier("live.status")
                    Text("\(model.zone?.id ?? "featured")|\(model.rooms.count)|\(model.loading ? "loading" : "loaded")")
                        .accessibilityIdentifier("live.source")
                }.font(.caption2).opacity(0.01).allowsHitTesting(false)
                #endif
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        // 分页与 drawable 使用同一整屏视口，不能只让 ScrollView 越过底部安全区。
        .ignoresSafeArea(.container, edges: .bottom)
        .background(DYLiveChatHost(chat: chat).frame(width: 1, height: 1).allowsHitTesting(false))
        .onAppear { if active { model.activate() } }
        .onChange(of: active) { _, value in
            if value { stripExpanded = true; model.activate() } else { model.deactivate() }
        }
        .task {
            // Render and start the preloaded room immediately; refresh stale listings behind it.
            scrollID = model.currentID
            model.play(currentRoom)
            async let followed: Void = model.loadFollowLive(bridge)
            if model.rooms.isEmpty || Date().timeIntervalSince(model.fetchedAt) > 60 {
                await model.load(bridge, reset: true)
                scrollID = model.currentID
                model.play(currentRoom)
            }
            _ = await followed
        }
        .onChange(of: model.currentID) { old, id in
            if DYFollowLiveStripPolicy.shouldCollapse(old: old, new: id, expanded: stripExpanded) {
                withAnimation(.easeOut(duration: 0.2)) { stripExpanded = false }
            }
            if let id, scrollID != id { scrollID = id }
            draft = ""; sendError = nil; inputFocused = false
            model.play(currentRoom)
            if let id, let i = model.rooms.firstIndex(where: { $0.id == id }), i >= model.rooms.count - 3 {
                Task { await model.load(bridge) }
            }
        }
        .task(id: chatRoom) {
            chat.close()
            guard let id = chatRoom else { return }
            // 首帧后再接评论网页，避免它的 JS/资源请求抢首播带宽和主线程。
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled, id == chatRoom else { return }
            chat.open(id)
        }
        .onChange(of: model.entered) { _, entered in
            if entered { showDiscover = false }
            else { inputFocused = false; draft = ""; sendError = nil }
        }
        .onChange(of: showDiscover) { _, expanded in
            model.browsing = expanded
            if expanded { model.stop(); Task { await model.loadFollowLive(bridge) } }
            else { model.play(currentRoom) }
        }
        .onDisappear { scrollEndTask?.cancel(); model.deactivate(); chat.close() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
        .sheet(isPresented: $showCategories) {
            DYLiveCategories(selection: model.zone) { z in
                showCategories = false
                if let z {
                    model.select(z, bridge)
                    selectedCategory = "game"
                    categoryHint = "已切到「\(z.name)」专区"
                } else {
                    model.backToFeatured(bridge)
                    selectedCategory = "featured"; categoryHint = nil
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// 顶部第一行：抖音广场页的「发现更多」展开入口 + 原有分类入口
    private var discoverBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDiscover.toggle() }
            } label: {
                Label(showDiscover ? "收起" : "发现更多",
                      systemImage: showDiscover ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).frame(height: 40).ddGlassCapsule()
            }
            .foregroundStyle(foreground).buttonStyle(.plain)
            .accessibilityIdentifier("live.discover")
            // 靠左避开 Duo 内屏的系统状态栏 / 前摄区。
            Spacer(minLength: 8)
        }
    }

    private var discoverPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                followedLiveRow
                categoryStrip
                if let categoryHint {
                    Text(categoryHint).font(.caption)
                        .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                }
                roomGrid
            }
            .padding(.top, 14).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    /// 当前分类的直播间列表（同网页版「更多直播」）：点哪个就看哪个，不用一个个上滑找
    private var roomGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.rooms.isEmpty ? (model.loading ? "加载中…" : "暂时没有直播") : "选一个直播间")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(model.rooms) { r in
                    Button {
                        model.currentID = r.id
                        withAnimation(.easeInOut(duration: 0.2)) { showDiscover = false }
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            CachedAsyncImage(url: r.cover.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                                placeholder: { theme.media.chromeFill.color(for: scheme) }
                                .frame(maxWidth: .infinity).aspectRatio(4 / 3, contentMode: .fit).clipped()
                            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title.isEmpty ? r.owner : r.title).font(.caption.weight(.semibold)).lineLimit(2)
                                HStack {
                                    Text(r.owner).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(r.viewers)
                                }.font(.caption2).opacity(0.85)
                            }
                            .foregroundStyle(.white).padding(8)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(foreground.opacity(r.id == model.currentID ? 0.9 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .onAppear { if r.id == model.rooms.last?.id { Task { await model.load(bridge) } } }   // 滑到底接着加载
                }
            }
        }
        .foregroundStyle(foreground)
    }

    /// 关注的主播里正在开播的：红色直播环 + 头像横排，点一下直接进房
    private var followedLiveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(theme.status.danger.color(for: scheme)).frame(width: 6, height: 6)
                Text("关注的人正在直播").font(.subheadline.weight(.semibold))
                Text(model.followLive.isEmpty ? "登录后可查看" : "\(model.followLive.count) 位")
                    .font(.caption)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
            }
            if !model.followLive.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(model.followLive) { r in
                            Button { model.open(r) } label: {
                                VStack(spacing: 5) {
                                    CachedAsyncImage(url: r.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                                        placeholder: { theme.media.chromeFill.color(for: scheme) }
                                        .frame(width: 52, height: 52).clipShape(Circle())
                                        .overlay(Circle().stroke(theme.status.danger.color(for: scheme), lineWidth: 2))
                                        .overlay(alignment: .bottom) {
                                            Text("直播中").font(.caption2.weight(.bold))
                                                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                                                .offset(y: 6)
                                        }
                                    Text(r.owner).font(.caption2).lineLimit(1).frame(width: 66)
                                }
                                .padding(.top, 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("live.followed.\(r.id)")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(foreground)
    }

    /// 一级分类条：只显示有真实列表接口的入口，横向滚动容纳窄屏。
    private var categoryStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("全部分类").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ddLiveCategories) { c in
                        Button { pickCategory(c) } label: {
                            Text(c.name)
                                .font(.subheadline.weight(selectedCategory == c.id ? .semibold : .regular))
                                .foregroundStyle(foreground)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(Capsule().fill(selectedCategory == c.id
                                    ? foreground.opacity(0.22)
                                    : theme.media.chromeFill.color(for: scheme)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live.category.\(c.id)")
                        .accessibilityValue(selectedCategory == c.id ? "已选择" : "未选择")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("live.categoryStrip")
        }
        .foregroundStyle(foreground)
    }

    private func pickCategory(_ c: DYLiveCategory) {
        switch c.kind {
        case .featured:
            selectedCategory = c.id; categoryHint = nil
            model.backToFeatured(bridge)
        case .followed:
            guard !model.followLive.isEmpty else {
                categoryHint = "还没看到关注的主播开播，可到「网页版 / 登录」里登录抖音"; return
            }
            selectedCategory = c.id; categoryHint = nil
            model.openFollowed(bridge)
        case .gameZones:
            selectedCategory = c.id
            model.select(DYLiveZone(id: "103", type: "4", name: "游戏"), bridge)
            categoryHint = "「游戏」下可选具体专区"
            showCategories = true
        case .partition(let zone):
            selectedCategory = c.id; categoryHint = nil
            model.select(zone, bridge)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if let error = model.error {
                Text(error).font(.footnote)
                Button("重试") { Task { await model.load(bridge, reset: true) } }
                Button("网页版 / 登录") { onWeb(URL(string: "https://live.douyin.com/")!) }
            } else {
                ProgressView().tint(foreground)
                Text("连接直播…").font(.footnote)
            }
        }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pages: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.rooms) { room in
                    DYLiveRoomPage(room: room, model: model, isCurrent: model.currentID == room.id,
                                   messages: model.currentID == room.id ? chat.messages : [],
                                   input: AnyView(commentInput), onWeb: onWeb)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .contentShape(Rectangle())
                        .accessibilityHidden(model.currentID != room.id)
                        .id(room.id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(.container, edges: .bottom)
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if !userScrolling {
                    gestureStartID = model.currentID
                    #if DEBUG
                    DYLiveModel.log("DDLIVE_SCROLL start=\(model.currentID ?? "-") count=\(model.rooms.count)")
                    #endif
                }
                scrollEndTask?.cancel(); userScrolling = true
            }
            .onEnded { value in
                // 左缘右滑返回：与「我的 / 信息」页 DYEdgeSwipeBack 同一套判定（左缘 30pt 起、右滑 >70pt）。
                // 刻意复用分页这一个手势，不再叠第二层 simultaneousGesture，避免影响上滑换台。
                if (model.entered || model.clean),
                   value.startLocation.x < 30, value.translation.width > 70,
                   abs(value.translation.height) < abs(value.translation.width) {
                    if model.clean { model.clean = false } else { model.leaveRoom() }
                    scrollEndTask?.cancel(); userScrolling = false; gestureStartID = nil
                    return
                }
                if abs(value.translation.width) > 80 && abs(value.translation.width) > abs(value.translation.height) && model.entered {
                    withAnimation(.easeInOut(duration: 0.2)) { model.clean = value.translation.width > 0 }
                }
                scrollEndTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    userScrolling = false; gestureStartID = nil
                }
            })
        .onChange(of: scrollID) { _, id in
            guard let id, id != model.currentID else { return }
            // 仅接受真实竖滑引起的相邻页变化，布局/追加列表不得偷偷切台。
            let start = gestureStartID ?? model.currentID
            if userScrolling, let a = model.rooms.firstIndex(where: { $0.id == id }),
               let b = model.rooms.firstIndex(where: { $0.id == start }), abs(a - b) <= 1 {
                model.currentID = id
            } else { scrollID = model.currentID }
        }
    }

    private var commentInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sendError { Text(sendError).font(.caption).foregroundStyle(theme.status.warning.color(for: scheme)) }
            HStack(spacing: 8) {
                TextField(chat.composerReady ? "说点什么…" : "评论区连接中…", text: $draft)
                    .font(.subheadline).foregroundStyle(foreground).focused($inputFocused)
                    .submitLabel(.send).onSubmit(sendComment)
                    .padding(.horizontal, 14).frame(height: 40).ddGlassCapsule()
                    .accessibilityIdentifier("live.chat.input")
                if !draft.isEmpty {
                    Button(action: sendComment) {
                        if sending { ProgressView() } else { Text(chat.composerReady ? "发送" : "连接中").font(.subheadline.weight(.semibold)) }
                    }.disabled(sending || !chat.composerReady).accessibilityIdentifier("live.chat.send")
                }
            }
        }
    }

    private func sendComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard chatRoom != nil, chat.composerReady else { sendError = "评论区连接中，稍后再试"; return }
        sending = true
        let target = chatRoom, submittedDraft = draft
        Task {
            let error = await chat.send(text)
            guard chatRoom == target else { sending = false; return }
            if let error { sendError = error }
            else if draft == submittedDraft { draft = ""; sendError = nil; inputFocused = false }
            sending = false
        }
    }
}

private struct DYLiveRoomPage: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let room: DYLiveRoom
    @ObservedObject var model: DYLiveModel
    let isCurrent: Bool
    let messages: [DYLiveMsg]
    let input: AnyView
    let onWeb: (URL) -> Void
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if !isCurrent || !model.ready, let cover = room.cover, let url = URL(string: cover) {
                    CachedAsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: room.portrait ? .fill : .fit) }
                        placeholder: { Color.clear }
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                if isCurrent && !model.entered {
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.enterRoom() }
                }
                if isCurrent, !model.ready || model.playbackError != nil {
                    VStack(spacing: 10) {
                        if let error = model.playbackError {
                            Text(error).font(.footnote).multilineTextAlignment(.center)
                            Button("重试", action: model.retry).buttonStyle(.bordered)
                        } else {
                            ProgressView().tint(foreground)
                            Text("连接直播…").font(.caption)
                        }
                    }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !isCurrent {
                    Color.clear.allowsHitTesting(false)
                } else if model.clean {
                    // 与进房态同一套「返回」胶囊，放左上避开右上系统状态栏 / 前摄挖孔
                    VStack { HStack { backCapsule(action: { model.clean = false }, id: "live.room.restore"); Spacer() }; Spacer() }
                        .contentShape(Rectangle())
                        .onTapGesture { model.clean = false }
                        .padding(.leading, 18).padding(.trailing, hSize == .compact ? 82 : 18).padding(.top, hSize == .compact ? 64 : 70)
                } else if model.entered {
                    VStack {
                        header
                        Spacer(minLength: 12)
                        VStack(alignment: .leading, spacing: 12) {
                            if !messages.isEmpty { DYLiveChatOverlay(messages: messages) }
                            HStack(spacing: 12) {
                                input
                                Menu {
                                    Button("清屏", systemImage: "rectangle") { model.clean = true }
                                    Toggle("静音", systemImage: "speaker.slash", isOn: $model.muted)
                                    Menu("清晰度", systemImage: "sparkles.tv") {
                                        Picker("清晰度", selection: Binding(get: { model.quality ?? "" },
                                                                         set: { model.setQuality($0.isEmpty ? nil : $0) })) {
                                            Text("自动").tag("")
                                            ForEach(model.qualityOptions, id: \.self) { Text(DYLiveModel.qualityName($0)).tag($0) }
                                        }
                                    }
                                    Button("重新连接", systemImage: "arrow.clockwise", action: model.retry)
                                    Button("官网互动（礼物）", systemImage: "safari") { onWeb(room.webURL) }
                                } label: { Image(systemName: "ellipsis").font(.title2).frame(width: 44, height: 44).ddGlassCircle() }
                                .accessibilityIdentifier("live.room.more")
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, hSize == .compact ? 82 : 18)
                    .padding(.top, hSize == .compact ? 64 : 70)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 12)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Spacer()
                        HStack(spacing: 10) {
                            avatar
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.owner).font(.headline).lineLimit(1)
                                Text("直播中 · \(room.viewers) 在看").font(.caption)
                            }
                        }
                        Text(room.title).font(.subheadline).lineLimit(2)
                        Button(action: model.enterRoom) {
                            Text("进入直播间").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 22).frame(height: 44).ddGlassCapsule()
                        }.buttonStyle(.plain).accessibilityIdentifier("live.room.enter")
                        Text("上滑切换直播间").font(.caption).foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 24)
                }
            }
            .foregroundStyle(foreground)
        }
        #if DEBUG
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.page.\(room.id)")
        #endif
    }

    private var avatar: some View {
        CachedAsyncImage(url: room.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
            placeholder: { theme.media.chromeFill.color(for: scheme) }
            .frame(width: 36, height: 36).clipShape(Circle())
    }
    private var header: some View {
        // 直播间唯一的返回键：与「我的 / 信息 / 网页版」页同款标题 + chevron.backward 符号。
        // 放左上角，右上角留给系统状态栏/前摄挖孔（展开内屏会被系统层盖住）。
        // 主视图不再挂 NavigationStack / toolbar，Duo 系统侧栏不会再多渲染一颗返回。
        HStack(spacing: 10) {
            backCapsule(action: model.leaveRoom, id: "live.room.close")
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.owner).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(room.viewers) 在看").font(.caption2)
                }
            }.padding(.trailing, 12).padding(.leading, 4).padding(.vertical, 4).ddGlassCapsule()
            Spacer(minLength: 8)
        }
    }
    /// 和 douyin.web.back / douyin.mine.back / douyin.messages.back 同一套返回键语义：
    /// 「返回」标题 + chevron.backward 符号 + 胶囊底。直播间只保留这一颗，不再叠加系统侧栏返回。
    private func backCapsule(action: @escaping () -> Void, id: String) -> some View {
        Button(action: action) {
            Label("返回", systemImage: "chevron.backward")
                .font(.system(size: theme.typography.pointSize(.headline), weight: .semibold))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(theme.media.chromeFill.color(for: scheme)))
        }
        .buttonStyle(.plain)
        .themeShadow(.floatingPanel)
        .accessibilityIdentifier(id)
    }
}

private struct DYLiveCategories: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let selection: DYLiveZone?
    let onSelect: (DYLiveZone?) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 14) {
                    ForEach([nil] + DYLiveZone.all.map(Optional.some), id: \.self) { zone in
                        Button { onSelect(zone) } label: {
                            HStack {
                                Text(zone?.name ?? "推荐直播").font(.subheadline)
                                if selection == zone { Image(systemName: "checkmark").font(.caption) }
                            }
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .foregroundStyle(theme.media.onMedia.color(for: scheme))
                            .ddGlassCapsule()
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }
            .navigationTitle("直播分类").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("live.categories.close")
                }
            }
        }
    }
}
