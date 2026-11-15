import Foundation
import CoreGraphics

/// 关注直播接口的匿名统计。不含房间、流地址或用户标识。
struct DYFollowLiveStats: Equatable, Decodable {
    var http: Int
    var code: Int?
    var hasList: Bool
    var list: Int
    var kept: Int
    var dropped: Int
    var parsed: Bool
}

enum DYFollowLiveKind: String, Equatable {
    case rooms
    case notLoggedIn
    case nobodyLive
    case filtered
    case unexpectedShape
    case requestFailed
    case decodeFailed
}

enum DYFollowLiveClassify {
    /// 空的 `items` 只有在接口明确给出空列表时才是「没人直播」。
    static func kind(status: Int, itemCount: Int, stats: DYFollowLiveStats?) -> DYFollowLiveKind {
        guard let stats else {
            if status == 200 && itemCount > 0 { return .rooms }
            if status == 200 { return .unexpectedShape }
            return .requestFailed
        }
        if stats.code == 8 { return .notLoggedIn }
        if !stats.parsed || stats.http != 200 { return .requestFailed }
        if let code = stats.code, code != 0 { return .requestFailed }
        if status != 200 { return .requestFailed }
        if itemCount > 0 { return .rooms }
        if stats.list > 0 && stats.kept == 0 { return .filtered }
        if stats.hasList && stats.list == 0 { return .nobodyLive }
        return .unexpectedShape
    }
}

/// 推荐直播与「从关注列表点进的单一直播间」之间的切换。不保存房间正文。
struct DYLiveVisit: Equatable {
    private(set) var roomIDs: [String] = []
    private(set) var currentID: String?
    private(set) var zoneID: String?
    private(set) var followed = false
    private var savedIDs: [String] = []
    private var savedID: String?
    private var savedZoneID: String?

    var acceptsRecommendation: Bool { !followed }

    mutating func replaceFeed(ids: [String], currentID: String?, zoneID: String?) {
        guard !followed else { return }
        roomIDs = ids
        self.currentID = currentID
        self.zoneID = zoneID
    }

    mutating func open(_ id: String) {
        if !followed {
            savedIDs = roomIDs
            savedID = currentID
            savedZoneID = zoneID
        }
        followed = true
        roomIDs = [id]
        currentID = id
    }

    @discardableResult
    mutating func leave() -> Bool {
        guard followed else { return false }
        roomIDs = savedIDs
        currentID = savedID
        zoneID = savedZoneID
        followed = false
        savedIDs = []
        savedID = nil
        savedZoneID = nil
        return true
    }

    mutating func clear() { self = DYLiveVisit() }
}

/// 关注列表只负责展示。播放地址单独解析，而且不放进缓存。
enum DYFollowLiveScripts {
    static let list = #"""
    const W = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', cookie_enabled: 'true',
      screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel', browser_name: 'Safari',
      browser_version: '26.0', channel: 'channel_pc_web' };
    const r = await req('GET', 'https://live.douyin.com/webcast/web/feed/follow/?' + new URLSearchParams(Object.assign({}, W,
      { enter_from: 'web_homepage_follow', scene: 'aweme_pc_follow_top' })).toString());
    const d = parse(r.t);
    const stats = (extra) => Object.assign({ http: r.s, code: d && Number.isFinite(Number(d.status_code)) ? Number(d.status_code) : null, hasList: !!(d && (Array.isArray(d.data) || (d.data && Array.isArray(d.data.data)))), list: 0, kept: 0, dropped: 0, parsed: !!d }, extra || {});
    if (!d) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [], stats: stats() });
    if (d.status_code) return JSON.stringify({ status: 401, items: [], stats: stats() });
    const arr = Array.isArray(d.data) ? d.data : ((d.data && d.data.data) || []);
    const toRoom = (room, roomRid) => {
      const su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id || ''), webRid: String(roomRid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || '',
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    };
    const out = [];
    let dropped = 0;
    for (const e of arr.slice(0, 30)) {
      const room = e.room || e.data || e;
      const x = toRoom(room, e.web_rid);
      if (x.id) out.push(x);
      else dropped++;
    }
    return JSON.stringify({ status: 200, items: out, stats: stats({ list: arr.length, kept: out.length, dropped }) });
    """#

    static let room = #"""
    const W = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', cookie_enabled: 'true',
      screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel', browser_name: 'Safari',
      browser_version: '26.0', channel: 'channel_pc_web' };
    const r = await req('GET', 'https://live.douyin.com/webcast/room/web/enter/?' + new URLSearchParams(Object.assign({}, W,
      { enter_from: 'web_live', enter_source: '', web_rid: rid })).toString());
    const d = parse(r.t);
    const stats = (extra) => Object.assign({ http: r.s, code: d && Number.isFinite(Number(d.status_code)) ? Number(d.status_code) : null, hasList: false, list: 0, kept: 0, dropped: 0, parsed: !!d }, extra || {});
    if (!d) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [], stats: stats() });
    if (d.status_code) return JSON.stringify({ status: 401, items: [], stats: stats() });
    const rm = d.data && d.data.data && d.data.data[0];
    const toRoom = (room, roomRid) => {
      const su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id || ''), webRid: String(roomRid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || '',
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    };
    if (!rm || rm.status !== 2) return JSON.stringify({ status: 200, items: [], stats: stats({ hasList: !!rm, list: rm ? 1 : 0, kept: 0, dropped: 1 }) });
    const x = toRoom(rm, rid);
    if (x.id && (Object.keys(x.hls).length || Object.keys(x.flv).length)) return JSON.stringify({ status: 200, items: [x], stats: stats({ hasList: true, list: 1, kept: 1, dropped: 0 }) });
    return JSON.stringify({ status: 200, items: [], stats: stats({ hasList: true, list: 1, kept: 0, dropped: 1 }) });
    """#
}

struct DYFollowMetadata: Equatable {
    var id: String
    var webRid: String
    var title: String
    var owner: String
    var avatar: String?
    var cover: String?
    var viewers: String
    var portrait: Bool

    func fillingEmpty(from fallback: DYFollowMetadata) -> DYFollowMetadata {
        DYFollowMetadata(
            id: id.isEmpty ? fallback.id : id,
            webRid: webRid.isEmpty ? fallback.webRid : webRid,
            title: title.isEmpty ? fallback.title : title,
            owner: owner.isEmpty ? fallback.owner : owner,
            avatar: avatar ?? fallback.avatar,
            cover: cover ?? fallback.cover,
            viewers: viewers.isEmpty ? fallback.viewers : viewers,
            portrait: portrait)
    }
}

struct DYFollowMetadataCache {
    var ttl: TimeInterval
    private var storedAt: Date?
    private var items: [DYFollowMetadata] = []

    mutating func store(_ items: [DYFollowMetadata], now: Date) {
        guard !items.isEmpty else { return }
        self.items = items
        storedAt = now
    }

    func items(now: Date) -> [DYFollowMetadata]? {
        guard let storedAt, now.timeIntervalSince(storedAt) < ttl, !items.isEmpty else { return nil }
        return items
    }

    mutating func invalidate() {
        items = []
        storedAt = nil
    }
}

/// 关注直播元数据只属于当前这一次登录会话。代际由 `reload` 推进；未登录只下毒，避免界面反复重拉。
struct DYFollowSessionCache {
    private(set) var generation = 0
    private var cache: DYFollowMetadataCache
    private var listGeneration: Int?
    private(set) var listEpoch = 0
    private var roomKey: (webRid: String, generation: Int)?
    private var loggedOut = false

    init(ttl: TimeInterval) {
        cache = DYFollowMetadataCache(ttl: ttl)
    }

    mutating func invalidate() {
        generation += 1
        listEpoch += 1
        cache.invalidate()
        listGeneration = nil
        roomKey = nil
        loggedOut = false
    }

    func cachedItems(now: Date) -> [DYFollowMetadata]? {
        guard !loggedOut else { return nil }
        return cache.items(now: now)
    }

    /// 只有记录中的列表代际仍是这一代时才合并。新的列表请求换一个 epoch，未登录下毒不再挡住它。
    mutating func beginList(generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        if listGeneration == generation { return true }
        listGeneration = generation
        listEpoch += 1
        loggedOut = false
        return false
    }

    mutating func finishList(generation: Int) {
        if listGeneration == generation { listGeneration = nil }
    }

    mutating func store(items: [DYFollowMetadata], generation: Int, epoch: Int, now: Date) {
        guard accepts(generation: generation, epoch: epoch), !items.isEmpty else { return }
        cache.store(items, now: now)
    }

    mutating func noteNotLoggedIn(generation: Int, epoch: Int) {
        guard generation == self.generation, epoch == listEpoch else { return }
        cache.invalidate()
        loggedOut = true
    }

    /// 同一个 webRid 且仍是当前代际时才合并进房请求。
    mutating func beginRoom(webRid: String) -> Bool {
        if let roomKey, roomKey.webRid == webRid, roomKey.generation == generation { return true }
        roomKey = (webRid, generation)
        return false
    }

    mutating func finishRoom(webRid: String, generation: Int) {
        if roomKey?.webRid == webRid, roomKey?.generation == generation { roomKey = nil }
    }

    func accepts(generation: Int, epoch: Int) -> Bool {
        generation == self.generation && epoch == listEpoch && !loggedOut
    }
}

enum DYFollowLiveIdentity {
    /// 保留第一条。空 id 丢掉；非空 id 或非空 webRid 的后续重复丢掉。空 webRid 不互相合并。
    static func unique<T>(_ items: [T], id: KeyPath<T, String>, webRid: KeyPath<T, String>) -> [T] {
        var seenIDs = Set<String>()
        var seenRids = Set<String>()
        var kept: [T] = []
        for item in items {
            let itemID = item[keyPath: id]
            if itemID.isEmpty || seenIDs.contains(itemID) { continue }
            let rid = item[keyPath: webRid]
            if !rid.isEmpty, seenRids.contains(rid) { continue }
            seenIDs.insert(itemID)
            if !rid.isEmpty { seenRids.insert(rid) }
            kept.append(item)
        }
        return kept
    }
}

enum DYFollowAvatarPolicy {
    static func liveNow<Item>(stale: Bool, kind: DYFollowLiveKind, items: [Item]) -> [Item] {
        if stale || kind != .rooms { return [] }
        return items
    }
}

struct DYFollowSelection {
    private(set) var token = 0
    private(set) var roomID: String?
    private(set) var detailWebRids: [String] = []
    private(set) var resolvingID: String?

    mutating func begin(roomID: String, webRid: String, hasStream: Bool) -> Int {
        token += 1
        resolvingID = nil
        self.roomID = roomID
        if !hasStream, !webRid.isEmpty { detailWebRids.append(webRid) }
        return token
    }

    func isCurrent(roomID: String, token: Int) -> Bool {
        self.token == token && self.roomID == roomID
    }

    mutating func startResolving(roomID: String) {
        guard self.roomID == roomID else { return }
        resolvingID = roomID
    }

    mutating func complete(roomID: String, token: Int) -> Bool {
        guard isCurrent(roomID: roomID, token: token), resolvingID == roomID else { return false }
        resolvingID = nil
        return true
    }

    mutating func cancel() {
        token += 1
        roomID = nil
        resolvingID = nil
    }
}

enum DYFollowSelectionFailure: Equatable {
    case unavailable
    case requestFailed
    case decodeFailed

    var message: String {
        switch self {
        case .unavailable: "这个直播间暂时没有可播放的线路"
        case .requestFailed: "直播线路获取失败"
        case .decodeFailed: "直播数据无法解析"
        }
    }

    static func from(kind: DYFollowLiveKind, hasPlayableRoom: Bool) -> DYFollowSelectionFailure? {
        switch kind {
        case .rooms where hasPlayableRoom: return nil
        case .rooms, .filtered, .nobodyLive: return .unavailable
        case .requestFailed: return .requestFailed
        case .decodeFailed, .unexpectedShape: return .decodeFailed
        case .notLoggedIn: return nil
        }
    }
}

/// 直播预览页「分类 / 关注直播」的位置。只看导航下沿、安全区和内容边距。
enum DYLivePreviewChrome {
    static let navGap: CGFloat = 8
    static let minTapHeight: CGFloat = 44
    static let contentMargin: CGFloat = 18

    /// `feedMinY` 与 `navMaxY` 使用同一个坐标空间。导航还没量到时只避开安全区。
    static func buttonOriginY(feedMinY: CGFloat, navMaxY: CGFloat, safeTop: CGFloat) -> CGFloat {
        let navBottomInFeed = navMaxY - feedMinY
        let belowNav = (navBottomInFeed > 0 ? navBottomInFeed : 0) + navGap
        return max(safeTop, belowNav)
    }

    static func horizontalInset(_ safe: CGFloat) -> CGFloat {
        max(contentMargin, safe)
    }

    /// 预览头和头像条要让开的高度：按钮、展开的头像，以及中间间距。
    static let controlBandHeight: CGFloat = 160
    /// 遮挡区外侧留出的空隙，和导航间距同一档。
    static let reservedGap: CGFloat = 8
    /// 左右都在让时，仍给两个按钮留下的最小宽度。
    static let minimumContentWidth: CGFloat = 120

    /// 把遮挡区变成内边距，而不是把整条预览头平移出屏幕。
    /// 右侧摄像头只增加 trailing；左侧只增加 leading；横跨按钮行才往下移。
    static func containedInsets(pane: CGRect, top: CGFloat, leading: CGFloat,
                                trailing: CGFloat, regions: [CGRect]) -> DYLivePreviewInsets {
        guard pane.width > 1, pane.height > 1 else {
            return DYLivePreviewInsets(top: top, leading: leading, trailing: trailing)
        }
        var top = max(0, top)
        var leading = max(0, leading)
        var trailing = max(0, trailing)
        let locals = regions
            .map { $0.offsetBy(dx: -pane.minX, dy: -pane.minY) }
            .filter { $0.width > 1 && $0.height > 1 }
        guard !locals.isEmpty else {
            return DYLivePreviewInsets(top: top, leading: leading, trailing: trailing)
        }
        for _ in 0..<4 {
            let band = CGRect(x: leading, y: top,
                              width: max(0, pane.width - leading - trailing),
                              height: controlBandHeight)
            var nextTop = top
            var nextLeading = leading
            var nextTrailing = trailing
            for local in locals {
                let hit = local.intersection(band)
                guard hit.width > 0.5, hit.height > 0.5 else { continue }
                if band.width > 1, hit.width >= band.width * 0.55 {
                    nextTop = max(nextTop, local.maxY + reservedGap)
                    continue
                }
                if local.midX >= pane.width / 2 {
                    nextTrailing = max(nextTrailing, pane.width - local.minX + reservedGap)
                } else {
                    nextLeading = max(nextLeading, local.maxX + reservedGap)
                }
            }
            let limit = max(0, pane.width - minimumContentWidth)
            if nextLeading + nextTrailing > limit {
                let leadGrowth = nextLeading - leading
                let trailGrowth = nextTrailing - trailing
                if leadGrowth <= trailGrowth {
                    nextTrailing = min(nextTrailing, max(trailing, limit - nextLeading))
                    nextLeading = min(nextLeading, max(0, limit - nextTrailing))
                } else {
                    nextLeading = min(nextLeading, max(leading, limit - nextTrailing))
                    nextTrailing = min(nextTrailing, max(0, limit - nextLeading))
                }
            }
            nextTop = min(max(0, nextTop), max(0, pane.height - minTapHeight))
            if nextTop == top, nextLeading == leading, nextTrailing == trailing { break }
            top = nextTop
            leading = nextLeading
            trailing = nextTrailing
        }
        return DYLivePreviewInsets(top: top, leading: leading, trailing: trailing)
    }

    /// 头像条可以画到状态栏图标下面，但折痕仍要让开，最后一颗头像要能滑回没有遮挡的位置。
    /// `conservativeTrailing` 是按钮用的完整右边距。条本身只用内容边距加上折痕，多出来的宽度变成滚动尾距。
    static func avatarStripInsets(conservativeTrailing: CGFloat, pane: CGRect, top: CGFloat,
                                  leading: CGFloat, divisions: [CGRect]) -> DYAvatarStripInsets {
        let hinge = containedInsets(pane: pane, top: top, leading: leading,
                                    trailing: contentMargin, regions: divisions)
        let trailing = min(max(contentMargin, hinge.trailing), max(contentMargin, conservativeTrailing))
        return DYAvatarStripInsets(trailing: trailing,
                                   scrollTail: max(0, conservativeTrailing - trailing))
    }
}

/// 头像条的右边距。`scrollTail` 加在滚动内容末尾，让最后一颗头像能滑出系统图标。
struct DYAvatarStripInsets: Equatable {
    var trailing: CGFloat
    var scrollTail: CGFloat
}

/// 直播预览头避让遮挡区之后的内边距。原点始终落在窗格内。
struct DYLivePreviewInsets: Equatable {
    var top: CGFloat
    var leading: CGFloat
    var trailing: CGFloat
}

#if DEBUG || FOLLOW_LIVE_LOGIC_MAIN
enum DYFollowLiveLogicTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let loggedOut = DYFollowLiveStats(http: 200, code: 8, hasList: false, list: 0, kept: 0, dropped: 0, parsed: true)
        check(DYFollowLiveClassify.kind(status: 401, itemCount: 0, stats: loggedOut) == .notLoggedIn, "status_code 8 应为未登录")
        let quiet = DYFollowLiveStats(http: 200, code: 0, hasList: true, list: 0, kept: 0, dropped: 0, parsed: true)
        check(DYFollowLiveClassify.kind(status: 200, itemCount: 0, stats: quiet) == .nobodyLive, "空列表才是没人直播")
        let dropped = DYFollowLiveStats(http: 200, code: 0, hasList: true, list: 4, kept: 0, dropped: 4, parsed: true)
        check(DYFollowLiveClassify.kind(status: 200, itemCount: 0, stats: dropped) == .filtered, "有房间但没有流不能当成没人直播")
        check(DYFollowLiveClassify.kind(status: 200, itemCount: 2, stats: quiet) == .rooms, "有房间时应返回列表")
        let offline = DYFollowLiveStats(http: -1, code: nil, hasList: false, list: 0, kept: 0, dropped: 0, parsed: false)
        check(DYFollowLiveClassify.kind(status: -1, itemCount: 0, stats: offline) == .requestFailed, "网络失败")
        let garbled = DYFollowLiveStats(http: 200, code: nil, hasList: false, list: 0, kept: 0, dropped: 0, parsed: false)
        check(DYFollowLiveClassify.kind(status: 403, itemCount: 0, stats: garbled) == .requestFailed, "正文无法解析")
        check(DYFollowLiveClassify.kind(status: 200, itemCount: 0, stats: nil) == .unexpectedShape, "没有统计信息的空结果不能当成没人直播")
        check(DYFollowLiveClassify.kind(status: 200, itemCount: 1, stats: nil) == .rooms, "没有统计信息但有房间仍可展示")
        let other = DYFollowLiveStats(http: 200, code: 2154, hasList: false, list: 0, kept: 0, dropped: 0, parsed: true)
        check(DYFollowLiveClassify.kind(status: 401, itemCount: 0, stats: other) == .requestFailed, "其它业务码不是未登录")
        let timeout = DYFollowLiveStats(http: -2, code: nil, hasList: false, list: 0, kept: 0, dropped: 0, parsed: false)
        check(DYFollowLiveClassify.kind(status: -2, itemCount: 0, stats: timeout) == .requestFailed, "进房超时仍是请求失败")
        let hardTimeout = DYFollowLiveStats(http: -3, code: nil, hasList: false, list: 0, kept: 0, dropped: 0, parsed: false)
        check(DYFollowLiveClassify.kind(status: -3, itemCount: 0, stats: hardTimeout) == .requestFailed, "进房硬超时仍是请求失败")
        let unavailable = DYFollowLiveStats(http: 200, code: 0, hasList: true, list: 1, kept: 0, dropped: 1, parsed: true)
        check(DYFollowLiveClassify.kind(status: 200, itemCount: 0, stats: unavailable) == .filtered, "选中的房间没有线路")

        func requestCount(_ script: String) -> Int { script.components(separatedBy: "await req").count - 1 }
        check(!DYFollowLiveScripts.list.contains("room/web/enter"), "展示列表不应请求房间详情")
        check(DYFollowLiveScripts.list.contains("webcast/web/feed/follow/"), "列表仍只走关注直播接口")
        check(requestCount(DYFollowLiveScripts.list) == 1, "列表脚本只发一次请求")
        check(DYFollowLiveScripts.list.contains("if (x.id) out.push(x)"), "没有流地址的房间仍要进列表")
        check(requestCount(DYFollowLiveScripts.room) == 1, "选中后只发一次进房请求")
        check(DYFollowLiveScripts.room.contains("room/web/enter"), "播放地址来自进房接口")
        check(DYFollowLiveScripts.room.contains("web_rid: rid"), "进房只带当前房间")

        var display = DYFollowSelection()
        check(display.detailWebRids.isEmpty, "20 个没有流地址的主播在展示前不需要详情请求")
        let firstPick = display.begin(roomID: "s3", webRid: "w3", hasStream: false)
        check(display.detailWebRids == ["w3"], "选择一个主播只解析这一间")
        let secondPick = display.begin(roomID: "s9", webRid: "w9", hasStream: false)
        check(!display.isCurrent(roomID: "s3", token: firstPick), "后一次选择使前一次结果失效")
        check(display.isCurrent(roomID: "s9", token: secondPick), "只有最新的选择可以应用")
        check(display.detailWebRids == ["w3", "w9"], "连续选择也不会回头请求整份列表")
        display.cancel()
        check(!display.isCurrent(roomID: "s9", token: secondPick), "关闭列表后迟到的结果不能再生效")
        var reuse = DYFollowSelection()
        _ = reuse.begin(roomID: "s1", webRid: "w1", hasStream: true)
        check(reuse.detailWebRids.isEmpty, "列表里已有流地址时直接复用")
        var missingRid = DYFollowSelection()
        _ = missingRid.begin(roomID: "s1", webRid: "", hasStream: false)
        check(missingRid.detailWebRids.isEmpty, "没有 webRid 时不能发详情请求")
        var resolving = DYFollowSelection()
        let ticketA = resolving.begin(roomID: "A", webRid: "wa", hasStream: false)
        resolving.startResolving(roomID: "A")
        let ticketB = resolving.begin(roomID: "B", webRid: "wb", hasStream: false)
        check(resolving.resolvingID == nil, "新的选择清掉上一个解析指示")
        resolving.startResolving(roomID: "B")
        check(resolving.isCurrent(roomID: "B", token: ticketB) && resolving.resolvingID == "B", "新房间可以进入解析")
        check(!resolving.complete(roomID: "A", token: ticketA) && resolving.resolvingID == "B", "旧房间完成不能清掉新指示")
        var emptyAfterResolving = DYFollowSelection()
        _ = emptyAfterResolving.begin(roomID: "s1", webRid: "w1", hasStream: false)
        emptyAfterResolving.startResolving(roomID: "s1")
        _ = emptyAfterResolving.begin(roomID: "s2", webRid: "", hasStream: false)
        check(emptyAfterResolving.resolvingID == nil && emptyAfterResolving.detailWebRids == ["w1"], "空 webRid 的新选择不显示指示也不追加详情")
        var dismissed = DYFollowSelection()
        let dismissedTicket = dismissed.begin(roomID: "s9", webRid: "w9", hasStream: false)
        dismissed.startResolving(roomID: "s9")
        dismissed.cancel()
        check(dismissed.resolvingID == nil && !dismissed.isCurrent(roomID: "s9", token: dismissedTicket), "关闭列表清掉指示且旧票据失效")

        check(DYFollowSelectionFailure.from(kind: .filtered, hasPlayableRoom: false) == .unavailable, "没有线路要有明确失败")
        check(DYFollowSelectionFailure.from(kind: .nobodyLive, hasPlayableRoom: false) == .unavailable, "进房时已经下播")
        check(DYFollowSelectionFailure.from(kind: .rooms, hasPlayableRoom: false) == .unavailable, "进房结果没有可播地址")
        check(DYFollowSelectionFailure.from(kind: .rooms, hasPlayableRoom: true) == nil, "拿到可播地址就可以进入")
        check(DYFollowSelectionFailure.from(kind: .requestFailed, hasPlayableRoom: false) == .requestFailed, "进房网络失败")
        check(DYFollowSelectionFailure.from(kind: .decodeFailed, hasPlayableRoom: false) == .decodeFailed, "进房数据无法解析")
        check(DYFollowSelectionFailure.from(kind: .unexpectedShape, hasPlayableRoom: false) == .decodeFailed, "进房结构异常按解析失败")
        check(DYFollowSelectionFailure.from(kind: .notLoggedIn, hasPlayableRoom: false) == nil, "未登录交给原来的登录状态")
        check(DYFollowSelectionFailure.unavailable.message == "这个直播间暂时没有可播放的线路", "没有线路的文案")
        check(DYFollowSelectionFailure.requestFailed.message == "直播线路获取失败", "网络失败的文案")
        check(DYFollowSelectionFailure.decodeFailed.message == "直播数据无法解析", "解析失败的文案")

        let resolved = DYFollowMetadata(id: "", webRid: "w", title: "", owner: "", avatar: nil, cover: "cover", viewers: "", portrait: false)
        let tapped = DYFollowMetadata(id: "1", webRid: "w", title: "标题", owner: "主播", avatar: "avatar", cover: nil, viewers: "9", portrait: true)
        let merged = resolved.fillingEmpty(from: tapped)
        check(merged.id == "1" && merged.webRid == "w" && merged.title == "标题" && merged.owner == "主播" && merged.avatar == "avatar" && merged.cover == "cover" && merged.viewers == "9" && merged.portrait == false, "进房结果补上列表里已有的名称")
        let labels = Set(Mirror(reflecting: merged).children.compactMap(\.label))
        check(!labels.contains("hls") && !labels.contains("flv"), "缓存元数据没有播放地址")

        var cache = DYFollowMetadataCache(ttl: 15)
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        cache.store([tapped], now: cachedAt)
        check(cache.items(now: cachedAt.addingTimeInterval(14))?.count == 1, "15 秒内可以复用主播信息")
        check(cache.items(now: cachedAt.addingTimeInterval(15)) == nil, "到期后不再复用主播信息")
        cache.store([tapped], now: cachedAt)
        cache.store([], now: cachedAt.addingTimeInterval(1))
        check(cache.items(now: cachedAt.addingTimeInterval(1))?.count == 1, "空结果不能清掉还有效的主播信息")
        cache.invalidate()
        check(cache.items(now: cachedAt.addingTimeInterval(2)) == nil, "失效后 TTL 内不再返回主播信息")

        let sessionNow = Date(timeIntervalSince1970: 1_700_000_100)
        let accountA = DYFollowMetadata(id: "a", webRid: "wa", title: "甲", owner: "甲", avatar: nil, cover: nil, viewers: "", portrait: true)
        let accountB = DYFollowMetadata(id: "b", webRid: "wb", title: "乙", owner: "乙", avatar: nil, cover: nil, viewers: "", portrait: true)
        var session = DYFollowSessionCache(ttl: 15)
        check(session.generation == 0, "会话代际从 0 开始")
        session.store(items: [accountA], generation: session.generation, epoch: session.listEpoch, now: sessionNow)
        session.invalidate()
        check(session.cachedItems(now: sessionNow.addingTimeInterval(1)) == nil, "invalidate 后 TTL 内不再返回上一账号")
        session.store(items: [accountA], generation: 0, epoch: 0, now: sessionNow.addingTimeInterval(1))
        check(session.cachedItems(now: sessionNow.addingTimeInterval(1)) == nil, "旧 generation 的 store 不能写回")
        session.store(items: [accountB], generation: session.generation, epoch: session.listEpoch, now: sessionNow.addingTimeInterval(1))
        check(session.cachedItems(now: sessionNow.addingTimeInterval(2))?.map(\.id) == ["b"], "新 generation 的 store 才是账号 B")
        var poisoned = DYFollowSessionCache(ttl: 15)
        poisoned.store(items: [accountA], generation: poisoned.generation, epoch: poisoned.listEpoch, now: sessionNow)
        let poisonedGeneration = poisoned.generation
        let poisonedEpoch = poisoned.listEpoch
        poisoned.noteNotLoggedIn(generation: poisonedGeneration, epoch: poisonedEpoch)
        check(poisoned.generation == poisonedGeneration, "未登录不推进代际")
        check(poisoned.cachedItems(now: sessionNow.addingTimeInterval(1)) == nil, "未登录清掉仍有效的缓存")
        poisoned.store(items: [accountA], generation: poisonedGeneration, epoch: poisonedEpoch, now: sessionNow.addingTimeInterval(1))
        check(poisoned.cachedItems(now: sessionNow.addingTimeInterval(2)) == nil, "同一代际的迟到 store 不能恢复")
        check(poisoned.beginList(generation: poisoned.generation) == false, "未登录后的新列表请求不再合并旧任务")
        poisoned.store(items: [accountB], generation: poisoned.generation, epoch: poisoned.listEpoch, now: sessionNow.addingTimeInterval(2))
        check(poisoned.cachedItems(now: sessionNow.addingTimeInterval(2))?.map(\.id) == ["b"], "新的列表请求可以写入当前账号")
        poisoned.noteNotLoggedIn(generation: poisonedGeneration, epoch: poisonedEpoch)
        check(poisoned.cachedItems(now: sessionNow.addingTimeInterval(2))?.map(\.id) == ["b"], "旧 epoch 的未登录不能清掉新请求")
        poisoned.invalidate()
        poisoned.store(items: [accountB], generation: poisoned.generation, epoch: poisoned.listEpoch, now: sessionNow.addingTimeInterval(3))
        check(poisoned.cachedItems(now: sessionNow.addingTimeInterval(3))?.map(\.id) == ["b"], "下一次代际可以缓存")

        struct Sample { var id: String; var webRid: String; var label: String }
        let duplicateIDs = DYFollowLiveIdentity.unique([
            Sample(id: "1", webRid: "a", label: "first"),
            Sample(id: "1", webRid: "b", label: "second"),
        ], id: \.id, webRid: \.webRid)
        check(duplicateIDs.map(\.label) == ["first"], "重复 id 保留第一条")
        let duplicateRids = DYFollowLiveIdentity.unique([
            Sample(id: "1", webRid: "w", label: "first"),
            Sample(id: "2", webRid: "w", label: "second"),
        ], id: \.id, webRid: \.webRid)
        check(duplicateRids.map(\.label) == ["first"], "重复的非空 webRid 保留第一条")
        let emptyRids = DYFollowLiveIdentity.unique([
            Sample(id: "3", webRid: "", label: "a"),
            Sample(id: "4", webRid: "", label: "b"),
        ], id: \.id, webRid: \.webRid)
        check(emptyRids.map(\.id) == ["3", "4"], "空 webRid 且 id 不同都保留")
        check(DYFollowLiveIdentity.unique([Sample(id: "", webRid: "w", label: "empty")], id: \.id, webRid: \.webRid).isEmpty, "空 id 被丢掉")
        check(DYFollowAvatarPolicy.liveNow(stale: true, kind: .rooms, items: ["old"]).isEmpty, "过期结果清空头像")
        check(DYFollowAvatarPolicy.liveNow(stale: false, kind: .notLoggedIn, items: ["old"]).isEmpty, "未登录清空头像")
        check(DYFollowAvatarPolicy.liveNow(stale: false, kind: .requestFailed, items: ["old"]).isEmpty, "请求失败清空头像")
        check(DYFollowAvatarPolicy.liveNow(stale: false, kind: .decodeFailed, items: ["old"]).isEmpty, "解析失败清空头像")
        check(DYFollowAvatarPolicy.liveNow(stale: false, kind: .rooms, items: ["n1", "n2"]) == ["n1", "n2"], "有房间时换成新 id")

        var visit = DYLiveVisit()
        visit.replaceFeed(ids: ["rec-a", "rec-b"], currentID: "rec-a", zoneID: "1010014")
        visit.open("fol-b")
        check(!visit.acceptsRecommendation && visit.roomIDs == ["fol-b"] && visit.currentID == "fol-b", "打开关注直播间只保留这一间")
        visit.replaceFeed(ids: ["other"], currentID: "other", zoneID: nil)
        check(visit.roomIDs == ["fol-b"], "关注直播期间不能被推荐列表覆盖")
        visit.open("fol-a")
        check(visit.leave() && visit.roomIDs == ["rec-a", "rec-b"] && visit.currentID == "rec-a" && visit.zoneID == "1010014", "退出应回到打开前的推荐直播")
        check(visit.acceptsRecommendation, "回到推荐后可以继续翻页")
        check(!visit.leave(), "普通退出不再次清空推荐")
        var closed = DYLiveVisit()
        closed.replaceFeed(ids: ["rec-a", "rec-b"], currentID: "rec-a", zoneID: "1010014")
        var pending = DYFollowSelection()
        let pendingTicket = pending.begin(roomID: "fol-a", webRid: "wa", hasStream: false)
        pending.cancel()
        if pending.isCurrent(roomID: "fol-a", token: pendingTicket) { closed.open("fol-a") }
        check(closed.acceptsRecommendation && closed.roomIDs == ["rec-a", "rec-b"] && closed.currentID == "rec-a" && closed.zoneID == "1010014", "关闭列表后仍停留在原来的推荐直播")
        visit.open("fol-a")
        visit.clear()
        check(visit.acceptsRecommendation && visit.roomIDs.isEmpty, "重置后不再恢复旧的关注会话")

        let compact = DYLivePreviewChrome.buttonOriginY(feedMinY: 0, navMaxY: 46, safeTop: 85)
        check(compact == 85, "外屏按钮应落在状态栏安全区下沿")
        check(compact - 46 >= DYLivePreviewChrome.navGap, "外屏与导航间距至少 8")
        let regular = DYLivePreviewChrome.buttonOriginY(feedMinY: 0, navMaxY: 73, safeTop: 39)
        check(regular == 81 && regular - 73 == DYLivePreviewChrome.navGap, "内屏按钮应在导航下沿再加 8")
        let grown = DYLivePreviewChrome.buttonOriginY(feedMinY: 0, navMaxY: 120, safeTop: 85)
        check(grown == 128 && grown - 120 == DYLivePreviewChrome.navGap, "导航变高时按钮跟着下移并保持 8pt")
        let shifted = DYLivePreviewChrome.buttonOriginY(feedMinY: 20, navMaxY: 66, safeTop: 39)
        check(shifted == 54, "导航和直播层不在同一原点时用相对位置")
        check(DYLivePreviewChrome.buttonOriginY(feedMinY: 0, navMaxY: 0, safeTop: 85) == 85, "导航未测到时仍避开状态栏")
        check(DYLivePreviewChrome.horizontalInset(0) == 18, "没有侧边安全区时保留 18pt")
        check(DYLivePreviewChrome.horizontalInset(10) == 18, "小于内容边距时用 18")
        check(DYLivePreviewChrome.horizontalInset(82) == 82, "侧边安全区大于 18 时让开")
        check(DYLivePreviewChrome.minTapHeight == 44, "最小触摸高度 44")

        let outer = CGRect(x: 0, y: 0, width: 320, height: 700)
        let clear = DYLivePreviewChrome.containedInsets(pane: outer, top: 85, leading: 18, trailing: 18, regions: [])
        check(clear == DYLivePreviewInsets(top: 85, leading: 18, trailing: 18), "没有遮挡时外屏边距不变")
        let above = CGRect(x: 250, y: 0, width: 70, height: 50)
        let status = DYLivePreviewChrome.containedInsets(pane: outer, top: 85, leading: 18, trailing: 18, regions: [above])
        check(status == clear, "完全在按钮行上方的摄像头不推移预览头")
        let camera = CGRect(x: 250, y: 40, width: 70, height: 90)
        let dodged = DYLivePreviewChrome.containedInsets(pane: outer, top: 85, leading: 18, trailing: 18, regions: [camera])
        check(dodged.leading == 18 && dodged.top == 85, "右侧摄像头不把发现按钮和第一颗头像推出左边界")
        check(dodged.trailing >= 320 - 250 + DYLivePreviewChrome.reservedGap, "右侧摄像头改为右侧内边距")
        let leftEdge = CGRect(x: 0, y: 40, width: 70, height: 90)
        let fromLeft = DYLivePreviewChrome.containedInsets(pane: outer, top: 85, leading: 18, trailing: 18, regions: [leftEdge])
        check(fromLeft.leading >= 78 && fromLeft.trailing == 18, "左侧遮挡只增加左边距")
        check(fromLeft.leading + fromLeft.trailing < outer.width, "左边距仍留在窗格内")
        let across = CGRect(x: 0, y: 70, width: 320, height: 40)
        let lowered = DYLivePreviewChrome.containedInsets(pane: outer, top: 85, leading: 18, trailing: 18, regions: [across])
        check(lowered.top >= 118 && lowered.leading == 18, "横跨按钮行的遮挡往下让，左边距不动")
        let inner = CGRect(x: 0, y: 0, width: 820, height: 600)
        let innerClear = DYLivePreviewChrome.containedInsets(pane: inner, top: 81, leading: 18, trailing: 18, regions: [])
        check(innerClear == DYLivePreviewInsets(top: 81, leading: 18, trailing: 18), "内屏没有遮挡时保持导航下沿")
        let shiftedPane = CGRect(x: 400, y: 20, width: 380, height: 640)
        let hinge = CGRect(x: 390, y: 0, width: 24, height: 640)
        let book = DYLivePreviewChrome.containedInsets(pane: shiftedPane, top: 12, leading: 18, trailing: 18, regions: [hinge])
        check(book.leading >= 18 && book.leading + book.trailing < shiftedPane.width, "分屏窗格里的折痕不把内容推出窗格")
        let stripClear = DYLivePreviewChrome.avatarStripInsets(conservativeTrailing: 18, pane: outer, top: 85, leading: 18, divisions: [])
        check(stripClear.trailing == 18 && stripClear.scrollTail == 0, "没有额外避让时头像条不另加尾距")
        let stripStatus = DYLivePreviewChrome.avatarStripInsets(conservativeTrailing: dodged.trailing, pane: outer, top: 85, leading: 18, divisions: [])
        check(stripStatus.trailing == 18, "状态栏遮挡不把整条头像行缩进去")
        check(stripStatus.scrollTail == dodged.trailing - 18, "最后一颗头像仍能滑出遮挡区")
        check(dodged.trailing > stripStatus.trailing, "发现按钮继续使用更保守的右边距")
        let fold = CGRect(x: 280, y: 0, width: 40, height: 700)
        let stripFold = DYLivePreviewChrome.avatarStripInsets(conservativeTrailing: 90, pane: outer, top: 85, leading: 18, divisions: [fold])
        check(stripFold.trailing >= 48 && stripFold.trailing <= 90, "头像条仍让开窗格里的折痕")
        check(stripFold.scrollTail == 90 - stripFold.trailing, "折痕之外的遮挡留在滚动尾距")
        check(stripFold.trailing < 90, "折痕避让不会再占满整个右侧系统区")
        return failures
    }
}
#endif

#if FOLLOW_LIVE_LOGIC_MAIN
@main
struct DYFollowLiveLogicMain {
    static func main() {
        let failures = DYFollowLiveLogicTests.run()
        if failures.isEmpty {
            print("DYFollowLiveLogicTests passed")
        } else {
            for failure in failures { print("FAIL \(failure)") }
            exit(1)
        }
    }
}
#endif
