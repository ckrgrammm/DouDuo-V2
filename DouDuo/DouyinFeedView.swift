// DouDuo：抖音第三方客户端。数据走抖音网页端接口，界面 / 播放全原生。
// 源自 無為 App 的「抖音原生模式」。
// - 一个看不见的 WKWebView（电脑版 UA）挂在抖音页面上，只当「签名代理」：在页面里发 XHR，
//   抖音自己的安全 SDK 自动补 a_bogus 等签名，签名算法跟着官方更新走，我们不用逆向。
// - 登录态与「网页版」共用 WKWebsiteDataStore.default()，在网页版登录后原生模式即带账号。
// - 推荐流：GET /aweme/v1/web/tab/feed/（网页版「推荐」页同一接口；不用「精选」module/feed）；
//   播放用 /aweme/v1/play/ 链接（302 到 CDN mp4，不需要 cookie，系统播放器直接播）。
// - 评论：GET /aweme/v1/web/comment/list/。
import SwiftUI
import Combine
import WebKit
import AVFoundation

/// 启动性能打点：写 ddlog「DDPERF  1234ms 事件」，毫秒从 App 进程起算
enum DDPerf {
    static let t0: Double = {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
    }()
    private static var seen = Set<String>()
    static var ms: Int { Int((Date().timeIntervalSince1970 - t0) * 1000) }
    /// once=true：同名事件只记第一次（首帧/首页这类）
    static func mark(_ event: String, once: Bool = true) {
        if once { guard seen.insert(event).inserted else { return } }
        DYLiveModel.log(String(format: "DDPERF %6dms %@", ms, event))
    }
}

/// Session-local read cache. Mutations never pass through this layer.
@MainActor
final class DYAsyncReadCache {
    private struct Entry { let data: Data; let time: TimeInterval }
    private struct Flight { let id: UUID; let task: Task<Data, Error> }
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private let now: () -> TimeInterval
    private let limit: Int
    private let byteLimit: Int

    init(limit: Int = 48, byteLimit: Int = 8 * 1024 * 1024,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.limit = max(1, limit); self.byteLimit = max(1, byteLimit); self.now = now
    }

    func invalidate() {
        entries.removeAll()
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll()
    }

    func load(key: String, maxAge: TimeInterval,
              fetch: @escaping @MainActor () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        if let entry = entries[key], now() - entry.time < maxAge { return entry.data }
        let flight: Flight
        if let existing = flights[key] { flight = existing }
        else {
            // One shared request per key, even if a preload and a screen start together.
            let task = Task { @MainActor in try await fetch() }
            flight = Flight(id: UUID(), task: task)
            flights[key] = flight
        }
        do {
            let data = try await flight.task.value
            if flights[key]?.id == flight.id {
                let valid = await Task.detached(priority: .utility) {
                    guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
                    guard let response = object as? [String: Any] else { return object is [Any] }
                    return (response["status"] as? Int ?? 200) == 200
                        && (response["code"] as? Int ?? 0) == 0
                        && (response["msg"] as? String) != "blocked"
                }.value
                // A reload/mutation while validation was suspended must not restore old data.
                if flights[key]?.id == flight.id {
                    flights[key] = nil
                    if valid, !flight.task.isCancelled, data.count <= byteLimit {
                        entries[key] = Entry(data: data, time: now())
                        while entries.count > limit || entries.values.reduce(0, { $0 + $1.data.count }) > byteLimit {
                            guard let oldest = entries.min(by: { $0.value.time < $1.value.time })?.key else { break }
                            entries[oldest] = nil
                        }
                    }
                }
            }
            try Task.checkCancellation()
            if flight.task.isCancelled { throw CancellationError() }
            return data
        } catch {
            if flights[key]?.id == flight.id { flights[key] = nil }
            throw error
        }
    }
}

// MARK: - 数据

struct DYAweme: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let desc: String
    let width: Double
    let height: Double
    let duration: Double
    let play: String?
    /// 抖音默认清晰度的地址（play 选了更高一档时才有）；高清起不来时备用
    var playAlt: String? = nil
    /// 秒开用的低码率地址（冷启动先放它，高清好了再换）
    var playFast: String? = nil
    /// 选中的清晰度说明（调试日志用）
    var q: String? = nil
    let cover: String?
    let images: [String]
    let author: Author
    let stats: Stats
    let music: String
    /// 该视频在你账号里是否已点赞 / 已收藏（未登录时一般没有这些字段）
    let userDigged: Int?
    let isCollect: Int?
    /// 0=视频 68=图文；上报观看时要带
    var awemeType: Int? = nil
    /// 作品原始发布时间（Unix 秒）；可选以兼容已保存的旧播放会话。
    var publishedAt: TimeInterval? = nil
    /// 保留平台返回的 AI 声明原文；没有标记不代表非 AI。
    var aiDeclaration: String? = nil
    /// 背景音乐直链（图文作品要边看图边放音乐）；旧会话没有这个字段
    var musicPlay: String? = nil
    /// 图文作品的背景音乐地址（视频返回 nil）。旧会话没有 musicPlay 时，图文的 play 就是那条 mp3
    var imageMusicURL: URL? { images.isEmpty ? nil : (musicPlay ?? play).flatMap(URL.init(string:)) }

    func publicationText(now: Date = Date()) -> String? {
        guard let publishedAt, publishedAt.isFinite, publishedAt > 0,
              publishedAt <= now.timeIntervalSince1970 else { return nil }
        let age = now.timeIntervalSince1970 - publishedAt
        if age < 60 { return "刚刚发布" }
        if age < 3600 { return "\(Int(age / 60))分钟前发布" }
        if age < 86400 { return "\(Int(age / 3600))小时前发布" }
        if age < 604800 { return "\(Int(age / 86400))天前发布" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: publishedAt)) + " 发布"
    }

    func metadataText(now: Date = Date()) -> String? {
        let parts = [publicationText(now: now), aiDeclaration?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    struct Author: Codable, Equatable { let name: String; let avatar: String?; let secUid: String?; var uid: String? = nil; var follow: Int? = nil }
    struct Stats: Codable, Equatable { let digg: Int; let comment: Int; let collect: Int; let share: Int; var play: Int? = nil }

    /// 视频画面高宽比，不是界面方向。界面布局看容器尺寸 / size class。
    var isTallFrame: Bool { height > width * 1.05 }
    var webURL: URL { URL(string: "https://www.douyin.com/video/\(id)")! }
}

/// 点赞/收藏的结果：成功 / 没登录 / 其它失败（带原因）
enum DYActionResult {
    case ok
    case notLoggedIn
    case failed(String)
}

struct DYActionResp: Decodable {
    let status: Int
    let statusCode: Int?
    let msg: String?
    var headers: String? = nil
    enum CodingKeys: String, CodingKey { case status, statusCode = "statusCode", msg, headers }
}

struct DYComment: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let name: String
    let avatar: String?
    let digg: Int
    let time: Double
    let replies: Int
    let ip: String?
    /// 这条评论在账号里是否已赞。缺字段当未赞。
    var userDigged: Int? = nil
    /// 评论配图（image_list）与表情包贴纸（sticker），缺字段为空
    var images: [DYCommentImage]? = nil
    var sticker: DYCommentImage? = nil
}

/// 评论里的一张图：缩略图用于列表，原图用于点开全屏
struct DYCommentImage: Decodable, Equatable, Hashable {
    let thumb: String
    let full: String
    let w: Double
    let h: Double
}

struct DYLiveRoom: Identifiable, Decodable, Equatable {
    let id: String
    let webRid: String
    let title: String
    let owner: String
    let avatar: String?
    let cover: String?
    let viewers: String
    let hls: [String: String]      // FULL_HD1 / HD1 / SD1 / SD2
    var flv: [String: String]? = nil
    let portrait: Bool
    var def: String? = nil

    var bestHLS: URL? {
        for k in ["HD1", "FULL_HD1", "SD2", "SD1"] { if let s = hls[k], let u = URL(string: s) { return u } }
        return hls.values.first.flatMap(URL.init(string:))
    }
    var webURL: URL { URL(string: "https://live.douyin.com/\(webRid)")! }
}

private struct DYLiveResp: Decodable { let status: Int; let items: [DYLiveRoom] }

/// 直播专区（网页版「游戏」下的专区；id 取自 live.douyin.com/categorynew/4_103_1_<id>）
/// shortcut: 写死网页版游戏页上的几个专区，网页改版/要别的分类时再从页面里抓
struct DYLiveZone: Hashable {
    let id: String, type: String, name: String
    static let all: [DYLiveZone] = [
        ("1010017", "无畏契约"), ("1011032", "三角洲行动"), ("1010045", "王者荣耀"), ("1010014", "英雄联盟"),
        ("1010032", "和平精英"), ("1010037", "穿越火线"), ("1010026", "绝地求生"), ("1010146", "QQ飞车端游"),
    ].map { DYLiveZone(id: $0.0, type: "1", name: $0.1) }
}

private struct DYFeedPage: Decodable { let status: Int; let items: [DYAweme]; let hasMore: Bool; let msg: String? }
private struct DYCommentPage: Decodable { let status: Int; let code: Int?; let items: [DYComment]; let cursor: Int; let hasMore: Bool; let total: Int; let msg: String? }

enum DYError: LocalizedError {
    case notReady, blocked(String), bad(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "抖音页面还没加载好"
        case .blocked(let m): "抖音拦截了请求（\(m)），在「网页版」里过一下验证或登录后重试"
        case .bad(let m): m
        }
    }
}

// MARK: - 签名代理（隐藏网页）

@MainActor
final class DouyinBridge: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var ready = false
    let web: WKWebView
    private let readCache = DYAsyncReadCache()
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private let startURL: URL
    private var liveContext: DouyinBridge?

    override convenience init() {
        self.init(startURL: URL(string: "https://www.douyin.com/jingxuan")!)
    }

    init(startURL: URL) {
        self.startURL = startURL
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        // 隐藏签名页只要接口，不要视频：⚠️ 不能设 allowsInlineMediaPlayback=false——
        // 抖音页自动播放时会弹系统全屏播放器盖住整个原生界面（UI 测试实测）。改成允许内联 + 脚本禁掉所有媒体播放
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.userContentController.addUserScript(WKUserScript(source: Self.noMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
        reload()
    }

    func reload() {
        invalidateReadCache()
        selfSecCache = nil
        ready = false
        if startURL.host == "www.douyin.com" { DDPerf.mark("bridge.load") }
        web.load(URLRequest(url: startURL))
        liveContext?.reload()
    }

    /// 直播专区请求在 live.douyin.com 的网页 SDK 中发出，共享真实登录态，避免跨域签名/请求被拒。
    private func callLive(_ body: String, args: [String: Any]) async throws -> Data {
        if liveContext == nil {
            let context = DouyinBridge(startURL: URL(string: "https://live.douyin.com/")!)
            context.web.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            web.superview?.addSubview(context.web)
            liveContext = context
        }
        guard let context = liveContext, context.web.superview != nil else { throw DYError.notReady }
        return try await context.call(body, args: args, attempts: 1)
    }

    /// 导航序号：reload 后旧导航的轮询不能把新页面标成就绪
    private var navGeneration = 0

    /// 签名 SDK（bdms）一加载、DOM 可交互就算就绪，不必等整页 didFinish + 固定 1.2s（实测提前约 2.5s）。
    /// didFinish + 1.2s 仍保留作兜底。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === web else { return }
        navGeneration += 1
        let gen = navGeneration
        DDPerf.mark("bridge.didCommit")
        Task { @MainActor [weak self] in
            for _ in 0..<150 {
                guard let self, gen == self.navGeneration, !self.ready else { return }
                // 只等 bdms：读接口靠它签 a_bogus 就够；写接口要的 securitySDK 由 requestJS 的 guardFor 自己短等
                let js = "typeof window.bdms !== 'undefined' && document.readyState !== 'loading'"
                if (try? await self.web.evaluateJavaScript(js)) as? Bool == true {
                    guard gen == self.navGeneration else { return }
                    self.markReady("sdk")
                    // ⚠️ bdms 到手时写接口要的 securitySDK（ticket guard）往往还没加载完。
                    // 这时 window.stop() 会把它的脚本一起掐掉 → 之后点赞/收藏/关注全报「没拿到抖音安全签名」。
                    // 所以先等 securitySDK 就绪（最多 10 秒）再停加载、清 DOM；等不到就只清 DOM，不 stop。
                    await self.quietWhenGuardReady(gen)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func quietWhenGuardReady(_ gen: Int) async {
        let probe = "!!(window.securitySDK && typeof window.securitySDK.getBdTicketGuardHeader === 'function')"
        var guardReady = false
        for _ in 0..<100 {
            guard gen == navGeneration else { return }
            if (try? await web.evaluateJavaScript(probe)) as? Bool == true { guardReady = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard gen == navGeneration else { return }
        // 不 window.stop()：会掐掉还在加载的 x-storage 密钥 iframe
        let js = Self.quietPageJS
        web.evaluateJavaScript(js) { r, _ in
            DYLiveModel.log("DDQUIET early guard=\(guardReady) \(r.map { String(describing: $0) } ?? "nil")")
        }
    }

    private func markReady(_ source: String) {
        guard !ready else { return }
        ready = true
        if startURL.host == "www.douyin.com" { DDPerf.mark("bridge.ready(\(source))") }
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.host == "www.douyin.com" { DDPerf.mark("bridge.didFinish") }
        // 安全 SDK 在 load 之后还要初始化一小会儿
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.markReady("didFinish")
            // 签名 SDK 就绪后把整页 DOM 清空：隐藏页面不再持续渲染（真机上 WebContent 曾占约 43% 一个核，手机发烫）
            self.web.evaluateJavaScript(Self.quietPageJS) { r, _ in DYLiveModel.log("DDQUIET \(r.map { String(describing: $0) } ?? "nil")") }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    func waitReady() async {
        if ready { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// 在抖音页面里发请求（页面 SDK 自动签名），JS 端把大 JSON 裁成精简结构再回传
    func call(_ body: String, args: [String: Any], attempts: Int = 3) async throws -> Data {
        try Task.checkCancellation()
        await waitReady()
        try Task.checkCancellation()
        var lastErr: Error = DYError.notReady
        for attempt in 0..<attempts {
            do {
                let r = try await web.callAsyncJavaScript(Self.requestJS + body, arguments: args, contentWorld: .page)
                guard let s = r as? String, let d = s.data(using: .utf8) else { throw DYError.bad("返回为空") }
                return d
            } catch {
                try Task.checkCancellation()
                lastErr = error
                DYLiveModel.log("DDCALL retry attempt=\(attempt) err=\(error.localizedDescription.prefix(80))")
                if attempt + 1 < attempts {
                    try await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastErr
    }

    func invalidateReadCache() { readCache.invalidate() }

    /// Explicitly opt in read-only APIs; never cache commands, sends or tracking.
    func cachedRead(_ body: String, args: [String: Any], maxAge: TimeInterval = 30,
                    attempts: Int = 1) async throws -> Data {
        let arguments = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        let key = body + "\n" + arguments.base64EncodedString()
        return try await readCache.load(key: key, maxAge: maxAge) { [self] in
            try await call(body, args: args, attempts: attempts)
        }
    }

    /// Warm small first pages only after the main feed has had time to start.
    func prefetchCommonScreens() async {
        guard !Task.isCancelled, (try? await selfProfile()) != nil else { return }
        async let posts = try? myList(.post, cursor: "0")
        async let saved = try? myList(.collect, cursor: "0")
        _ = await (posts, saved)
    }

    /// Warm the current creator only; shared reads also serve a swipe during loading.
    func prefetchCreator(_ sec: String) async {
        guard !sec.isEmpty, !Task.isCancelled else { return }
        async let profile = try? userProfile(sec)
        async let posts = try? userPosts(sec, cursor: "0")
        async let follow = try? followState(sec: sec)
        let (user, page, _) = await (profile, posts, follow)
        guard !Task.isCancelled else { return }
        let images = ([user?.avatar] + (page?.items.prefix(6).map { $0.cover } ?? []))
            .compactMap { $0 }.compactMap(URL.init(string:))
        await withTaskGroup(of: Void.self) { group in
            for url in images {
                group.addTask { _ = await ImageCache.shared.load(url) }
            }
        }
    }

    /// 本次启动看过几条（推荐接口的 view_count，网页版同口径）
    private var watchCount = 0

    /// 观看上报：跟网页版一样，起播时报播放(aweme/stats)、登录时写观看历史(history/write)。
    /// 不上报，账号就学不到你在DouDuo里看了什么，推荐会和 App 越走越远。
    func reportWatch(_ a: DYAweme, preID: String?, preSeen: Bool) async {
        watchCount += 1
        let d = try? await call(Self.watchJS, args: [
            "id": a.id, "type": String(a.awemeType ?? 0), "author": a.author.uid ?? "",
            "pre": preID ?? "", "seen": preSeen ? "1" : "0"], attempts: 1)
        #if DEBUG
        DYLiveModel.log("DDWATCH \(a.id) \(d.flatMap { String(data: $0, encoding: .utf8) } ?? "fail")")
        #endif
    }
    /// 自己的 sec_uid（拉「喜欢」列表要用）
    var selfSecCache: String?

    private static let noMediaJS = """
    (() => {
      const P = HTMLMediaElement.prototype;
      P.play = function () { try { this.muted = true; this.pause(); } catch (e) {} return Promise.resolve(); };
      const V = HTMLVideoElement.prototype;
      // 签名页绝不能占用原生全屏播放器；部分网站会直接请求全屏而不调用 play()。
      V.webkitEnterFullscreen = V.webkitEnterFullScreen = function () {};
      for (const key of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
        Element.prototype[key] = function () { return Promise.resolve(); };
      }
      const kill = () => document.querySelectorAll('video,audio').forEach(v => { try {
        v.muted = true; v.pause(); v.removeAttribute('autoplay'); v.preload = 'none';
        v.playsInline = true; v.setAttribute('playsinline', ''); v.setAttribute('webkit-playsinline', '');
      } catch (e) {} });
      const observe = () => {
        kill();
        if (document.documentElement) new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
      };
      document.addEventListener('DOMContentLoaded', observe);
      if (document.documentElement) observe();
    })();
    """

    /// 推荐流一页。refresh_index / pull_type 由 DYFeedCoordinator 统一分配（票），这里不自己计数。
    func fetchFeed(_ ticket: DYFeedTicket) async throws -> DYFeedFetchedPage<DYAweme> {
        let r = try await fetchFeed(refresh: ticket.refreshIndex, pull: ticket.pull, tag: "\(ticket.worker) seq=\(ticket.seq)")
        return DYFeedFetchedPage(items: r.items, hasMore: r.hasMore)
    }

    func fetchFeed(refresh: Int, pull: String, tag: String = "") async throws -> (items: [DYAweme], hasMore: Bool) {
        let t0 = DDPerf.ms
        defer { DYLiveModel.log("DDPERF feed.request #\(refresh) \(tag) took \(DDPerf.ms - t0)ms (start \(t0)ms)") }
        // 只读一次就不重试：失败交给 coordinator 退避 / 换 Worker，避免一个请求在里面重试 3 次卡住顺序合并
        let d = try await call(Self.feedJS, args: ["refresh": String(refresh), "pull": pull,
                                                   "views": String(watchCount)], attempts: 2)
        let p = try JSONDecoder().decode(DYFeedPage.self, from: d)
        DYLiveModel.log("DDFEED n=\(p.items.count) status=\(p.status)")
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        DDPerf.mark("feed.firstNetworkPage")
        if p.items.isEmpty, let m = p.msg, !m.isEmpty { throw DYError.blocked(m) }
        return (p.items, p.hasMore)
    }

    /// 真点赞（走网页端同一个接口，页面 SDK 自动签名）
    func digg(_ id: String, like: Bool) async throws -> DYActionResult {
        invalidateReadCache()
        defer { invalidateReadCache() }
        let d = try await call(Self.diggJS, args: ["id": id, "type": like ? "1" : "0"])
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT digg id=\(id) like=\(like) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        if let h = r.headers, !h.isEmpty { ddWrite("DDACT digg \(r.status) headers: \(h.replacingOccurrences(of: "\r\n", with: " | "))") }
        #endif
        return Self.interpret(r)
    }

    /// 不感兴趣：网页版同一个接口（commit/dislike/item），抖音据此减少同类推荐
    func dislike(_ id: String) async throws -> DYActionResult {
        invalidateReadCache()
        defer { invalidateReadCache() }
        let d = try await call(Self.dislikeJS, args: ["id": id], attempts: 2)
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT dislike id=\(id) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    /// 统一解读：status_code 8 = 用户未登录；0 = 成功
    private static func interpret(_ r: DYActionResp) -> DYActionResult {
        actionResult(status: r.status, code: r.statusCode, msg: r.msg, detail: r.headers)
    }

    /// requestJS 的 req 拒发未签名写请求时返回的状态（见 guardFor）
    static let guardRefusedStatus = -4
    static let guardRefusedMessage = "没拿到抖音安全签名，为保护登录态没发送。请到 菜单 → 网页版 重新登录后再试"

    /// 所有写接口（点赞 / 收藏 / 不感兴趣 / 关注 / 评论赞 …）共用的结果解读：status_code 0 = 成功，8 = 未登录
    static func actionResult(status: Int, code: Int?, msg: String?, detail: String? = nil) -> DYActionResult {
        if status == 200, (code ?? 0) == 0 { return .ok }
        if status == guardRefusedStatus {
            // 附上拦截原因（nosdk / timeout / keys=… login=…），方便定位是哪一步没拿到签名
            let why = (detail ?? "").replacingOccurrences(of: "ticket-guard missing: ", with: "")
            return .failed(why.isEmpty ? guardRefusedMessage : guardRefusedMessage + "\n[\(why)]")
        }
        if code == 8 || (msg ?? "").contains("未登录") { return .notLoggedIn }
        return .failed(msg?.isEmpty == false ? msg! : "HTTP \(status) / code \(code ?? -1)")
    }

    /// 真收藏 / 取消收藏
    func favorite(_ id: String, add: Bool) async throws -> DYActionResult {
        invalidateReadCache()
        defer { invalidateReadCache() }
        #if DEBUG
        ddWrite("DDACT fav start id=\(id) add=\(add)")
        #endif
        let d = try await call(Self.favJS, args: ["id": id, "action": add ? "1" : "0"])
        #if DEBUG
        ddWrite("DDACT fav raw \(String(data: d, encoding: .utf8)?.prefix(200) ?? "-")")
        #endif
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT fav id=\(id) add=\(add) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    #if DEBUG
    /// 模拟器扫码登录：直接走抖音 SSO 的二维码接口，二维码存 Documents/qr.png，扫完自动跳 redirect 落 cookie
    func debugQRLogin() async {
        await waitReady()
        let getJS = #"""
        const r = await fetch('https://sso.douyin.com/get_qrcode/?service=' + encodeURIComponent('https://www.douyin.com') + '&need_logo=false&need_short_url=false&aid=6383&account_sdk_source=sso&language=zh', { credentials: 'include' });
        const t = await r.text();
        return t;
        """#
        guard let raw = try? await web.callAsyncJavaScript(getJS, arguments: [:], contentWorld: .page) as? String,
              let d = raw.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let data = j["data"] as? [String: Any],
              let b64 = data["qrcode"] as? String, let token = data["token"] as? String,
              let png = Data(base64Encoded: b64) else {
            DYLiveModel.log("DDQR get 失败 \((try? await web.callAsyncJavaScript(getJS, arguments: [:], contentWorld: .page)) as? String ?? "nil")")
            return
        }
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qr.png")
        try? png.write(to: u)
        DYLiveModel.log("DDQR 二维码已生成 token=\(token.prefix(8))")
        let checkJS = #"""
        const r = await fetch('https://sso.douyin.com/check_qrconnect/?service=' + encodeURIComponent('https://www.douyin.com') + '&token=' + token + '&need_logo=false&aid=6383&account_sdk_source=sso&language=zh', { credentials: 'include' });
        return await r.text();
        """#
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let s = try? await web.callAsyncJavaScript(checkJS, arguments: ["token": token], contentWorld: .page) as? String,
                  let cd = s.data(using: .utf8), let cj = try? JSONSerialization.jsonObject(with: cd) as? [String: Any],
                  let dd = cj["data"] as? [String: Any] else { continue }
            let st = "\(dd["status"] ?? "?")"
            DYLiveModel.log("DDQR status=\(st)")
            if let redirect = dd["redirect_url"] as? String, let ru = URL(string: redirect), !redirect.isEmpty {
                DYLiveModel.log("DDQR 已确认，跳转落 cookie")
                web.load(URLRequest(url: ru))
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                reload()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if let me = try? await selfProfile() { DYLiveModel.log("DDQR 登录成功 \(me.name)") }
                else { DYLiveModel.log("DDQR 跳转后仍未登录") }
                return
            }
            if st == "5" || st == "4" { DYLiveModel.log("DDQR 二维码过期"); return }
        }
    }

    /// 调试：把真机登录态导出 / 导入到模拟器（只在 DEBUG，本机两台设备之间搬，不上传）
    func debugExportCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cs = await store.allCookies().filter { $0.domain.contains("douyin") }
        let arr: [[String: Any]] = cs.map { c in
            var p: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                    "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
            if let e = c.expiresDate { p["expires"] = e.timeIntervalSince1970 }
            return p
        }
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-cookies.json")
        if let d = try? JSONSerialization.data(withJSONObject: arr) { try? d.write(to: u) }
        DYLiveModel.log("DDCK export \(arr.count) sessionid=\(cs.contains { $0.name == "sessionid" })")
    }

    func debugImportCookies() async {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-cookies.json")
        guard let d = try? Data(contentsOf: u), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
            DYLiveModel.log("DDCK import 没有文件"); return
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        var n = 0
        for p in arr {
            var props: [HTTPCookiePropertyKey: Any] = [.name: p["name"] ?? "", .value: p["value"] ?? "",
                                                      .domain: p["domain"] ?? "", .path: p["path"] ?? "/"]
            if (p["secure"] as? Bool) == true { props[.secure] = "TRUE" }
            if (p["httpOnly"] as? Bool) == true { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let e = p["expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: e) }
            if let c = HTTPCookie(properties: props) { await store.setCookie(c); n += 1 }
        }
        try? FileManager.default.removeItem(at: u)
        DYLiveModel.log("DDCK import \(n)")
        reload()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        if let me = try? await selfProfile() { DYLiveModel.log("DDCK 登录成功 \(me.name)") } else { DYLiveModel.log("DDCK 导入后仍未登录") }
    }

    /// 探针：在签名页里跑一段 JS（可用 req/base/parse/first），返回字符串
    func probe(_ body: String) async -> String {
        (try? await call(body, args: [:])).flatMap { String(data: $0, encoding: .utf8) } ?? "ERR"
    }
    #endif

    /// 是否已登录（登录后推荐流才跟着账号走）
    func isLoggedIn() async -> Bool {
        let r = try? await web.callAsyncJavaScript(Self.loginJS, arguments: [:], contentWorld: .page)
        let s = (r as? String) ?? ""
        #if DEBUG
        ddWrite("DDACT login check -> \(s)")
        #endif
        return s.contains("sessionid") || s == "1"
    }

    func fetchComments(_ id: String, cursor: Int) async throws -> (items: [DYComment], cursor: Int, hasMore: Bool, total: Int) {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let page: DYCommentPage
            do {
                // 首屏评论已在视频轮到时预取：缓存 5 分钟，看完长视频再点评论也是秒开；翻页仍 30 秒
                let data = try await cachedRead(Self.commentJS, args: ["id": id, "cursor": String(cursor)],
                                                maxAge: cursor == 0 ? 300 : 30)
                page = try JSONDecoder().decode(DYCommentPage.self, from: data)
            } catch {
                // A cache reset can cancel the shared fetch while this panel is still visible.
                // Only the caller's cancellation means the user has actually left the panel.
                try Task.checkCancellation()
                if attempt == 2 {
                    if error is CancellationError { throw DYError.notReady }
                    throw error
                }
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                continue
            }
            let transient = page.status <= 0 || page.status >= 500 || page.msg == "blocked"
            if transient, attempt < 2 {
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                continue
            }
            guard page.status == 200, (page.code ?? 0) == 0, page.msg != "blocked" else {
                throw DYError.blocked(page.msg ?? "HTTP \(page.status)")
            }
            return (page.items, page.cursor, page.hasMore, page.total)
        }
        throw DYError.notReady
    }

    private var liveMaxTime = "0"
    private var liveOffset = 0
    private var liveCursorGeneration = UUID()

    /// 关注的主播里正在直播的（网页版直播首页顶上那排头像，同一个接口；要登录）
    func fetchFollowLive() async throws -> [DYLiveRoom] {
        let d = try await call(Self.followLiveJS, args: [:], attempts: 2)
        let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
        if p.items.isEmpty { DYLiveModel.log("DDFOLLOWLIVE status=\(p.status) raw=\(String(decoding: d.prefix(300), as: UTF8.self))") }
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        return p.items
    }

    private static let followLiveJS = #"""
    const W = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', cookie_enabled: 'true',
      screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel', browser_name: 'Safari',
      browser_version: '26.0', channel: 'channel_pc_web' };
    const r = await req('GET', 'https://live.douyin.com/webcast/web/feed/follow/?' + new URLSearchParams(Object.assign({}, W,
      { enter_from: 'web_homepage_follow', scene: 'aweme_pc_follow_top' })).toString());
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [], raw: (r.t || '').slice(0, 200) });
    if (d.status_code) return JSON.stringify({ status: 401, items: [], raw: (r.t || '').slice(0, 200) });
    const arr = Array.isArray(d.data) ? d.data : ((d.data && d.data.data) || []);
    const toRoom = (room, rid) => {
      const su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id || ''), webRid: String(rid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || '',
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    };
    const out = [];
    for (const e of arr.slice(0, 30)) {
      const room = e.room || e.data || e;
      let x = toRoom(room, e.web_rid);
      // 列表里没带流地址的，按 web_rid 进房拿一次（网页点头像也是走这个接口）
      if (!Object.keys(x.hls).length && !Object.keys(x.flv).length && x.webRid) {
        const er = parse((await req('GET', 'https://live.douyin.com/webcast/room/web/enter/?' + new URLSearchParams(Object.assign({}, W,
          { enter_from: 'web_live', enter_source: '', web_rid: x.webRid })).toString())).t);
        const rm = er && er.data && er.data.data && er.data.data[0];
        if (rm && rm.status === 2) x = toRoom(Object.assign({ owner: room.owner }, rm), x.webRid);
      }
      if (x.id && (Object.keys(x.hls).length || Object.keys(x.flv).length)) out.push(x);
    }
    return JSON.stringify({ status: 200, items: out, raw: out.length ? null : (r.t || '').slice(0, 300) });
    """#

    func fetchLive(reset: Bool, zone: DYLiveZone? = nil) async throws -> [DYLiveRoom] {
        if reset { liveMaxTime = "0"; liveOffset = 0; liveCursorGeneration = UUID() }
        let generation = liveCursorGeneration
        if let zone {
            let d = try await callLive(Self.zoneJS, args: ["partition": zone.id, "ptype": zone.type, "offset": String(liveOffset)])
            guard liveCursorGeneration == generation else { return [] }
            let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
            guard p.status == 200 else {
                throw DYError.bad("专区连接失败（HTTP \(p.status)），可打开网页版检查或返回推荐直播")
            }
            liveOffset += 15
            return p.items
        }
        let d = try await call(Self.liveJS, args: ["maxtime": liveMaxTime])
        guard liveCursorGeneration == generation else { return [] }
        let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        liveMaxTime = String(Int(Date().timeIntervalSince1970))
        return p.items
    }

    // 直播专区（网页版 live.douyin.com/categorynew/4_103_1_<id> 同一接口）：一页 15 个，按 offset 翻页
    private static let zoneJS = #"""
    const P = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', enter_from: 'page_refresh',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', os_name: 'Mac OS', os_version: '10.15.7',
      count: '15', offset: offset, partition: partition, partition_type: ptype, req_from: '2' };
    const r = await req('GET', 'https://live.douyin.com/webcast/web/partition/detail/room/v2/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    const arr = d && d.data && Array.isArray(d.data.data) ? d.data.data : null;
    if (!arr) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [] });
    const items = arr.filter(it => it && it.room && it.room.stream_url).map(it => {
      const room = it.room, su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id), webRid: String(it.web_rid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || (room.user_count ? String(room.user_count) : ''),
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    }).filter(x => Object.keys(x.hls).length > 0 || Object.keys(x.flv).length > 0);
    return JSON.stringify({ status: r.s, items });
    """#

    // 直播推荐：live.douyin.com/webcast/feed/（跨子域 XHR 同样被页面 SDK 签名，实测 200 / 20 条）
    private static let liveJS = #"""
    const P = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', enter_from: 'link_share',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', os_name: 'Mac OS', os_version: '10.15.7', channel: 'channel_pc_web',
      request_tag_from: 'web', need_map: '1', liveid: '1', is_draw: '1', inner_from_drawer: '0', custom_count: '20',
      action: 'load_more', action_type: 'loadmore', enter_source: 'web_homepage_hot_web_live_card',
      source_key: 'web_homepage_hot_web_live_card', is_ssr: 'true', maxtime: maxtime };
    const r = await req('GET', 'https://live.douyin.com/webcast/feed/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d || !Array.isArray(d.data)) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [] });
    const items = d.data.filter(it => it && it.type === 1 && it.data && it.data.stream_url).map(it => {
      const room = it.data, su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id), webRid: String(it.web_rid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || '',
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    }).filter(x => Object.keys(x.hls).length > 0 || Object.keys(x.flv).length > 0);
    return JSON.stringify({ status: r.s, items });
    """#

    private static let diggJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, type: type, item_type: '0' });
    const u = '/aweme/v1/web/commit/item/digg/?' + new URLSearchParams(P).toString();
    const r = await req('POST', u, '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code, msg: d.status_msg || (r.s === 200 ? '' : r.t.slice(0, 120)),
      headers: r.s === 200 ? null : (r.h || '').replace(/set-cookie:[^\n]*/gi, 'set-cookie: <hidden>').slice(0, 600) });
    """#

    private static let dislikeJS = #"""
    const r = await req('POST', '/aweme/v1/web/commit/dislike/item/?' + q({ aweme_id: id }),
      new URLSearchParams({ aweme_id: id }).toString());
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code, msg: d.status_msg || (r.s === 200 ? '' : (r.t || '').slice(0, 120)) });
    """#

    private static let favJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, action: action });
    const tries = ['/aweme/v1/web/commit/item/collect/', '/aweme/v1/web/aweme/collect/'];
    let last = { status: -1 };
    for (const u of tries) {
      const r = await req('POST', u + '?' + new URLSearchParams(P).toString(), '');
      const d = parse(r.t) || {};
      if (r.s === 200 && (d.status_code === 0 || d.status_code === undefined)) return JSON.stringify({ status: 200, statusCode: 0 });
      last = { status: r.s, statusCode: d.status_code, msg: (d.status_msg || r.t.slice(0, 120)) };
    }
    return JSON.stringify(last);
    """#

    /// SDK 就绪后清空隐藏页：停媒体、清 body 与样式表，之后新增元素（脚本、iframe 除外）也移除。
    /// ⚠️ 必须保留 iframe（及包着它的节点）：安全 SDK 把登录时生成的 ticket-guard 密钥存在
    /// x-storage-web 跨域 iframe 里，删掉它点赞/收藏/关注就拿不到 bd-ticket-guard-client-data
    /// →「没拿到抖音安全签名」。iframe 也不能挪位置（挪了会重新加载）。
    private static let quietPageJS = #"""
    (() => { try {
      document.querySelectorAll('video,audio').forEach(v => { try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {} });
      const keep = n => n.nodeType === 1 && (n.tagName === 'SCRIPT' || n.tagName === 'IFRAME' || !!n.querySelector('iframe'));
      if (document.body) {
        [...document.body.children].forEach(n => { if (!keep(n)) n.remove(); });
        new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => { if (n.nodeType === 1 && !keep(n)) n.remove(); })))
          .observe(document.body, { childList: true });
      }
      document.querySelectorAll('style,link[rel=stylesheet]').forEach(e => e.remove());
      return 'quiet iframes=' + document.querySelectorAll('iframe').length;
    } catch (e) { return 'err ' + e; } })()
    """#

    private static let loginJS = #"""
    return (document.cookie || '').includes('sessionid') ? 'sessionid' : '0';
    """#

    // 共用：在页面世界里发 XHR（被抖音 SDK hook，自动加签名）
    static let requestJS = #"""
    // VLCKit 3 能播 AVC-FLV，但部分 HEVC-FLV 会一直等首帧；先读网页 SDK 明确给出的编码，不能盲试 6 秒。
    const compatibleLiveFLV = su => {
      const raw = su.live_core_sdk_data && su.live_core_sdk_data.pull_data && su.live_core_sdk_data.pull_data.stream_data;
      const sdk = typeof raw === 'string' ? parse(raw) : raw;
      const streams = [];
      for (const [name, group] of Object.entries((sdk && sdk.data) || {})) {
        if (name === 'ao') continue; // ao 是纯音频，不能拿它的 h264 标记判定同路径视频流。
        for (const stream of Object.values(group || {})) {
          if (!stream || !stream.flv || stream.enableEncryption) continue;
          const params = typeof stream.sdk_params === 'string' ? parse(stream.sdk_params) : stream.sdk_params;
          const codec = String((params && params.VCodec) || '').toLowerCase();
          if ((codec === 'h264' || codec === 'avc') && Number(params.vbitrate) > 0) streams.push(stream.flv);
        }
      }
      const urls = new Set(streams);
      return Object.fromEntries(Object.entries(su.flv_pull_url || {}).filter(([_, u]) => urls.has(u)));
    };
    // 抖音「ticket guard」：点赞/关注/发评论/收藏等写接口必须带 bd-ticket-guard-* 头（页面安全 SDK 用登录时生成的密钥签）。
    // 不带就被安全网关 403（bd-ticket-guard-result: 1101），并且服务端直接吊销登录票据 → 之后全是「用户未登录」。
    // 受保护路径表取自 SDK 自己的配置；签名也让 SDK 自己算，跟着官方更新走。
    // 路径表读不到（SDK 配置还没加载 / 改名）时，按写接口特征兜底当受保护处理——宁可拦下也不能裸发。
    const writeLike = /\/(commit|collects?|comment\/(publish|digg|delete)|danmaku\/(post|digg|delete))/;
    const guardFor = async (method, path) => {
      let pathname = path;
      try { pathname = new URL(path, location.origin).pathname } catch (e) {}
      // 就绪只等 bdms（读接口不需要 securitySDK）；只有写请求才短等安全 SDK 加载（最多 3 秒），推荐流等 GET 不受影响
      let sdk = window.securitySDK;
      for (let i = 0; !sdk && i < 30 && method === 'POST'; i++) {
        await new Promise(ok => setTimeout(ok, 100)); sdk = window.securitySDK;
      }
      if (!window.__ddGuardPaths && sdk) {
        const list = [];
        for (const v of Object.values(sdk.config || {})) for (const c of (Array.isArray(v) ? v : [v])) list.push(...((c && c.consumerPathList) || []));
        if (list.length) window.__ddGuardPaths = list;   // 空表不缓存，下次再读
      }
      const guarded = window.__ddGuardPaths ? window.__ddGuardPaths.some(p => pathname.startsWith(p.replace(/\/$/, ''))) : writeLike.test(pathname);
      if (!guarded) return { protected: false, headers: null };
      if (!sdk || typeof sdk.getBdTicketGuardHeader !== 'function') return { protected: true, headers: null, why: 'nosdk' };
      // ⚠️ getBdTicketGuardHeader 写死 signType:pubKey / certType:header，只产出「登录下发」用的公钥头，
      // 永远不会有 bd-ticket-guard-client-data。点赞等 consumer 接口的 client-data 是 SDK 的 XHR 拦截器
      // 按 consumerPathList 自动加的（我们的 XHR 本来就被它 hook，a_bogus 也是这样来的）。
      // 所以这里只确认签名材料齐全（私钥 + 登录下发的 ticket + ts_sign），齐了就裸发，让拦截器签。
      const material = async () => {
        try { return await Promise.race([sdk.getMaterialDiagnostics(), new Promise(ok => setTimeout(() => ok(null), 1500))]) }
        catch (e) { return null }
      };
      const complete = m => !!(m && m.has_private_key === 1 && m.has_ticket === 1 && m.has_ts_sign === 1);
      try {
        let m = await material();
        let beat = '';
        // 缺票据：/passport/web/token/beat/ 是「票据下发」路径，已登录时调一次，服务端重新下发 ticket/ts_sign。每页最多一次。
        if (m && !complete(m) && !window.__ddBeatTried) {
          window.__ddBeatTried = true;
          beat = await new Promise(ok => {
            const x = new XMLHttpRequest();
            x.open('GET', '/passport/web/token/beat/?aid=6383&account_sdk_source=web&language=zh&device_platform=web_app');
            x.withCredentials = true; x.timeout = 6000;
            x.onload = () => {
              let code = '';
              try { const d = JSON.parse(x.responseText); code = d.message === 'success' ? 'ok' : String((d.data && d.data.error_code) || d.message || '?') } catch (e) { code = 'nojson' }
              ok(' beat=' + x.status + '/' + code + ' sd=' + (x.getResponseHeader('bd-ticket-guard-server-data') ? 1 : 0));
            };
            x.onerror = () => ok(' beat=neterr'); x.ontimeout = () => ok(' beat=timeout');
            x.send();
          });
          await new Promise(ok => setTimeout(ok, 300));   // 让 SDK 把下发的票据落盘
          m = await material();
        }
        const why = (m ? 'pk=' + m.has_private_key + ' tk=' + m.has_ticket + ' ts=' + m.has_ts_sign : 'nomat')
          + ' login=' + String(sdk._isLogin) + beat;
        return { protected: true, ok: complete(m), headers: null, why };
      } catch (e) { return { protected: true, ok: false, headers: null, why: 'err ' + e } }
    };
    const req = async (method, path, body) => {
      const g = await guardFor(method, path);
      // 宁可不发，也不能发一个没签名的写请求把登录态赔进去
      if (g.protected && method === 'POST' && !g.ok) {
        return { s: -4, t: '', h: 'ticket-guard missing: ' + (g.why || 'no material') };
      }
      return new Promise(ok => {
        const x = new XMLHttpRequest();
        let done = false;
        const fin = r => { if (!done) { done = true; ok(r) } };
        x.timeout = 12000;
        x.ontimeout = () => fin({ s: -2, t: '' });
        // 硬超时：页面安全 SDK 会接管 XHR，部分接口它压着不放、x.timeout 也不触发 → Promise 永远挂死
        setTimeout(() => { try { x.abort() } catch (e) {} fin({ s: -3, t: '' }) }, 14000);
        x.open(method, path); x.withCredentials = true;
        x.setRequestHeader('Accept', 'application/json, text/plain, */*');
        if (method === 'POST') x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
        if (g.headers) for (const [k, v] of Object.entries(g.headers)) { if (v != null && v !== '') x.setRequestHeader(k, String(v)) }
        x.onload = () => fin({ s: x.status, t: x.responseText, h: x.status === 200 ? '' : (x.getAllResponseHeaders() || '') }); x.onerror = () => fin({ s: -1, t: '' });
        x.send(body || null);
      });
    };
    const base = { device_platform: 'webapp', aid: '6383', channel: 'channel_pc_web', pc_client_type: '1', pc_libra_divert: 'Mac',
      update_version_code: '170400', support_h265: '1', support_dash: '0', version_code: '170400', version_name: '17.4.0',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', browser_online: 'true', engine_name: 'WebKit', engine_version: '605.1.15',
      os_name: 'Mac OS', os_version: '10.15.7', cpu_core_num: '8', device_memory: '8', platform: 'PC', downlink: '10',
      effective_type: '4g', round_trip_time: '50' };
    const parse = t => { try { return JSON.parse(t) } catch (e) { return null } };
    const first = o => (o && o.url_list && o.url_list[0]) || null;
    const q = s => new URLSearchParams(Object.assign({}, base, s)).toString();
    // 直连 CDN（douyinvod）优先：实测首字节 0.27–0.30s；www.douyin.com/aweme/v1/play/ 多跳一次 0.95–1.85s
    // ⚠️ 推荐 tab/feed 给的直连是 v3-web-prime.douyinvod.com（带 tk=webid），只认网页播放器，
    // AVPlayer / curl / 甚至页面里 fetch 都是 403 → 起播看门狗干等 6 秒再重建（2026-11-11 实测）。
    // 这种直连跳过，改用 /aweme/v1/play/ 跳转（302 到 zjcdn，首字节约 0.4–0.6s）。
    const playable = u => !/web-prime|[?&]tk=webid/.test(u);
    const pickRedirect = l => (l || []).find(u => u.includes('/aweme/v1/play/')) || null;
    const pickPlay = l => (l || []).find(u => !u.includes('/aweme/v1/play/') && playable(u)) || pickRedirect(l) || (l && l[0]) || null;
    // 清晰度：按「有效码率」挑最高一档（H.265 同码率约等于 H.264 的 1.4 倍），跳过弱网档
    const resOf = r => {
      const pa = r.play_addr || {}, w = pa.width || 0, h = pa.height || 0;
      if (w && h) return Math.min(w, h);
      const m = /_(\d{3,4})_/.exec(r.gear_name || ''); return m ? +m[1] : 0;
    };
    const bestRate = v => {
      const rs = (v.bit_rate || []).filter(r => r && r.play_addr && r.play_addr.url_list && r.play_addr.url_list.length)
        .filter(r => !/adapt_lowest|lower/i.test(r.gear_name || ''));
      rs.sort((a, b) => ((b.bit_rate || 0) * (b.is_h265 ? 1.4 : 1)) - ((a.bit_rate || 0) * (a.is_h265 ? 1.4 : 1)));
      return rs[0] || null;
    };
    const fastRate = v => {
      const rs = (v.bit_rate || []).filter(r => r && r.play_addr && r.play_addr.url_list && r.play_addr.url_list.length && resOf(r) >= 540);
      rs.sort((a, b) => (a.bit_rate || 0) - (b.bit_rate || 0));
      return rs[0] || null;
    };
    // 抖音作品 → 精简结构（推荐 / 关注 / 搜索 / 喜欢 / 收藏 / 历史 / 作品 共用）
    const mapA = a => {
      const v = a.video || {}, urls = (v.play_addr && v.play_addr.url_list) || [];
      const st = a.statistics || {};
      const def = pickPlay(urls), br = bestRate(v), best = br ? pickPlay(br.play_addr.url_list) : null;
      const fr = fastRate(v), fast = fr ? pickPlay(fr.play_addr.url_list) : null;
      const pd = v.play_addr || {};
      // 备用地址：优先 /aweme/v1/play/ 跳转；不能和主地址相同（主地址本身就是跳转时退到默认档）
      const main = best || def, redirect = pickRedirect(br ? br.play_addr.url_list : urls);
      return {
        id: String(a.aweme_id), desc: a.desc || '', width: v.width || 0, height: v.height || 0, duration: (v.duration || 0) / 1000,
        play: main,
        playAlt: redirect && redirect !== main ? redirect : (def && def !== main ? def : null),
        playFast: fast && fast !== main ? fast : null,
        q: (br ? (br.gear_name || '?') + ' ' + resOf(br) + 'p h265=' + (br.is_h265 ? 1 : 0) + ' ' + Math.round((br.bit_rate || 0) / 1000) + 'k' : 'nolist')
          + ' | def ' + (pd.width || 0) + 'x' + (pd.height || 0) + ' | gears ' + (v.bit_rate || []).map(r => (r.gear_name || '?') + ':' + Math.round((r.bit_rate || 0) / 1000) + 'k' + (r.is_h265 ? 'h' : '')).join(','),
        cover: first(v.cover) || first(v.origin_cover) || (a.images && a.images[0] && first(a.images[0])) || null,
        images: (a.images || []).map(i => first(i)).filter(Boolean),
        author: { name: (a.author && a.author.nickname) || '', avatar: a.author && first(a.author.avatar_thumb), secUid: a.author && a.author.sec_uid, uid: a.author && a.author.uid ? String(a.author.uid) : null, follow: a.author ? (a.author.follow_status || 0) : 0 },
        awemeType: a.aweme_type || 0,
        publishedAt: typeof a.create_time === 'number' && Number.isFinite(a.create_time) && a.create_time > 0 ? a.create_time : null,
        aiDeclaration: a.risk_infos && typeof a.risk_infos.content === 'string' && /(?:\bAI\b|人工智能)/i.test(a.risk_infos.content) ? (a.risk_infos.content.trim() || null) : null,
        stats: { digg: st.digg_count || 0, comment: st.comment_count || 0, collect: st.collect_count || 0, share: st.share_count || 0, play: st.play_count == null ? null : Number(st.play_count) },
        music: (a.music && a.music.title) || '',
        musicPlay: (a.music && first(a.music.play_url)) || null,
        userDigged: a.user_digged ? 1 : 0,
        isCollect: (a.is_collect || a.is_collected || (a.collect_stat === 1)) ? 1 : 0
      };
    };
    """#

    // 推荐流 = 网页版「推荐」页（douyin.com/?recommend=1）同一个接口：GET /aweme/v1/web/tab/feed/。
    // ⚠️ 不要换回 module/feed + module_id=3003101：那是「精选」页（/jingxuan）的流，给电脑端挑的横屏/长视频，
    // 跟账号的「推荐」兴趣不是一回事（2026-11 在网页里抓包确认）。也不拿精选兜底：拉不到就报错让用户重试。
    private static let feedJS = #"""
    const raw = { is_client: false, ff_danmaku_status: 1, danmaku_switch_status: 0, is_dash_user: 0, related_recommend: 1, is_xigua_user: 0 };
    if (pull !== '0') Object.assign(raw, { videoPrefer: { fsn: [], like: [], halfMin: [], min: [] }, seo_info: 'https://www.douyin.com/?recommend=1',
      is_auto_play: 0, is_full_screen: 0, is_full_webscreen: 0, is_mute: 0, is_speed: 1, is_visible: 1 });
    const T = Object.assign({}, base, { filterGids: '', tag_id: '', share_aweme_id: '', live_insert_type: '', count: '10', refresh_index: refresh,
      video_type_select: '1', aweme_pc_rec_raw_data: JSON.stringify(raw), globalwid: '', pull_type: pull, min_window: '0', free_right: '0',
      view_count: views, plug_block: '0', need_translation: '1', ug_source: '', creative_id: '' });
    const r = await req('GET', '/aweme/v1/web/tab/feed/?' + new URLSearchParams(T).toString());
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [], hasMore: false,
      msg: (r.t || '').replace(/[^\u4e00-\u9fa5A-Za-z0-9 ]/g, '').slice(-20) || 'blocked' });
    const items = (d.aweme_list || []).filter(a => a && a.video && !a.is_ads && !(a.raw_ad_data)).map(mapA);
    return JSON.stringify({ status: r.s, items, hasMore: !!d.has_more, msg: d.status_msg || null });
    """#

    private static let watchJS = #"""
    const s = await req('POST', '/aweme/v2/web/aweme/stats/?' + q({}),
      new URLSearchParams({ aweme_type: type, item_id: id, source: '0', play_delta: '1' }).toString());
    const ds = parse(s.t) || {};
    let h = { s: 0 }, dh = {};
    if (author) {
      h = await req('POST', '/aweme/v1/web/history/write/?' + q({}),
        new URLSearchParams({ aweme_id: id, author_id: author, pre_item_seen: seen, pre_item_id: pre }).toString());
      dh = parse(h.t) || {};
    }
    return JSON.stringify({ stats: [s.s, ds.status_code], history: [h.s, dh.status_code] });
    """#

    private static let commentJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, cursor: cursor, count: '20', item_type: '0', whale_cut_token: '', cut_version: '1', rcFT: '' });
    const r = await req('GET', '/aweme/v1/web/comment/list/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s, items: [], cursor: 0, hasMore: false, total: 0, msg: 'blocked' });
    const ddImg = o => { const u = o && o.url_list && o.url_list[0]; return u ? { u, w: o.width || 0, h: o.height || 0 } : null; };
    const ddImages = c => (c.image_list || []).map(x => {
      const m = ddImg(x.medium_url) || ddImg(x.thumb_url) || ddImg(x.crop_url) || ddImg(x.origin_url);
      const o = ddImg(x.origin_url) || m;
      return m ? { thumb: m.u, full: o.u, w: o.w || m.w, h: o.h || m.h } : null;
    }).filter(Boolean);
    const ddSticker = c => {
      const s = c.sticker; if (!s) return null;
      const st = ddImg(s.static_url) || ddImg(s.animate_url); if (!st) return null;
      const an = ddImg(s.animate_url) || st;
      return { thumb: st.u, full: an.u, w: s.width || st.w, h: s.height || st.h };
    };
    const items = (d.comments || []).map(c => ({
      id: String(c.cid), text: c.text || '', name: (c.user && c.user.nickname) || '', avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || 0, replies: c.reply_comment_total || 0, ip: c.ip_label || null, userDigged: c.user_digged ? 1 : 0,
      images: ddImages(c), sticker: ddSticker(c)
    }));
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, items, cursor: d.cursor || 0, hasMore: !!d.has_more, total: d.total || 0, msg: d.status_msg || null });
    """#
}

/// 隐藏网页要挂进窗口里，JS 定时器 / 网络才不被系统节流
private struct DouyinBridgeHost: UIViewRepresentable {
    let bridge: DouyinBridge
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        v.accessibilityElementsHidden = true
        v.alpha = 0.01
        v.clipsToBounds = true
        bridge.web.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        v.addSubview(bridge.web)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct DYPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    let gravity: AVLayerVideoGravity
    /// 首帧出来前透明（露出封面），出来后填底色盖住封面——封面是 4:3 裁图，和视频比例不一致
    let readyFill: UIColor
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
        var fill: UIColor = .clear
        private var obs: NSKeyValueObservation?
        func watch() {
            obs = pl.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
                let ready = l.isReadyForDisplay
                DispatchQueue.main.async { self?.backgroundColor = ready ? self?.fill : .clear }
            }
        }
    }
    func makeUIView(context: Context) -> V {
        let v = V(); v.isUserInteractionEnabled = false; v.fill = readyFill; v.watch(); return v
    }
    func updateUIView(_ v: V, context: Context) {
        v.fill = readyFill
        if v.pl.player !== player { v.pl.player = player }
        if v.pl.videoGravity != gravity { v.pl.videoGravity = gravity }
    }
}

// MARK: - 预加载（抖音同款：提前缓冲后面几条）

/// 当前条后面 N 条提前建好 AVPlayer 并缓冲开头几秒（不出声、不播放），滑到时页面直接接管 → 秒开。
/// 封面同时预取。窗口外的立即释放（硬解码会话有限，不能无限开）。
@MainActor
final class DYPreloader {
    static let ahead = 3   // 提前暖 3 条；微热降到 2、烫了 1
    private var players: [String: AVPlayer] = [:]
    private var handedOut: Set<String> = []
    private var obs: [String: NSKeyValueObservation] = [:]
    #if DEBUG
    var disabled = ProcessInfo.processInfo.environment["WUWEI_DEBUG_DOUYIN_NOPRELOAD"] == "1"
    #else
    let disabled = false
    #endif

    func update(_ items: [DYAweme], current index: Int) {
        guard !disabled, items.indices.contains(index) else { return }
        let th = ProcessInfo.processInfo.thermalState
        let ahead = th == .nominal ? Self.ahead : (th == .fair ? 2 : 1)
        let lo = index + 1, hi = min(items.count - 1, index + ahead)
        let window = lo <= hi ? Array(items[lo...hi]) : []
        let ids = Set(window.map(\.id))
        // 离开窗口的：释放没被领走的；已领走的只要离当前 ≥2 条就不再记账（页面已经销毁）
        for (id, p) in players where !ids.contains(id) { release(id, p) }
        let near = Set(items[max(0, index - 1)...min(items.count - 1, index + 1)].map(\.id))
        handedOut = handedOut.filter { near.contains($0) || ids.contains($0) }
        for a in window where players[a.id] == nil && !handedOut.contains(a.id) {
            // 图文：每张图都提前下好并在后台按屏幕尺寸解码（翻页时主线程不再解大图），背景音乐跟视频一样提前缓冲
            if !a.images.isEmpty { DYImagePostView.prefetchImages(a) }
            let source: URL
            if let music = a.imageMusicURL { source = music }
            else if a.images.isEmpty, let s = a.play, let url = URL(string: s) { source = DYVideoCache.localURL(a.id) ?? url }
            else { continue }
            let item = AVPlayerItem(asset: DYMedia.asset(source))
            item.preferredForwardBufferDuration = 6
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = true
            players[a.id] = p
            // ready 后 preroll：把开头的数据和首帧解码好
            obs[a.id] = item.observe(\.status, options: [.new]) { [weak p] it, _ in
                guard it.status == .readyToPlay else { return }
                DispatchQueue.main.async { p?.preroll(atRate: 1) { _ in } }
            }
            if a.images.isEmpty, let c = a.cover.flatMap(URL.init(string:)) { Task { _ = await ImageCache.shared.load(c); _ = await DYVideoBackdropCache.shared.load(c) } }
        }
    }

    /// 页面起播时来领；领走后由页面负责释放
    func take(_ id: String) -> AVPlayer? {
        guard let p = players.removeValue(forKey: id) else { return nil }
        obs.removeValue(forKey: id)?.invalidate()
        handedOut.insert(id)
        p.isMuted = false
        return p
    }

    func clear() {
        for (id, p) in players { release(id, p) }
        handedOut.removeAll()
    }

    private func release(_ id: String, _ p: AVPlayer) {
        obs.removeValue(forKey: id)?.invalidate()
        p.pause()
        p.replaceCurrentItem(with: nil)
        players[id] = nil
    }
}

// MARK: - 推荐流

enum DYRecommendationAspect: String, CaseIterable, Identifiable {
    case all, portraitFirst, landscapeFirst
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部内容（默认）"
        case .portraitFirst: "竖屏优先"
        case .landscapeFirst: "横屏优先"
        }
    }
    var portraitTarget: Double? {
        switch self { case .all: nil; case .portraitFirst: 0.9; case .landscapeFirst: 0.3 }
    }
}

extension DYAweme: DYFeedItem {
    var feedIsPortrait: Bool { !images.isEmpty || isTallFrame }
    var feedIsPlayable: Bool { play != nil || !images.isEmpty }
}

/// 推荐流指标里 UI 那一侧的部分（首帧耗时、滑动等待），写进 coordinator 的同一份快照
@MainActor
enum DYFeedBench {
    static weak var model: DYFeedModel?
    /// 自动滑动压测（DEBUG）：从空列表起跑，不恢复 / 不覆盖会话，不用本地缓存秒开，测的是纯网络供应
    static let isBenchRun: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["DOUDUO_FEED_AUTOSWIPE"] != nil
        #else
        false
        #endif
    }()
    private static var current: (id: String, at: Double)?

    /// 推荐页切到这一条（首帧计时从这里开始）
    /// 同一次界面更新里播放器的 onChange 可能比屏幕的 onChange(currentID) 先到：先记下，稍后对上
    private static var early: (id: String, at: Double)?

    static func becameCurrent(_ id: String, waited: Bool) {
        let now = Date().timeIntervalSince1970
        guard let p = model?.pipeline else { return }
        Task { await p.noteSwipe(waited: waited) }
        if let e = early, e.id == id, now - e.at < 0.5 {
            early = nil; current = nil
            Task { await p.noteFirstFrame(ms: 0) }
            return
        }
        current = (id, now)
    }
    /// 播放器出首帧（ShortVideoPlayer 在 isActive 且首帧到达时调用）；不是推荐页当前条的忽略
    static func firstFrame(_ id: String) {
        let now = Date().timeIntervalSince1970
        guard let c = current, c.id == id else { early = (id, now); return }
        current = nil
        let ms = Int((now - c.at) * 1000)
        guard let p = model?.pipeline else { return }
        Task { await p.noteFirstFrame(ms: ms) }
    }
    /// 写日志 + Documents/feed-bench.json（对比 1 / 2 / 4 Worker 用）
    static func dump(_ reason: String) {
        guard let p = model?.pipeline else { return }
        Task {
            let s = await p.snapshot()
            DYLiveModel.log("DDFEEDBENCH[\(reason)] " + s.summary)
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let d = try? JSONEncoder().encode(s) else { return }
            try? d.write(to: dir.appendingPathComponent("feed-bench-w\(s.workers)-c\(s.concurrency).json"), options: .atomic)
        }
    }
}

@MainActor
final class DYFeedModel: ObservableObject {
    @Published var items: [DYAweme] = []
    @Published var error: String?
    @Published var loading = false
    @Published var liked: Set<String> = []
    @Published var collected: Set<String> = []
    @Published var toast: String?
    /// 是否已登录抖音（登录后推荐流才按账号个性化，点赞/收藏才能进账号）
    @Published var isLoggedIn = false

    /// New key intentionally ignores legacy screen-dependent filters.
    @AppStorage("douyin_recommendation_aspect_v1") var aspectPreference: DYRecommendationAspect = .all
    /// 供应管线：4 个 Worker 由 coordinator 统一调度，结果按序合并进共享候选池（只存元数据）。
    /// 播放列表 items 只从 deliver() 这一个出口进新条目。
    let pipeline: DYFeedCoordinator<DYAweme>
    private weak var bridge: DouyinBridge?
    /// 播放列表里当前条之后保持几条（Forward Buffer）；再往后的留在候选池，不建播放器、不下视频
    static let forwardBuffer = 6
    /// 一次 loadMore 至少交出几条就可以先返回（起播 / 刷新不用等第二页）
    static let firstBatch = 3
    /// 当前播放到哪一条（屏幕在 focusCurrent 时同步过来），算「后面还剩几条」用
    private var cursorID: String?
    /// 播放列表追加了新条目（后台补充时），屏幕据此刷新预加载 / 缓存窗口
    var onAppend: (() -> Void)?
    static func isPortrait(_ a: DYAweme) -> Bool { a.feedIsPortrait }
    var targetRatio: Double? { aspectPreference.portraitTarget }
    /// 调试统计：API 原始返回 vs 最终排进播放列表（区分比例受限于接口还是客户端混排）
    private var delivered = 0, deliveredPortrait = 0

    init() {
        pipeline = DYFeedCoordinator(config: .fromEnvironment(), log: { DYLiveModel.log($0) })
        DYFeedBench.model = self
    }

    private var attaching: Task<Void, Never>?
    /// 挂上管线（只挂一次，并发调用都等同一个）；每次都等签名页就绪：
    /// 请求超时只从真正能发请求时算起，冷启动 / 登录后重载不会误判超时
    private func attach(_ bridge: DouyinBridge) async {
        if attaching == nil || self.bridge !== bridge {
            self.bridge = bridge
            let fetch: DYFeedCoordinator<DYAweme>.Fetch = { @MainActor [weak bridge] ticket in
                guard let bridge else { throw DYError.notReady }
                return try await bridge.fetchFeed(ticket)
            }
            let supply: DYFeedCoordinator<DYAweme>.Notify = { @MainActor [weak self] in await self?.supplied() }
            let pipeline = pipeline
            attaching = Task { await pipeline.attach(fetch: fetch, onSupply: supply) }
        }
        await attaching?.value
        await bridge.waitReady()
    }

    private var aheadCount: Int {
        guard let id = cursorID, let i = items.firstIndex(where: { $0.id == id }) else { return items.count }
        return items.count - i - 1
    }

    /// 候选进播放列表的唯一出口（按目标比例从共享池里取）
    @discardableResult
    func deliver(_ n: Int, substitute: Bool) async -> Int {
        guard n > 0 else { return 0 }
        await pipeline.setRatio(targetRatio)
        let have = Set(items.map(\.id))
        let got = await pipeline.take(n, substitute: substitute, ahead: aheadCount).filter { !have.contains($0.id) }
        guard !got.isEmpty else { return 0 }
        for a in got {
            // 账号里已点赞/已收藏的，进页面就是选中态
            if a.userDigged == 1 { liked.insert(a.id) }
            if a.isCollect == 1 { collected.insert(a.id) }
        }
        items.append(contentsOf: got)
        delivered += got.count; deliveredPortrait += got.filter(Self.isPortrait).count
        return got.count
    }

    /// 会话恢复 / 调试替换后：播放列表里已有的登记进去重集合
    func registerPlaylist() async { await pipeline.register(items.map(\.id)) }

    /// 启动时把本地已缓存、没看过、又不在列表里的放到候选池最前（秒开）
    func seedPool(_ cached: [DYAweme]) async {
        await pipeline.register(items.map(\.id))
        await pipeline.seed(cached)
    }

    /// 方向 / 比例变了：当前条之后的退回候选池重新按比例排（当前这条不动，不打断播放）
    func remix(after index: Int?) async {
        let keep = (index ?? -1) + 1
        guard keep <= items.count else { return }
        let upcoming = Array(items[keep...])
        items.removeSubrange(keep...)
        await pipeline.setRatio(targetRatio)
        await pipeline.putBack(upcoming)
        await deliver(max(upcoming.count, Self.forwardBuffer), substitute: true)
    }

    /// 屏幕每次换当前条时调：Forward Buffer 不够就从池子补，待播不够 20 条就让管线在后台补
    func supply(_ bridge: DouyinBridge, current id: String?) {
        cursorID = id
        Task {
            await attach(bridge)
            if !loading, aheadCount < Self.forwardBuffer,
               await deliver(Self.forwardBuffer - aheadCount, substitute: aheadCount < 2) > 0 { onAppend?() }
            await pipeline.demand(ahead: aheadCount)
        }
    }

    /// 管线合并出新候选：Forward Buffer 有空位就补上；顺便给池子最前面几条暖封面（只是图片，不建播放器）
    private func supplied() async {
        if !loading, aheadCount < Self.forwardBuffer,
           await deliver(Self.forwardBuffer - aheadCount, substitute: aheadCount < 2) > 0 { onAppend?() }
        for a in await pipeline.peek(4) {
            if let c = a.cover.flatMap(URL.init(string:)) { Task.detached(priority: .utility) { _ = await ImageCache.shared.load(c) } }
        }
    }

    private static func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "-" : String(format: "%.0f%%", Double(n) * 100 / Double(d)) }

    /// 用户在等（起播 / 播到底 / 不感兴趣后没下一条）：紧急要一批，至少交出 firstBatch 条（有比例要求时 6 条）
    func loadMore(_ bridge: DouyinBridge) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await attach(bridge)
        // Forward Buffer 本来就够（例如恢复的会话后面还有很多条）：不发紧急请求，只按水位在后台补
        // （当前条找不到时——比如刚被「不感兴趣」移走——照常紧急拉）
        if let id = cursorID, let i = items.firstIndex(where: { $0.id == id }), items.count - i - 1 >= Self.forwardBuffer {
            error = nil; await pipeline.demand(ahead: items.count - i - 1); return
        }
        let want = Self.forwardBuffer
        let goal = targetRatio == nil ? Self.firstBatch : want
        // 先只按目标方向挑；缺的方向再等几页，实在找不到最后才补位
        var added = await deliver(want, substitute: false)
        var rounds = 0
        while added < goal && rounds < 8 {
            await pipeline.demand(ahead: aheadCount, urgent: true)
            let alive = await pipeline.awaitNextMerge()
            rounds += 1
            // 头几页严格按比例；等了几页还凑不齐（接口就是给不出）或首屏为空时允许补位，避免卡住
            added += await deliver(want - added, substitute: rounds >= 3 || items.isEmpty)
            if !alive { break }
        }
        var substituted = 0
        if added < want { substituted = await deliver(want - added, substitute: true); added += substituted }
        let all = items.filter(Self.isPortrait).count
        let recent = items.suffix(20).filter(Self.isPortrait).count
        DYLiveModel.log("DDMIX list added=\(added) substituted=\(substituted) rounds=\(rounds) target=\(targetRatio.map { String(format: "%.2f", $0) } ?? "free") preference=\(aspectPreference.rawValue) playlist=\(all)/\(items.count) (\(Self.pct(all, items.count))) recent20=\(recent)/\(min(20, items.count)) (\(Self.pct(recent, min(20, items.count)))) pool=\(await pipeline.poolCount) delivered=\(Self.pct(deliveredPortrait, delivered))")
        if items.isEmpty {
            error = await pipeline.lastError.map { DYError.blocked($0).localizedDescription } ?? "暂时没刷到推荐，登录后或稍后再试"
        } else {
            error = nil
        }
        // 起播的这批交出去了，剩下的让管线在后台补到 20 条
        await pipeline.demand(ahead: aheadCount)
    }

    /// 刷新推荐：先拉到新一批再替换播放列表，失败不清空当前画面、候选池原样还原
    func refresh(_ bridge: DouyinBridge) async -> Bool {
        guard !loading else { return false }
        loading = true
        defer { loading = false }
        await attach(bridge)
        await pipeline.register(items.map(\.id))
        let backup = await pipeline.beginRefresh()
        await pipeline.setRatio(targetRatio)
        var fresh: [DYAweme] = [], rounds = 0
        let want = Self.forwardBuffer
        while fresh.count < (targetRatio == nil ? Self.firstBatch : want) && rounds < 8 {
            await pipeline.demand(ahead: fresh.count, urgent: true)
            let alive = await pipeline.awaitNextMerge()
            rounds += 1
            fresh += await pipeline.take(want - fresh.count, substitute: rounds >= 3, ahead: fresh.count)
            if !alive { break }
        }
        if fresh.count < want { fresh += await pipeline.take(want - fresh.count, substitute: true, ahead: fresh.count) }
        guard !fresh.isEmpty else { await pipeline.restore(backup); return false }
        for a in fresh {
            if a.userDigged == 1 { liked.insert(a.id) }
            if a.isCollect == 1 { collected.insert(a.id) }
        }
        items = fresh
        cursorID = fresh.first?.id
        error = nil
        await pipeline.demand(ahead: fresh.count - 1)
        return true
    }

    /// 账号变了 / 签名页重载：播放列表与候选池全部清空（请求序号继续往上数）
    func reset() async {
        items = []; error = nil; cursorID = nil; delivered = 0; deliveredPortrait = 0
        await pipeline.reset()
    }
}

struct DouyinFeedScreen: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = DouyinBridge()
    @StateObject private var feed = DYFeedModel()
    @State private var insets = EdgeInsets()
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var currentID: String?
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var dragStartID: String?
    @State private var scrollEndTask: Task<Void, Never>?
    @State private var initialized = false
    @State private var refreshing = false
    @State private var showComments = false
    @State private var web: DYWebTarget?
    @State private var tab: DYTab = {
        let e = ProcessInfo.processInfo.environment
        if e["DOUDUO_STARTLIVE"] == "1" { return .live }
        if e["DOUDUO_STARTFOLLOW"] == "1" { return .follow }
        return .recommend
    }()
    @StateObject private var live = DYLiveModel()
    @StateObject private var following = DYPagedModelHolder()
    @State private var showSearch = false
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @State private var showMine = false
    /// 顶栏「我的」按钮用的账号头像
    @State private var myUser: DYUser?
    @State private var authorTarget: DYAweme.Author?
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @AppStorage("douyin_muted_v1") private var muted = false
    @State private var pendingUpdate: DDUpdate?
    @State private var showFollowComments = false
    @State private var showMessages = false
    /// 盖在视频上的页面（我的/信息/搜索/作者）打开时，所有视频和直播都停
    private var overlayOpen: Bool { showSearch || showMine || showMessages || authorTarget != nil }
    /// 半折叠/合屏：顶栏要整体左移躲开前摄挖孔，间距也收紧
    @State private var topNudge: CGFloat = 0
    /// 顶栏可用宽度：评论栏从右侧滑出时 = 视频区宽度，顶栏跟着视频居中、自适应收紧
    @State private var topBarWidth: CGFloat?
    @State private var noticeUnread = 0

    /// 外屏评论打开（视频缩到面板上方）时顶栏让位
    private func commentsDocked(_ geo: GeometryProxy) -> Bool {
        let open = tab == .recommend ? showComments && current != nil : tab == .follow ? showFollowComments : false
        guard open else { return false }
        return DYCommentLayout(size: geo.size, fold: DYDuoMetrics.foldIsActive(geo), showComments: true).docked
    }

    private var currentIndex: Int? { currentID.flatMap { id in feed.items.firstIndex { $0.id == id } } }
    private var current: DYAweme? { currentIndex.map { feed.items[$0] } }

    var body: some View {
        GeometryReader { safe in
            ZStack(alignment: .top) {
                layoutRoot
                if !(tab == .live && (live.clean || live.entered)) && !commentsDocked(safe) {
                    topBar
                        .padding(.top, max(safe.safeAreaInsets.top, hSize == .compact ? 44 : 16) + 8)
                        .frame(width: topBarWidth)
                        .background {
                            GeometryReader { bar in
                                LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.22), .clear],
                                               startPoint: .top, endPoint: .bottom)
                                    .frame(height: bar.size.height + 36)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        // 直播间返回键只保留 DYLiveRoomPage 里那一颗画面内「返回」胶囊：
        // 主视图不挂 NavigationStack / toolbar，避免 Duo 系统侧栏再渲染一个重复的返回按钮。
        .background(DouyinBridgeHost(bridge: bridge).frame(width: 1, height: 1).allowsHitTesting(false))
        .background(DYForwardPreloadHost(item: current, enabled: !overlayOpen && web == nil))
        .task {
            guard !initialized else { return }
            initialized = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_SELFTEST"] == "1" { Task { await DDSelfTest.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_APITEST"] == "1" { Task { await DDApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LIVEPROBE"] == "1" { Task { await DDFeatureProbe.run(bridge, live: live) } }
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_APISCAN"] == "1" { Task { await DYApiScanner.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_CPROBE"] == "1" { Task { await DYCommentApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LOGINPROBE"] == "1" { Task { await DYLoginProbe.run(bridge) } }
            #endif
            if ProcessInfo.processInfo.environment["DOUDUO_EXPORTTEST"] == "1" { Task { await DDFeatureProbe.exportHeadProbe(bridge) } }
            // 真机验收用：DOUDUO_STARTLIVE=1 + DOUDUO_AUTOLIVEROOM=1 直接进房，省去手点。
            if ProcessInfo.processInfo.environment["DOUDUO_AUTOLIVEROOM"] == "1" {
                Task { @MainActor in
                    var waited = 0
                    while live.rooms.isEmpty, waited < 24 {
                        try? await Task.sleep(for: .milliseconds(500))
                        waited += 1
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                    if !live.entered, !live.rooms.isEmpty { live.enterRoom() }
                }
            }
            #endif
            if tab == .live { return }   // 起手就是直播页（调试）时别把推荐流的播放器都拉起来
            // 秒开：先播上次缓存好、还没看过的；连接抖音 / 拉推荐在后台接着往后补
            if feed.items.isEmpty, !DYFeedBench.isBenchRun, let saved = DYFeedSession.load() {
                feed.items = saved.items
                resume = saved.positions
                currentID = saved.currentID
                scrollID = saved.currentID
                for a in saved.items {
                    if a.userDigged == 1 { feed.liked.insert(a.id) }
                    if a.isCollect == 1 { feed.collected.insert(a.id) }
                }
                DDPerf.mark("feed.visible(session)")
                DYLiveModel.log("DDSESSION 恢复 id=\(saved.currentID) t=\(saved.positions[saved.currentID] ?? 0)")
            }
            if feed.items.isEmpty {
                // 没有会话：本地缓存好、没看过的按竖横比例挑出来先播
                let cached = DYFeedBench.isBenchRun ? [] : DYVideoCache.pendingSnapshot()
                if !cached.isEmpty {
                    await feed.seedPool(cached)
                    await feed.deliver(DYFeedModel.forwardBuffer, substitute: true)
                    for a in cached {
                        if a.userDigged == 1 { feed.liked.insert(a.id) }
                        if a.isCollect == 1 { feed.collected.insert(a.id) }
                    }
                    currentID = feed.items.first?.id
                    DDPerf.mark("feed.visible(cache)")
                    DYLiveModel.log("DDCACHE 启动从缓存起播 n=\(feed.items.count)/\(cached.count)")
                }
            }
            // 会话恢复的条目登记进去重集合；本地缓存好、没看过的放进共享候选池最前
            await feed.seedPool(DYFeedBench.isBenchRun ? [] : DYVideoCache.pendingSnapshot())
            // 恢复的会话里「当前条之后」是上次的排法：按现在的方向 / 比例重排（当前这条不动）
            if currentIndex != nil { await feed.remix(after: currentIndex) }
            feed.onAppend = { refreshWindows() }
            await feed.loadMore(bridge)
            if !feed.items.isEmpty { DDPerf.mark("feed.visible(network)") }
            if currentID == nil { currentID = feed.items.first?.id }
            focusCurrent()
            #if DEBUG
            // 用真实作品详情复验元数据显示，不造预览数据、不做账号互动。
            if let id = ProcessInfo.processInfo.environment["DOUDUO_VIDEO_ID"],
               let item = try? await bridge.awemeDetail(id) {
                feed.items = [item]; currentID = item.id; scrollID = item.id
                await feed.registerPlaylist()
                focusCurrent()
            }
            let env0 = ProcessInfo.processInfo.environment
            if let d = env0["DOUDUO_LIVEDELAY"], let sec = Double(d) {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { tab = .live }
            }
            let env = ProcessInfo.processInfo.environment
            if let o = env["DOUDUO_OPEN"] {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                switch o {
                case "search": showSearch = true
                case "mine": showMine = true
                case "follow": tab = .follow
                case "author": authorTarget = current?.author
                case "comments": showComments = true
                case "messages": showMessages = true
                case "login": web = DYWebTarget(url: URL(string: "https://www.douyin.com/?recommend=1")!)
                case "qr": Task { await bridge.debugQRLogin() }
                case "export": Task { await bridge.debugExportCookies() }
                case "import": Task { await bridge.debugImportCookies() }
                default: break
                }
            }
            if env["WUWEI_DEBUG_DOUYIN_ADVANCE"] == "1" {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if feed.items.count > 1 { withAnimation { currentID = feed.items[1].id } }
            }
            // 推荐流供应对比（1 / 2 / 4 Worker）：DOUDUO_FEED_AUTOSWIPE=每条停留秒数，DOUDUO_FEED_BENCH_SECS=总时长。
            // 只是自动往下滑（不上报观看 / 不写历史，见 reportWatch），结束写 Documents/feed-bench-w*-c*.json
            if let step = env["DOUDUO_FEED_AUTOSWIPE"].flatMap(Double.init), step > 0 {
                let total = env["DOUDUO_FEED_BENCH_SECS"].flatMap(Double.init) ?? 120
                let end = Date().addingTimeInterval(total)
                while Date() < end, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                    guard let i = currentIndex else { continue }
                    if i + 1 < feed.items.count { currentID = feed.items[i + 1].id }
                    else { playNext(after: feed.items[i].id) }
                }
                DYFeedBench.dump("bench")
            }
            if env["WUWEI_DEBUG_DOUYIN_LIVE"] == "1" { tab = .live }
            if env["WUWEI_DEBUG_DOUYIN_COMMENTS"] == "1" {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showComments = true
            }
            #endif
        }
        .task(id: currentID) {
            // 旧会话没有新增字段：只补当前作品元数据，不换播放地址、不丢进度。
            guard let id = currentID, feed.items.contains(where: { $0.id == id && $0.publishedAt == nil }),
                  let detail = try? await bridge.awemeDetail(id), !Task.isCancelled,
                  let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
            feed.items[index].publishedAt = detail.publishedAt
            feed.items[index].aiDeclaration = detail.aiDeclaration
            saveSession()
        }
        .onChange(of: currentID) { old, new in
            // ⚠️ 宽屏（Duo 内屏）首次布局时 ScrollView 会把 scrollPosition 回写成 nil → 没有「当前条」→ 全部不播、上滑也不认。
            // 列表非空时把 nil 顶回上一个；刷新 / 重载会先清空列表再置 nil，不受影响。
            if new == nil, let old, feed.items.contains(where: { $0.id == old }) { currentID = old; return }
            scrollID = new
            if let new, let i = feed.items.firstIndex(where: { $0.id == new }) {
                // 滑动等待：切到这条时后面已经没有可播的了（下一滑得等供应）
                DYFeedBench.becameCurrent(new, waited: i + 1 >= feed.items.count)
            }
            focusCurrent()
            saveSession()
            reportWatch(old: old, new: new)
            prefetchNextComments(after: new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveSession()
            DYFeedBench.dump("resign")
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if DDPlayback.shared.appIsActive { saveSession() }
        }
        .onChange(of: cacheCount) { _, _ in focusCurrent() }
        .onChange(of: feed.aspectPreference) { _, _ in remixUpcoming() }
        .onDisappear { live.stop(); preloader.clear() }
        .fullScreenCover(item: $web, onDismiss: {
            // 网页里可能登录 / 过了验证：重开签名页，先重新读登录态，再刷推荐
            live.reset(); following.model(bridge).reset(); preloader.clear(); currentID = nil; bridge.reload()
            Task {
                await feed.reset()
                await feed.loadMore(bridge)
                currentID = feed.items.first?.id
                focusCurrent()
            }
            if tab == .live { Task { await live.load(bridge, reset: true) } }
        }) { t in
            DouyinWebScreen(start: t.url)
        }
        .fullScreenCover(isPresented: $showMessages) {
            DYMessagesScreen(bridge: bridge, onClose: { showMessages = false }, onWeb: { u in
                showMessages = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: u) }
            })
        }
        .task(id: bridge.ready) {
            // 顶栏头像与消息红点：签名页每次（重新）就绪都重读一次。登录 / 重新登录后签名页会 reload，
            // 以前只在启动时读一次，启动后才登录的话头像一直是空的。
            guard bridge.ready else { return }
            do { myUser = try await bridge.selfProfile() }
            catch DYError.bad { myUser = nil }   // 明确未登录才清掉；网络错误保留旧头像
            catch {}
            await refreshNoticeUnread()          // 登录 / 重新登录后消息红点也跟着更新
        }
        .task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await preloadFollowing()
        }
        .task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            await bridge.prefetchCommonScreens()
        }
        .task {
            // 只预取一页直播元数据，不拉流、不进房；用户点直播时不必再从零等列表。
            guard tab != .live else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard live.rooms.isEmpty, !Task.isCancelled else { return }
            await live.load(bridge, reset: true)
            async let followed: Void = live.loadFollowLive(bridge)
            await withTaskGroup(of: Void.self) { group in
                for room in live.rooms.prefix(6) {
                    if let url = room.cover.flatMap(URL.init(string:)) {
                        group.addTask { _ = await ImageCache.shared.load(url) }
                    }
                }
            }
            _ = await followed
        }
        .onChange(of: showMessages) { _, open in
            if !open { Task { await refreshNoticeUnread() } }
        }
        .task {
            // 启动查一次新版本；关掉后同一版本不再提示
            if let u = await DDUpdateChecker.check() { pendingUpdate = u }
        }
        .alert("有新版本", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }; pendingUpdate = nil } })) {
            Button("去 GitHub 更新") {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u); DDUpdateChecker.open(u) }
                pendingUpdate = nil
            }
            Button("关闭", role: .cancel) {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }
                pendingUpdate = nil
            }
        } message: {
            Text("新版本 \(pendingUpdate?.version ?? "")（当前 \(DDUpdateChecker.currentVersion)）\n去 GitHub 下载新版，重新签名安装即可，登录态会保留。")
        }
    }

    @ViewBuilder
    private var layoutRoot: some View {
        GeometryReader { geo in
            let panelW = sidePanelWidth(geo)
            // 右侧有评论栏时前摄落在评论栏上，顶栏不用再躲
            let nudge = panelW > 0 ? 0 : DYDuoMetrics.topBarLeftShift(geo)
            let barW: CGFloat? = panelW > 0 ? geo.size.width - panelW : nil
            flatArrangement(geo)
                .onAppear { topNudge = nudge; topBarWidth = barW }
                .onChange(of: nudge) { _, n in topNudge = n }
                .onChange(of: barW) { _, v in withAnimation(.snappy) { topBarWidth = v } }
        }
    }

    @State private var nextCommentsTask: Task<Void, Never>?
    /// 下一条的评论首屏也提前拉（停留 1.5 秒才拉，快速划过不浪费请求）：划过去马上点评论也秒开
    private func prefetchNextComments(after id: String?) {
        nextCommentsTask?.cancel()
        guard let id, let i = feed.items.firstIndex(where: { $0.id == id }), i + 1 < feed.items.count else { return }
        let next = feed.items[i + 1].id
        nextCommentsTask = Task {
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            _ = try? await bridge.fetchComments(next, cursor: 0)
        }
    }

    /// 当前条之后按新的方向/比例重排；不够就接着拉
    private func remixUpcoming() {
        guard tab == .recommend || !feed.items.isEmpty else { return }
        Task {
            await feed.remix(after: currentIndex)
            DYLiveModel.log("DDMIX remix preference=\(feed.aspectPreference.rawValue) upcoming=\(feed.items.count - (currentIndex ?? -1) - 1)")
            if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
            focusCurrent()
        }
    }

    /// 一套布局通吃所有状态，且**不换容器**（换容器会重建播放器 → 黑屏 / 重播）：
    /// - 平放/外屏：视频铺满；够宽时评论从右侧滑出（视频等比适应可见区域，不裁切），窄屏走底部 sheet
    /// - 半折叠：视频自动缩到一多半，另一半常驻评论（宽>高→左右分；高>宽→上下分）
    /// 右侧评论栏宽度（没有右侧栏 = 0）；布局和顶栏共用同一算法
    private func sidePanelWidth(_ geo: GeometryProxy) -> CGFloat {
        DYCommentLayout(size: geo.size,
                        fold: tab != .live && DYDuoMetrics.foldIsActive(geo),
                        showComments: tab == .follow ? showFollowComments : showComments && tab == .recommend).panelWidth
    }

    private func flatArrangement(_ geo: GeometryProxy) -> some View {
        let fold = tab == .recommend && DYDuoMetrics.foldIsActive(geo)
        let layout = DYCommentLayout(size: geo.size, fold: fold,
                                     showComments: showComments && tab == .recommend)
        let w = geo.size.width, h = geo.size.height
        let sideBySide = layout.sideBySide
        let tableFold = layout.tableFold
        let showPanel = layout.showPanel
        let panelW = layout.panelWidth, panelH = layout.panelHeight
        let videoW = layout.videoWidth, videoH = layout.videoHeight

        return ZStack(alignment: .topLeading) {
            // 外屏：评论面板从底部升起，视频缩到上方继续播（关注流在 DYFollowFeed 里自己挂）
            DYCommentDock(enabled: layout.docked && tab == .recommend && current != nil, isOpen: $showComments) {
                feedArea
                    .frame(width: videoW, height: videoH, alignment: .topLeading)
                    .clipped()
            } panel: {
                if let cur = current {
                    DYCommentPanel(bridge: bridge, aweme: cur, onClose: { withAnimation(.snappy) { showComments = false } })
                        .id(cur.id)
                }
            }
            .frame(width: videoW, height: videoH, alignment: .topLeading)
            if showPanel, let cur = current {
                DYCommentPanel(bridge: bridge, aweme: cur,
                               onClose: fold ? nil : { withAnimation(.snappy) { showComments = false } })
                    .frame(width: sideBySide ? panelW : w,
                           height: tableFold ? panelH : h)
                    .offset(x: sideBySide ? videoW : 0, y: tableFold ? videoH : 0)
                    .id(cur.id)
            }
        }
        .background(theme.media.strongScrim.color(for: scheme).ignoresSafeArea())
        .animation(.snappy, value: fold)
        .animation(.snappy, value: showComments)
    }

    private func refreshNoticeUnread() async {
        guard let groups = try? await bridge.noticeCounts() else { return }
        noticeUnread = DYMessagesScreen.badge(groups)
    }

    /// 换条时：上一条看完没有（≥95%，网页版同口径）+ 新一条起播 1.5 秒后上报
    private func reportWatch(old: String?, new: String?) {
        guard let new, let item = feed.items.first(where: { $0.id == new }) else { return }
        #if DEBUG
        // 自动滑动压测不是真人在看：不写观看历史、不上报播放，免得污染账号的推荐与历史
        if ProcessInfo.processInfo.environment["DOUDUO_FEED_AUTOSWIPE"] != nil { return }
        #endif
        var seen = false
        if let old, let prev = feed.items.first(where: { $0.id == old }), prev.duration > 0,
           DDNowPlaying.id == old { seen = DDNowPlaying.time / prev.duration >= 0.95 }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard currentID == new else { return }
            await bridge.reportWatch(item, preID: old, preSeen: seen)
        }
    }

    private func saveSession() {
        guard !DYFeedBench.isBenchRun, let id = currentID, feed.items.contains(where: { $0.id == id }) else { return }
        var positions = resume
        if DDNowPlaying.id == id, DDNowPlaying.time.isFinite {
            positions[id] = max(0, DDNowPlaying.time)
        }
        DYFeedSession(items: feed.items, currentID: id, positions: positions).save()
    }

    /// 自动连播：播完滑到下一条；快到底时先补一页
    private func playNext(after id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        if i + 1 < feed.items.count {
            withAnimation { currentID = feed.items[i + 1].id }
        } else {
            Task {
                await feed.loadMore(bridge)
                if let j = feed.items.firstIndex(where: { $0.id == id }), j + 1 < feed.items.count {
                    withAnimation { currentID = feed.items[j + 1].id }
                }
            }
        }
    }

    private func preloadFollowing() async {
        let model = following.model(bridge)
        if model.items.isEmpty || model.isStale { await model.loadMore() }
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            for item in model.items.prefix(6) {
                if let url = item.cover.flatMap(URL.init(string:)) {
                    group.addTask { _ = await ImageCache.shared.load(url) }
                }
            }
        }
    }

    /// 点页签只切页，不再顺手刷新（点顶部会误触成「刷新视频」）。
    /// 要换一批推荐走「更多 → 刷新推荐」。
    private func selectTab(_ target: DYTab) {
        guard tab != target else { return }
        tab = target
    }

    /// 先拉到新一批再替换，失败不清空当前画面；与预取互斥，避免旧请求覆盖刷新结果。
    @MainActor private func refreshRecommendations() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; focusCurrent() }
        while feed.loading {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        // 管线作废在途请求、清空候选，紧急拉新一批；拿到才替换播放列表
        guard await feed.refresh(bridge), !Task.isCancelled else {
            DYLiveModel.log("DDREFRESH failed kept=\(currentID ?? "-")")
            return
        }
        let fresh = feed.items
        showComments = false
        scrollEndTask?.cancel(); userScrolling = false
        preloader.clear()
        resume = [:]
        currentID = fresh.first?.id
        scrollID = currentID
        saveSession()
        DYLiveModel.log("DDREFRESH ok n=\(fresh.count) first=\(currentID ?? "-")")
    }

    private func focusCurrent() {
        guard !refreshing, let i = currentIndex else { return }
        preloader.update(feed.items, current: i)
        let curID = feed.items[i].id
        let ahead = Array(feed.items.dropFirst(i + 1))
        let currentItem = feed.items[i]
        Task {
            await DYVideoCache.shared.markWatched(curID)
            await DYVideoCache.shared.focus(current: currentItem, ahead: ahead)
        }
        // Forward Buffer 不够就从共享候选池补；待播（列表 + 池）少于 8 条时管线在后台补到 20 条
        feed.supply(bridge, current: curID)
    }

    /// 后台补充往播放列表里加了新条目：刷新预加载（最多 3 个 AVPlayer）/ 磁盘缓存窗口
    private func refreshWindows() {
        guard !refreshing, let j = currentIndex else { return }
        preloader.update(feed.items, current: j)
        let cur = feed.items[j], ahead = Array(feed.items.dropFirst(j + 1))
        Task { await DYVideoCache.shared.focus(current: cur, ahead: ahead) }
    }

    @ViewBuilder
    private var feedArea: some View {
        ZStack(alignment: .top) {
            if tab == .live {
                DYLiveFeed(bridge: bridge, model: live, onWeb: { u in web = DYWebTarget(url: u) }, active: web == nil && !overlayOpen)
            } else if tab == .follow {
                DYFollowFeed(bridge: bridge, insets: insets, model: following, active: tab == .follow && web == nil && !overlayOpen,
                             showComments: $showFollowComments,
                             onAuthor: { a in authorTarget = a.author },
                             onLogin: { web = DYWebTarget(url: DouyinWeb.home) },
                             onToast: { showToast($0) },
                             onLive: { r in live.open(r); selectTab(.live) })
            } else {
                recommendArea
            }
            if let t = feed.toast {
                Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("douyin.toast")
            }
            #if DEBUG
            // UI 测试锚点：当前视频 id
            Text(currentID ?? "-").font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.currentID")
                .allowsHitTesting(false)
            #endif
        }
        // 顶栏要压在系统状态栏那一行，所以整块忽略顶部安全区；
        // 外屏左右有侧边控制区，安全区会把顶栏整行往左挤，所以水平方向也忽略（视频本来就铺满）
        .ignoresSafeArea(edges: [.top, .horizontal])
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { insets = geo.safeAreaInsets
                    }
                    .onChange(of: geo.safeAreaInsets) { _, v in insets = v }
            }
        }
        .onChange(of: tab) { _, t in
            if t == .recommend { focusCurrent() } else { preloader.clear() }
            if t != .live { live.stop() }
        }
        .fullScreenCover(isPresented: $showSearch) {
            DYSearchScreen(bridge: bridge, onAuthor: { a in authorTarget = a.author })
        }
        .fullScreenCover(isPresented: $showMine) {
            DYMineScreen(bridge: bridge,
                         onLogin: { showMine = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: DouyinWeb.home) } },
                         onAuthor: { a in authorTarget = a.author })
        }
        .sheet(item: $authorTarget) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: { u in web = DYWebTarget(url: u) })
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }

    }

    /// 顶部一排：左菜单，中间 关注/推荐/直播，右边 搜索 / 我的
    /// 顶栏：只留「关注 / 推荐 / 直播」三个纯文字页签，不用胶囊，与状态栏时间/信号同一行。
    /// 自适应仅收紧间距；消息与头像入口始终保留最小触摸区。
    private var topBar: some View {
        Group {
            if hSize == .compact {
                compactTopBar
            } else {
                ViewThatFits(in: .horizontal) {
                    topBarRow(spacing: topNudge > 0 ? 5 : 14, hPad: 16)
                    topBarRow(spacing: 0, hPad: 10)
                    topBarRow(spacing: 0, hPad: 5)
                }
            }
        }
        .themeShadow(.mediaLabel)
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.trailing, topNudge)
    }

    /// 外屏顶栏（仿 TikTok）：左 直播图标 ｜ 中 可横滑文字栏（靠右，「推荐」贴最右，左缘渐隐）｜ 右 搜索
    private var compactTopBar: some View {
        HStack(spacing: 0) {
            Button { selectTab(.live) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 21, weight: tab == .live ? .bold : .medium))
                    Capsule().fill(.white).frame(width: 18, height: 2).opacity(tab == .live ? 1 : 0)
                }
                .foregroundStyle(.white.opacity(tab == .live ? 1 : 0.9))
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("直播").accessibilityIdentifier("douyin.tab.live")

            GeometryReader { g in
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        compactEntry("我的", selected: false, id: "douyin.mine.top") { showMine = true }
                        compactEntry("消息", selected: false, dot: noticeUnread > 0, id: "douyin.messages.top") { showMessages = true }
                        compactEntry(DYTab.follow.title, selected: tab == .follow, id: "douyin.tab.follow") { selectTab(.follow) }
                        compactEntry(DYTab.recommend.title, selected: tab == .recommend, loading: refreshing, id: "douyin.tab.recommend") {
                            selectTab(.recommend)
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            selectTab(.recommend); Task { await refreshRecommendations() }
                        })
                    }
                    .padding(.horizontal, 6)
                    // 内容不满一行时也靠右，和 TikTok 一样当前页签贴着搜索
                    .frame(minWidth: g.size.width, alignment: .trailing)
                }
                .defaultScrollAnchor(.trailing)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                        Color.black
                    }
                }
            }
            .frame(height: 44)

            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("搜索").accessibilityIdentifier("douyin.search")
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    private func compactEntry(_ title: String, selected: Bool, dot: Bool = false, loading: Bool = false,
                              id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: selected ? .bold : .semibold))
                    .lineLimit(1).fixedSize()
                    .opacity(loading ? 0 : 1)
                    .overlay { if loading { ProgressView().tint(.white) } }
                    .overlay(alignment: .topTrailing) {
                        if dot { Circle().fill(.red).frame(width: 7, height: 7).offset(x: 6, y: -2) }
                    }
                Capsule().fill(.white).frame(width: 22, height: 2.5).opacity(selected ? 1 : 0)
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func topBarRow(spacing: CGFloat, hPad: CGFloat) -> some View {
        // 触摸区左右各扩 hPad、上下各扩 14（图标与字号不动）
        HStack(spacing: spacing) {
            ForEach(DYTab.allCases, id: \.self) { t in
                Button { selectTab(t) } label: {
                    VStack(spacing: 3) {
                        Text(t.title)
                            .font(.headline.weight(tab == t ? .bold : .medium))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(tab == t ? 1 : 0.62))
                            .lineLimit(1).fixedSize()
                            .opacity(t == .recommend && refreshing ? 0 : 1)
                            .overlay {
                                if t == .recommend && refreshing {
                                    ProgressView().tint(theme.media.onMedia.color(for: scheme))
                                        .accessibilityLabel("正在刷新推荐")
                                }
                            }
                        Capsule()
                            .fill(theme.media.onMedia.color(for: scheme))
                            .frame(width: 16, height: 3)
                            .opacity(tab == t ? 1 : 0)
                    }
                    // 文字本身小，撑开触摸区，避免点不中/误判成下拉
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    guard t == .recommend else { return }
                    selectTab(.recommend)
                    Task { await refreshRecommendations() }
                })
            }
            // 消息只留图标，未读红点仍独立显示。
            Button { showMessages = true } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                .padding(.horizontal, hPad)
                .padding(.vertical, 14)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if noticeUnread > 0 {
                        Circle().fill(theme.status.danger.color(for: scheme))
                            .frame(width: 7, height: 7)
                            .offset(x: -(hPad - 2), y: 10)
                            .allowsHitTesting(false)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("消息")
            .accessibilityIdentifier("douyin.messages.top")

            // 「我的」：独立按钮（不属于 tab 切换）
            Button { showMine = true } label: {
                HStack(spacing: 5) {
                    CachedAsyncImage(url: myUser?.avatar.flatMap(URL.init(string:))) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 19))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                }
                .padding(.horizontal, max(hPad - 2, 4))
                .padding(.vertical, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("我的")
            .accessibilityIdentifier("douyin.mine.top")
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(theme.media.onMedia.color(for: scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")
            .accessibilityIdentifier("douyin.search")
        }
        .fixedSize()
    }

    private func topIcon(_ name: String, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name)
                .font(.system(size: theme.typography.pointSize(.headline), weight: .semibold))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 顶栏「消息」。样式跟现有 topIcon，红暴液态按钮合并后会一起换。
    private var messageEntry: some View {
        topIcon("bell", "douyin.messages") { showMessages = true }
            .overlay(alignment: .topTrailing) {
                if noticeUnread > 0 {
                    Circle().fill(theme.status.danger.color(for: scheme))
                        .frame(width: 8, height: 8)
                        .offset(x: -6, y: 6)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("douyin.messages.badge")
                }
            }
    }

    /// 顶部「关注 / 推荐 / 直播」切换（抖音顶栏同款位置）
    private var tabSwitcher: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        return HStack(spacing: 14) {
            ForEach(DYTab.allCases, id: \.self) { t in
                Button { selectTab(t) } label: {
                    VStack(spacing: 4) {
                        Text(t.title)
                            .font(.headline.weight(tab == t ? .bold : .medium))
                            .foregroundStyle(fg.opacity(tab == t ? 1 : 0.6))
                            .lineLimit(1)
                            .fixedSize()
                        Capsule().fill(fg).frame(width: 18, height: 3).opacity(tab == t ? 1 : 0)
                    }
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var recommendArea: some View {
        ZStack(alignment: .topLeading) {
            if feed.items.isEmpty {
                VStack(spacing: WuWeiDesign.Spacing.md) {
                    if let e = feed.error {
                        Text(e).font(.footnote).multilineTextAlignment(.center)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        HStack {
                            Button("重试") { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id } }
                                .buttonStyle(.borderedProminent)
                            Button("打开网页版") { web = DYWebTarget(url: DouyinWeb.home) }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView().tint(theme.media.onMedia.color(for: scheme))
                        Text(bridge.ready ? "加载推荐…" : "连接抖音…").font(.footnote)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(feed.items) { item in
                            page(for: item)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollID, anchor: .center)
                .onAppear { scrollID = currentID }
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            if !userScrolling { dragStartID = currentID }
                            scrollEndTask?.cancel(); userScrolling = true
                        }
                    }
                    .onEnded { _ in
                        // 下拉不再触发刷新（顶部点击/轻扫会误判成刷新）；刷新走「更多 → 刷新推荐」。
                        dragStartID = nil
                        scrollEndTask = Task {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            if !Task.isCancelled { userScrolling = false }
                        }
                    })
                .onChange(of: scrollID) { _, id in
                    guard let id, feed.items.contains(where: { $0.id == id }) else { return }
                    if userScrolling { currentID = id }
                    else if id != currentID { scrollID = currentID }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }
        }
    }

    /// 单页构造拆成独立函数：参数太多，写在 ForEach 里会让类型检查超时。
    private func page(for item: DYAweme) -> some View {
        let extras = AnyView(moreExtrasMenu(item))
        let active = item.id == currentID && web == nil && tab == .recommend && !overlayOpen
        return DYVideoPage(item: item,
                           isCurrent: active,
                           insets: insets,
                           resume: resume[item.id],
                           liked: feed.liked.contains(item.id),
                           collected: feed.collected.contains(item.id),
                           onLike: { toggleLike(item.id, force: nil) },
                           onCollect: { toggleCollect(item.id) },
                           onDoubleTap: { toggleLike(item.id, force: true) },
                           onComments: { withAnimation(.snappy) { showComments.toggle() } },
                           onSearch: { showSearch = true },
                           onAuthor: { authorTarget = item.author },
                           onSavePosition: { resume[item.id] = $0; saveSession() },
                           preloader: preloader,
                           bridge: bridge,
                           onToast: { showToast($0) },
                           onDislike: { dislike(item.id) },
                           moreExtras: extras,
                           onEnded: { playNext(after: item.id) },
                           onSwipeRightOverride: showComments ? { withAnimation(.snappy) { showComments = false } } : nil)
    }

    /// 点赞：先本地乐观更新，再调抖音网页接口，按服务端返回决定成败
    /// （不用 cookie 判断登录态：sessionid 是 HttpOnly，document.cookie 读不到，会误判成未登录）
    private func toggleLike(_ id: String, force: Bool?) {
        let has = feed.liked.contains(id)
        let want = force ?? !has
        guard want != has else { return }
        if want { feed.liked.insert(id) } else { feed.liked.remove(id) }
        Task {
            do {
                switch try await bridge.digg(id, like: want) {
                case .ok:
                    break
                case .notLoggedIn:
                    await MainActor.run {
                        if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                        showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                        showToast("点赞失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT digg ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                    showToast("点赞失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 不感兴趣：立刻从列表拿掉并切到下一条，后台告诉抖音（失败只提示，不把视频塞回来）
    private func dislike(_ id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        let next = i + 1 < feed.items.count ? feed.items[i + 1].id : (i > 0 ? feed.items[i - 1].id : nil)
        scrollEndTask?.cancel(); userScrolling = false
        showComments = false
        if currentID == id { currentID = next; scrollID = next }
        feed.items.remove(at: i)
        resume[id] = nil
        saveSession()
        showToast("将减少此类推荐")
        Task {
            await DYVideoCache.shared.markWatched(id)
            do {
                switch try await bridge.dislike(id) {
                case .ok: break
                case .notLoggedIn: showToast("抖音未登录，「不感兴趣」没同步到账号")
                case .failed(let why): showToast("「不感兴趣」同步失败：\(why)")
                }
            } catch {
                showToast("「不感兴趣」同步失败：\(error.localizedDescription)")
            }
        }
        if next == nil { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id; scrollID = currentID } }
    }

    /// 收藏 / 取消收藏（同步到抖音账号的「收藏」）
    private func toggleCollect(_ id: String) {
        let has = feed.collected.contains(id)
        let want = !has
        if want { feed.collected.insert(id) } else { feed.collected.remove(id) }
        Task {
            do {
                switch try await bridge.favorite(id, add: want) {
                case .ok:
                    await MainActor.run { showToast(want ? "已收藏" : "已取消收藏") }
                case .notLoggedIn:
                    await MainActor.run {
                        if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                        showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                        showToast("收藏失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT fav ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                    showToast("收藏失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func showToast(_ s: String) {
        feed.toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if feed.toast == s { feed.toast = nil }
        }
    }

    /// 当前作品操作留在第一层，全局偏好统一收进设置。
    @ViewBuilder
    private func moreExtrasMenu(_ item: DYAweme) -> some View {
        Section {
            Button("刷新推荐", systemImage: "arrow.clockwise") {
                Task { await refreshRecommendations() }
            }
            .disabled(refreshing)
            Menu {
                Menu {
                    Toggle(isOn: $autoNext) { Label("自动连播", systemImage: "play.square.stack") }
                    Toggle(isOn: $muted) { Label("静音", systemImage: "speaker.slash") }
                } label: { Label("播放设置", systemImage: "play.circle") }
                Picker(selection: $feed.aspectPreference) {
                    ForEach(DYRecommendationAspect.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                } label: { Label("推荐视频比例", systemImage: "aspectratio") }
                .pickerStyle(.menu)
                .accessibilityIdentifier("douyin.recommendation.aspect")
                Menu {
                    Picker(selection: $cacheCount) {
                        Text("5 条").tag(5)
                        Text("10 条").tag(10)
                        Text("20 条").tag(20)
                        Text("50 条").tag(50)
                        Text("100 条").tag(100)
                        Text("关闭").tag(0)
                    } label: { Label("预缓存数量", systemImage: "arrow.down.circle") }
                    .pickerStyle(.menu)
                    Button("清除视频缓存", systemImage: "trash") {
                        Task {
                            let b = await DYVideoCache.shared.clear()
                            showToast("已清除 \(b / 1024 / 1024) MB")
                            focusCurrent()
                        }
                    }
                } label: { Label("缓存管理", systemImage: "internaldrive") }
                Menu {
                    Button("官网 / 登录（备用入口）", systemImage: "safari") { web = DYWebTarget(url: DouyinWeb.home) }
                } label: { Label("账号与登录", systemImage: "person.crop.circle") }
                Menu {
                    Button {
                        UIApplication.shared.open(DDUpdateChecker.repoURL)
                    } label: {
                        Label("开源仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("douyin.about")
                } label: { Label("关于", systemImage: "info.circle") }
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

struct DYWebTarget: Identifiable { let id = UUID(); let url: URL }

enum DYTab: CaseIterable { case follow, recommend, live
    var title: String {
        switch self {
        case .follow: "关注"
        case .recommend: "推荐"
        case .live: "直播"
        }
    }
}

// MARK: - 单页

struct DYVideoPage: View {
    @Environment(\.horizontalSizeClass) private var hSize
    private var railWidth: CGFloat { hSize == .compact ? 50 : 54 }
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let item: DYAweme
    let isCurrent: Bool
    let insets: EdgeInsets
    let resume: Double?
    let liked: Bool
    let collected: Bool
    let onLike: () -> Void
    let onCollect: () -> Void
    let onDoubleTap: () -> Void
    let onComments: () -> Void
    let onSearch: () -> Void
    let onAuthor: () -> Void
    let onSavePosition: (Double) -> Void
    let preloader: DYPreloader
    let bridge: DouyinBridge?
    let onToast: ((String) -> Void)?
    /// 只有推荐流传：关注 / 搜索 / 我的 里不显示「不感兴趣」
    let onDislike: (() -> Void)?
    /// 「更多」菜单末尾追加的条目（消息 / 我的 / 设置），由推荐流注入
    var moreExtras: AnyView = AnyView(EmptyView())
    /// 播完切下一条（「自动连播」打开才生效）
    var onEnded: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    var onSwipeLeftOverride: (() -> Void)? = nil
    var onSwipeRightOverride: (() -> Void)? = nil
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @State private var heart = false
    @State private var danmaku: [DYDanmaku] = []
    @State private var danmakuLoaded = false
    @State private var saving = false
    @State private var showShare = false
    @State private var showDanmakuInput = false
    @AppStorage("douyin_rate_v1") private var lockedRate = 1.0
    @AppStorage("douyin_bg_play_v1") private var bgPlay = false
    @State private var danmakuDraft = ""
    @State private var danmakuSending = false
    @FocusState private var danmakuFocused: Bool
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    /// 外屏评论打开、视频缩到面板上方时只留画面
    @Environment(\.dyCommentsDocked) private var docked

    init(item: DYAweme, isCurrent: Bool, insets: EdgeInsets, resume: Double?, liked: Bool, collected: Bool,
         onLike: @escaping () -> Void, onCollect: @escaping () -> Void, onDoubleTap: @escaping () -> Void,
         onComments: @escaping () -> Void, onSearch: @escaping () -> Void, onAuthor: @escaping () -> Void, onSavePosition: @escaping (Double) -> Void,
         preloader: DYPreloader, bridge: DouyinBridge? = nil, onToast: ((String) -> Void)? = nil,
         onDislike: (() -> Void)? = nil, moreExtras: AnyView = AnyView(EmptyView()),
         onEnded: (() -> Void)? = nil, onBack: (() -> Void)? = nil,
         onSwipeLeftOverride: (() -> Void)? = nil, onSwipeRightOverride: (() -> Void)? = nil) {
        self.item = item; self.isCurrent = isCurrent; self.insets = insets; self.resume = resume
        self.liked = liked; self.collected = collected
        self.onLike = onLike; self.onCollect = onCollect; self.onDoubleTap = onDoubleTap
        self.onComments = onComments; self.onSearch = onSearch; self.onAuthor = onAuthor; self.onSavePosition = onSavePosition
        self.preloader = preloader; self.bridge = bridge; self.onToast = onToast
        self.onDislike = onDislike
        self.moreExtras = moreExtras
        self.onEnded = onEnded
        self.onBack = onBack
        self.onSwipeLeftOverride = onSwipeLeftOverride
        self.onSwipeRightOverride = onSwipeRightOverride
    }

    var body: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        ZStack(alignment: .bottomLeading) {
            if item.images.isEmpty, let s = item.play, let remote = URL(string: s) {
                // 只用「整条缓存」或「在线流」：不再走头部缓存 + 接续（那一下切换必然闪/卡）
                let url = DYVideoCache.localURL(item.id) ?? remote
                // 复用影库播放器：横滑快进（带预览缩略图）、双击、长按 2 倍速、竖滑切视频、底部可拖进度条、VLC 兜底
                PlayerPage.external(id: item.id, title: item.desc, url: url, durationSec: item.duration,
                                    isActive: isCurrent, topInset: insets.top, bottomInset: insets.bottom,
                                    resumePosition: resume, compactChrome: true,
                                    preparedPlayer: { preloader.take(item.id) },
                                    onEnded: autoNext ? onEnded : nil,
                                    onDoubleTap: {
                                        onDoubleTap()
                                        heart = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { heart = false }
                                    },
                                    onSavePosition: onSavePosition, onClose: {}, fillWidth: hSize == .compact && item.isTallFrame,
                                    danmaku: danmakuOn ? danmaku : [],
                                    altURL: item.playAlt.flatMap(URL.init(string:)),
                                    quality: item.q,
                                    fastURL: item.playFast.flatMap(URL.init(string:)),
                                    posterURL: item.cover.flatMap(URL.init(string:)),
                                    videoAspect: item.height > 0 ? item.width / item.height : 0,
                                    headEndSeconds: nil,
                                    continuationURL: nil,
                                    onSwipeLeft: { if isCurrent { (onSwipeLeftOverride ?? onAuthor)() } },
                                    onSwipeRight: onSwipeRightOverride,
                                    // 外屏竖视频铺满（左右裁一点、居中），不再贴左
                                    fillCropLimit: hSize == .compact ? 0.3 : 0.18)
            } else {
                DYImagePostView(item: item, isCurrent: isCurrent, bottomInset: insets.bottom,
                                onEnded: autoNext ? onEnded : nil,
                                preparedMusic: { preloader.take(item.id) })
            }

            VStack {
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: hSize == .compact ? 230 : 170)
            }
            .opacity(docked ? 0 : 1)
            .allowsHitTesting(false)
            if heart {
                Image(systemName: "heart.fill")
                    .font(.system(size: theme.typography.pointSize(.splash)))
                    .scaleEffect(1.7)
                    .foregroundStyle(theme.status.danger.color(for: scheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // 左下信息贴近进度条；右侧按钮维持原高度，不跟随标题下移。
            HStack(alignment: .bottom, spacing: 12) {
                info(fg)
                Spacer(minLength: 0)
                actions(fg)
                    .modifier(DYRailReservedNudge())
                    // 外屏：按钮栏往右贴（列中心距右缘约 35pt，原来约 48pt）
                    .offset(x: hSize == .compact ? 4 : 0)
                    // 按钮栏固定高度：图集这一行底部少 12pt，这里补回去，视频/图集切换时按钮不跳
                    .padding(.bottom, item.images.isEmpty ? 56 : 68)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, max(insets.bottom, 18) + (item.images.isEmpty ? 36 : 24))
            .opacity(docked ? 0 : 1)
            .allowsHitTesting(!docked)
        }
        .overlay(alignment: .bottom) {
            if showDanmakuInput { danmakuBar.padding(.bottom, max(insets.bottom, 12) + 6) }
        }
        .fullScreenCover(isPresented: $showShare) {
            DYForwardScreen(item: item).presentationBackground(.clear)
        }
        .animation(.snappy, value: heart)
        .animation(.snappy, value: docked)
        .onChange(of: isCurrent) { _, c in if !c { showDanmakuInput = false } }
        .onChange(of: docked) { _, d in if d { showDanmakuInput = false } }
        .task(id: isCurrent) {
            guard isCurrent, let bridge else { return }
            // Skip videos the user flicks past; never await this work before playback.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            async let comments = try? bridge.fetchComments(item.id, cursor: 0)
            if let sec = item.author.secUid, !sec.isEmpty { await bridge.prefetchCreator(sec) }
            _ = await comments
        }
        // 弹幕：轮到这条时才拉（一次拉整条视频的）
        .task(id: isCurrent) {
            guard isCurrent, !danmakuLoaded, item.images.isEmpty, let b = bridge else { return }
            danmakuLoaded = true
            do {
                danmaku = try await b.danmaku(item.id, durationMs: Int(item.duration * 1000))
                DYLiveModel.log("DDDM id=\(item.id) n=\(danmaku.count) first=\(danmaku.first.map { "\($0.offset)s \($0.text)" } ?? "-")")
            } catch {
                DYLiveModel.log("DDDM id=\(item.id) error=\(error)")
            }
        }
    }

    private var danmakuBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $danmakuDraft, prompt: Text("发个弹幕见证当下").foregroundStyle(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .focused($danmakuFocused)
                .submitLabel(.send)
                .onSubmit { sendDanmaku() }
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(.black.opacity(0.6)))
                .accessibilityIdentifier("douyin.danmaku.input")
            Button(action: sendDanmaku) {
                if danmakuSending { ProgressView().tint(.white) }
                else { Text("发送").font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(theme.accent.color(for: scheme)))
            .disabled(danmakuDraft.trimmingCharacters(in: .whitespaces).isEmpty || danmakuSending)
            .accessibilityIdentifier("douyin.danmaku.send")
            Button { showDanmakuInput = false; danmakuFocused = false } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 40)
            }
        }
        .padding(.horizontal, 12)
    }

    private func sendDanmaku() {
        let text = danmakuDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !danmakuSending, let b = bridge else { return }
        danmakuSending = true
        let at = DDNowPlaying.id == item.id ? DDNowPlaying.time : 0
        Task {
            do {
                let id = try await b.postDanmaku(item.id, text: text, offset: at)
                // 自己发的立刻上屏（从当前时间点开始飘）
                danmaku.append(DYDanmaku(id: id, text: text, offset: at + 0.3))
                danmaku.sort { $0.offset < $1.offset }
                danmakuDraft = ""
                showDanmakuInput = false
                danmakuFocused = false
                onToast?("弹幕已发送")
            } catch {
                onToast?("弹幕发送失败：\(error.localizedDescription)")
            }
            danmakuSending = false
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        onToast?("正在保存…")
        Task {
            do {
                try await DYSaver.save(item)
                onToast?(item.images.isEmpty ? "视频已保存到相册" : "图集已保存到相册")
            } catch {
                onToast?("保存失败：\(error.localizedDescription)")
            }
            saving = false
        }
    }

    /// 左下保留作者昵称与文案；作者头像放在右侧操作栏顶部。
    private func info(_ fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: onAuthor) {
                    Text(item.author.name).font(.footnote.weight(.semibold)).foregroundStyle(fg).lineLimit(1)
                        .frame(minHeight: 26, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.author")
            }
            if let metadata = item.metadataText() {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("douyin.video.metadata")
            }
            if !item.desc.isEmpty {
                DYExpandableTitle(text: item.desc, foreground: fg,
                                  secondary: theme.media.onMediaSecondary.color(for: scheme))
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
        .themeShadow(.mediaLabel)
    }

    /// 小红书式右侧栏：一根竖向液态玻璃胶囊（赞 / 评论 / 收藏 / 搜索，数字在图标下），下方单独一颗「更多」圆按钮
    private func actions(_ fg: Color) -> some View {
        VStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(fg)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
                .ddGlassCapsule()
                .accessibilityLabel("返回上一层")
                .accessibilityIdentifier("douyin.list.back")
            }
            Button(action: onAuthor) {
                CachedAsyncImage(url: item.author.avatar.flatMap(URL.init(string:))) { img in
                    img.resizable().scaledToFill()
                } placeholder: { theme.media.chromeFill.color(for: scheme) }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().stroke(fg.opacity(0.9), lineWidth: 1))
                .frame(width: 54, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(item.author.name)的主页")
            .accessibilityIdentifier("douyin.author.avatar")
            // 抖音 / TikTok 同款：没关注时头像底部压一个红色「+」，点了关注 →「✓」→ 消失
            .overlay(alignment: .bottom) {
                if let bridge { DYFollowBadge(author: item.author, bridge: bridge, onToast: onToast).offset(y: 5) }
            }
            .padding(.bottom, 6)
            VStack(spacing: 6) {
                railItem(liked ? "heart.fill" : "heart", DYFormat.count(item.stats.digg + (liked ? 1 : 0)),
                         tint: liked ? theme.status.danger.color(for: scheme) : fg, "douyin.like", onLike)
                railItem("ellipsis.bubble", DYFormat.count(item.stats.comment), tint: fg, "douyin.comments", onComments)
                railItem(collected ? "star.fill" : "star", DYFormat.count(item.stats.collect + (collected ? 1 : 0)),
                         tint: collected ? theme.status.warning.color(for: scheme) : fg, "douyin.collect", onCollect)
                railItem("arrowshape.turn.up.right", "", tint: fg, "douyin.share", { showShare = true })
            }
            .padding(.vertical, 8)
            .frame(width: railWidth)
            .frame(width: 54) // 保留列中心，与右侧系统信号栏竖直对齐
            moreMenu(fg)
        }
        .themeShadow(.mediaLabel)
    }

    private func railItem(_ icon: String, _ text: String, tint: Color, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(height: 28)
                if !text.isEmpty {
                    Text(text).font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: railWidth, height: text.isEmpty ? 44 : 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 「更多」：转发 / 下载快捷入口 → 不感兴趣 → 弹幕 → 刷新推荐 / 设置。
    @ViewBuilder
    private func moreMenu(_ fg: Color) -> some View {
        Menu {
            ControlGroup {
                Button {
                    save()
                } label: {
                    Label(saving ? "保存中…" : "下载", systemImage: "arrow.down.to.line")
                }
                .disabled(saving)
                .accessibilityIdentifier("douyin.save")
            }
            if let onDislike {
                Button("不感兴趣", systemImage: "hand.thumbsdown", role: .destructive) { onDislike() }
                    .accessibilityIdentifier("douyin.dislike")
            }
            if item.images.isEmpty {
                // 锁定倍速：选了之后每个视频都按这个速度放，直到改回正常
                Picker("倍速", selection: $lockedRate) {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Text(r == 1 ? "正常速度" : String(format: "%g 倍速", r)).tag(r)
                    }
                }
                Toggle("后台播放（听书）", systemImage: "headphones", isOn: $bgPlay)
                DYDanmakuOptions(onSend: bridge == nil ? nil : {
                    showDanmakuInput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { danmakuFocused = true }
                })
            }
            moreExtras
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .frame(width: 54)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.more")
    }

}

/// 本次运行里在 DouDuo 点过的关注（作者 uid → 是否关注）。同一作者的多条视频共用，点一次其它条的「+」也跟着消失。
@MainActor final class DYFollowStore: ObservableObject {
    static let shared = DYFollowStore()
    /// 以 uid 和 sec_uid 双键记录（推荐流条目、作者页手里拿到的标识不一定相同）
    @Published private var state: [String: Bool] = [:]

    func isFollowing(_ author: DYAweme.Author) -> Bool? {
        author.uid.flatMap { state[$0] } ?? author.secUid.flatMap { state[$0] }
    }

    func set(_ followed: Bool, uid: String?, sec: String?) {
        for key in [uid, sec].compactMap({ $0 }) where !key.isEmpty { state[key] = followed }
    }
}

/// 抖音 / TikTok 同款：没关注时头像底部压一个红色「+」，点了关注 →「✓」→ 消失。
/// 单独成 View：只有它观察 DYFollowStore，点关注不会让整页视频重绘。
struct DYFollowBadge: View {
    let author: DYAweme.Author
    let bridge: DouyinBridge
    let onToast: ((String) -> Void)?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var follows = DYFollowStore.shared
    @State private var busy = false
    /// 刚点完关注：先显示 ✓，一会儿再收起
    @State private var justFollowed = false

    private var isFollowing: Bool { follows.isFollowing(author) ?? ((author.follow ?? 0) > 0) }
    private var isSelf: Bool { author.secUid != nil && author.secUid == bridge.selfSecCache }

    var body: some View {
        let red = theme.status.danger.color(for: scheme)
        if (author.uid ?? author.secUid) != nil, !isSelf, !isFollowing || justFollowed {
            Button { Task { await follow() } } label: {
                ZStack {
                    Circle().fill(justFollowed ? Color.white : red)
                    if busy && !justFollowed {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: justFollowed ? "checkmark" : "plus")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(justFollowed ? red : .white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 18, height: 18)
                .frame(width: 32, height: 28)   // 触摸区比圆点大
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(justFollowed ? "已关注" : "关注\(author.name)")
            .accessibilityIdentifier("douyin.author.followBadge")
        }
    }

    /// 乐观更新：先变 ✓，失败再变回 + 并提示
    private func follow() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var uid = author.uid
        if uid?.isEmpty ?? true, let sec = author.secUid { uid = try? await bridge.followState(sec: sec).uid }
        guard let uid, !uid.isEmpty else { onToast?("关注失败：没拿到作者信息"); return }
        withAnimation(.snappy) { justFollowed = true }
        follows.set(true, uid: uid, sec: author.secUid)
        let result: DYActionResult
        do { result = try await bridge.followUser(uid, follow: true) } catch { result = .failed(error.localizedDescription) }
        switch result {
        case .ok: try? await Task.sleep(for: .milliseconds(900))
        case .notLoggedIn: onToast?("抖音未登录：菜单 → 网页版 / 登录")
        case .failed(let why): onToast?("关注失败：\(why)")
        }
        if case .ok = result {} else { follows.set(false, uid: uid, sec: author.secUid) }
        withAnimation(.snappy) { justFollowed = false }
    }
}

// MARK: - 图文

/// 图文作品：抖音同款——自动翻页、背景音乐、底部圆点 + 「2/4」页码。
/// 手动左右滑会重新计时；开了「自动连播」时最后一张停留后切下一条，否则回到第一张循环。
struct DYImagePostView: View {
    let item: DYAweme
    let isCurrent: Bool
    let bottomInset: CGFloat
    let onEnded: (() -> Void)?
    /// 预加载器提前缓冲好的背景音乐（没有就现建）
    var preparedMusic: () -> AVPlayer? = { nil }
    /// 图片按这个像素上限在后台解码：够铺满手机屏（原图常是 2160×2880，整张懒解码会在翻页动画里卡主线程）
    static let maxPixel = 2400
    /// 每张停留秒数（单张图没有翻页，停久一点再连播）
    static let slideSeconds: Double = 3
    static let singleSeconds: Double = 5
    @AppStorage("douyin_muted_v1") private var muted = false
    @State private var page = 0
    @State private var music: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?
    @State private var playbackID = UUID()

    private var count: Int { item.images.count }

    /// 把一条图文的所有图片下好并在后台解码进内存缓存（预加载器和当前页共用）
    static func prefetchImages(_ item: DYAweme) {
        let urls = item.images.compactMap(URL.init(string:))
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls { group.addTask { _ = await ImageCache.shared.loadThumb(url, maxPixel: maxPixel) } }
            }
        }
    }

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(item.images.enumerated()), id: \.offset) { i, s in
                CachedAsyncImage(url: URL(string: s), thumbnailMaxPixel: Self.maxPixel) { img in img.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            if count > 1 { indicator.padding(.bottom, max(bottomInset, 10) + 8) }
        }
        .onChange(of: muted) { _, m in music?.isMuted = m }
        .onChange(of: isCurrent) { _, c in c ? startMusic() : stopMusic() }
        .onAppear { if isCurrent { startMusic() } }
        .onChange(of: isCurrent, initial: true) { _, c in if c { Self.prefetchImages(item) } }   // 冷启动直接落在这条时也补齐
        .onDisappear { stopMusic() }
        // 每换一页（自动或手滑）任务重启 → 重新计时；不是当前条就不跑
        .task(id: AdvanceKey(current: isCurrent, page: page)) { await autoAdvance() }
        .accessibilityIdentifier("douyin.imagePost")
    }

    /// 少于等于 10 张显示圆点（当前页加长成胶囊），再多只留页码，旁边始终带「当前/总数」
    private var indicator: some View {
        HStack(spacing: 8) {
            if count <= 10 {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule().fill(.white.opacity(i == page ? 1 : 0.45))
                            .frame(width: i == page ? 14 : 6, height: 6)
                    }
                }
            }
            Text("\(page + 1)/\(count)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.35)))
        .animation(.snappy, value: page)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(page + 1) 张，共 \(count) 张")
        .accessibilityIdentifier("douyin.imagePost.indicator")
    }

    private struct AdvanceKey: Equatable { let current: Bool; let page: Int }

    /// 当前页停留够时间就翻下一页；最后一页：开了自动连播切下一条，否则回第一张（单张图且不连播就停着）
    private func autoAdvance() async {
        guard isCurrent, count > 0, count > 1 || onEnded != nil else { return }
        do { try await Task.sleep(for: .seconds(count > 1 ? Self.slideSeconds : Self.singleSeconds)) } catch { return }
        if page + 1 < count {
            withAnimation(.easeInOut(duration: 0.35)) { page += 1 }
        } else if let onEnded {
            onEnded()
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { page = 0 }
        }
    }

    private func startMusic() {
        guard music == nil, let url = item.imageMusicURL else { return }
        // 优先用预加载器缓冲好的（滑到就有声）；跟视频同一套：抖音 UA / Referer 头、.playback 音频会话
        let p = preparedMusic() ?? AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(url)))
        p.isMuted = muted
        p.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero); p.play()
        }
        music = p
        // 切后台 / 锁屏跟视频一样停（开了后台播放除外）；离开这条时 stopMusic 会注销
        DDPlayback.shared.register(playbackID, stop: { p.pause() }, start: { p.play() })
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        p.play()
    }

    private func stopMusic() {
        if let o = loopObserver { NotificationCenter.default.removeObserver(o); loopObserver = nil }
        music?.pause()
        music = nil
        DDPlayback.shared.unregister(playbackID)
    }
}

enum DYFormat {
    static func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let i = Int(t.rounded(.down))
        return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i % 3600 / 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }
    static func count(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 1e8) }
        if n >= 10_000 { return String(format: "%.1fw", Double(n) / 1e4) }
        return "\(n)"
    }
    static func time(_ ts: Double) -> String {
        let d = Date().timeIntervalSince1970 - ts
        if d < 3600 { return "\(max(1, Int(d / 60)))分钟前" }
        if d < 86400 { return "\(Int(d / 3600))小时前" }
        if d < 86400 * 30 { return "\(Int(d / 86400))天前" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - 评论

struct DYCommentPanel: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let bridge: DouyinBridge
    let aweme: DYAweme
    let onClose: (() -> Void)?
    @State private var items: [DYComment] = []
    @State private var cursor = 0
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var replies: [String: [DYComment]] = [:]
    @State private var replyCursor: [String: Int] = [:]
    @State private var replyMore: [String: Bool] = [:]
    @State private var replyLoading: Set<String> = []
    @State private var replyErr: [String: String] = [:]
    @State private var draft = ""
    @State private var replyTo: DYComment?
    @State private var showEmoji = false
    @State private var showAt = false
    @State private var emojis: [DYEmoji] = []
    @State private var friends: [DYFriend] = []
    @State private var atLoading = false
    @State private var atError: String?
    @State private var sending = false
    @State private var sendErr: String?
    @State private var digged: Set<String> = []
    @State private var diggShown: [String: Int] = [:]
    @State private var relatedWords: [String] = []
    @State private var relatedQuery: DYRelatedQuery?
    @FocusState private var inputFocused: Bool

    init(bridge: DouyinBridge, aweme: DYAweme, onClose: (() -> Void)?) {
        self.bridge = bridge; self.aweme = aweme; self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(total > 0 ? "\(DYFormat.count(total)) 条评论" : "评论").font(.subheadline.weight(.semibold))
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭评论")
                        .accessibilityIdentifier("douyin.comments.close")
                }
            }
            .foregroundStyle(.themeTextPrimary)
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 10) {
                            row(c)
                            if c.replies > 0 { replyBlock(c) }
                        }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(theme.status.danger.color(for: scheme))
                        Button("重试") { self.error = nil; Task { await load() } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("douyin.comments.retry")
                    } else if hasMore {
                        ProgressView().frame(maxWidth: .infinity)
                            .task { await load() }
                    } else if items.isEmpty {
                        Text("还没有评论").font(.footnote).foregroundStyle(.themeTextSecondary).frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            if !relatedWords.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        Text("相关搜索").font(.caption).foregroundStyle(.themeTextSecondary)
                        ForEach(relatedWords, id: \.self) { word in
                            Button { relatedQuery = DYRelatedQuery(word: word) } label: {
                                Label(word, systemImage: "magnifyingglass")
                                    .font(.footnote).lineLimit(1)
                                    .foregroundStyle(theme.accent.color(for: scheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("douyin.comments.relatedSearch")
            }
            Divider()
            inputBar
        }
        .background(GlassBackground())
        // Match the user's verified official right-swipe-to-close behavior.
        .background(DYSwipeDismiss(direction: .right, enabled: onClose != nil && relatedQuery == nil) { onClose?() })
        .modifier(DYRailReservedNudge())
        .task(id: aweme.id) { relatedWords = await bridge.relatedSearch(for: aweme) }
        .fullScreenCover(item: $relatedQuery) { query in
            DYRelatedSearchScreen(bridge: bridge, word: query.word)
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showAt { atPanel }
            if let r = replyTo {
                HStack {
                    Text("回复 @\(r.name)").font(.caption).foregroundStyle(.themeTextSecondary).lineLimit(1)
                    Spacer()
                    Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.themeTextSecondary)
                }
            }
            if let e = sendErr {
                Text(e).font(.caption2).foregroundStyle(theme.status.danger.color(for: scheme))
            }
            HStack(spacing: 8) {
                Button {
                    showEmoji.toggle()
                    showAt = false
                    if showEmoji, emojis.isEmpty { Task { emojis = await bridge.emojiList() } }
                } label: {
                    Image(systemName: showEmoji ? "keyboard" : "face.smiling")
                        .font(.body).foregroundStyle(showEmoji ? theme.accent.color(for: scheme) : .themeTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.comment.emoji")
                Button {
                    showAt.toggle()
                    showEmoji = false
                    if showAt { Task { await loadFriends() } }
                } label: {
                    Image(systemName: "at").font(.body.weight(.medium))
                        .foregroundStyle(showAt ? theme.accent.color(for: scheme) : .themeTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.comment.at")
                TextField(replyTo == nil ? "说点什么…" : "回复 \(replyTo!.name)", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .accessibilityIdentifier("douyin.comment.input")
                Button { Task { await send() } } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill").font(.body.weight(.semibold)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : theme.accent.color(for: scheme))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityIdentifier("douyin.comment.send")
            }
            if showEmoji {
                if emojis.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("加载表情…").font(.caption2).foregroundStyle(.themeTextSecondary)
                    }
                    .frame(height: 60)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                            ForEach(emojis) { e in
                                Button { draft += e.displayName } label: {
                                    CachedAsyncImage(url: e.url.flatMap(URL.init(string:))) { img in
                                        img.resizable().scaledToFit()
                                    } placeholder: { Color.clear }
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 150)
                    .accessibilityIdentifier("douyin.comment.emojis")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .task { await DYEmojiStore.shared.load(bridge: bridge) }
    }

    /// 拉「我关注的人」给 @ 面板用
    private func loadFriends() async {
        guard friends.isEmpty, !atLoading else { return }
        atLoading = true
        defer { atLoading = false }
        do {
            let r = try await bridge.followingUsers()
            friends = r.items
            atError = r.items.isEmpty ? "没拿到关注列表（可能未登录）" : nil
        } catch {
            atError = "关注列表加载失败：\(error.localizedDescription)"
        }
    }

    /// @ 面板：优先「我关注的人」，拿不到时退回本视频评论区里的人
    @ViewBuilder
    private var atPanel: some View {
        let people: [DYFriend] = friends.isEmpty
            ? atCandidates.map { DYFriend(name: $0.name, avatar: $0.avatar, secUid: $0.id) }
            : friends
        // 跟抖音一致：输入框上方一排头像 + 昵称，横滑
        VStack(alignment: .leading, spacing: 4) {
            if atLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载朋友…").font(.caption2).foregroundStyle(.themeTextSecondary)
                }
                .padding(.vertical, 8)
            } else if people.isEmpty {
                Text(atError ?? "没有可 @ 的人").font(.caption2).foregroundStyle(.themeTextSecondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(people, id: \.id) { u in
                            Button {
                                draft += "@\(u.name) "
                                showAt = false
                                inputFocused = true
                            } label: {
                                VStack(spacing: 5) {
                                    CachedAsyncImage(url: u.avatar.flatMap(URL.init(string:))) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: { Color.primary.opacity(0.08) }
                                    .frame(width: 50, height: 50).clipShape(Circle())
                                    Text(u.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.themeTextPrimary)
                                        .lineLimit(1)
                                        .frame(width: 56)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                }
                .frame(height: 92)
            }
        }
        .padding(.top, 2)
    }

    /// @ 候选：评论作者 + 楼中楼作者，去重
    private var atCandidates: [DYComment] {
        var seen = Set<String>()
        var out: [DYComment] = []
        for c in items {
            if seen.insert(c.name).inserted { out.append(c) }
            for r in replies[c.id] ?? [] where seen.insert(r.name).inserted { out.append(r) }
        }
        return Array(out.prefix(30))
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let c = try await bridge.publishComment(aweme.id, text: text, replyID: replyTo?.id)
            if let parent = replyTo {
                replies[parent.id, default: []].insert(c, at: 0)
            } else {
                items.insert(c, at: 0)
                total += 1
            }
            draft = ""; replyTo = nil; sendErr = nil
            inputFocused = false
        } catch {
            sendErr = "发送失败：\(error.localizedDescription)"
        }
    }

    private func row(_ c: DYComment) -> some View {
        rowBody(c)
            .contentShape(Rectangle())
            .onTapGesture { replyTo = c; inputFocused = true }
    }

    private func rowBody(_ c: DYComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: c.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.08) }
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(c.name).font(.caption.weight(.semibold)).foregroundStyle(.themeTextSecondary)
                if !c.text.isEmpty {
                    DYEmojiStore.shared.rich(c.text).font(.subheadline).foregroundStyle(.themeTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DYCommentMedia(comment: c)
                HStack(spacing: 8) {
                    Text(DYFormat.time(c.time))
                    if let ip = c.ip, !ip.isEmpty { Text(ip) }
                }
                .font(.caption2).foregroundStyle(.themeTextSecondary)
            }
            Spacer(minLength: 4)
            commentDigg(c)
        }
    }

    private func commentDigg(_ c: DYComment) -> some View {
        let on = digged.contains(c.id)
        let n = diggShown[c.id] ?? c.digg
        return Button { Task { await toggleDigg(c) } } label: {
            VStack(spacing: 2) {
                Image(systemName: on ? "heart.fill" : "heart").font(.caption)
                Text(DYFormat.count(max(0, n))).font(.caption2)
            }
            .foregroundStyle(on ? theme.status.danger.color(for: scheme) : Color.themeTextSecondary)
            .frame(minWidth: 32, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.comment.digg")
    }

    private func toggleDigg(_ c: DYComment) async {
        let want = !digged.contains(c.id)
        let before = diggShown[c.id] ?? c.digg
        if want { digged.insert(c.id) } else { digged.remove(c.id) }
        diggShown[c.id] = max(0, before + (want ? 1 : -1))
        do {
            switch try await bridge.diggComment(c.id, awemeID: aweme.id, like: want) {
            case .ok:
                break
            case .notLoggedIn:
                revertDigg(c, want: want, before: before)
                sendErr = "抖音未登录"
            case .failed(let why):
                revertDigg(c, want: want, before: before)
                sendErr = why
            }
        } catch {
            revertDigg(c, want: want, before: before)
            sendErr = error.localizedDescription
        }
    }

    private func revertDigg(_ c: DYComment, want: Bool, before: Int) {
        if want { digged.remove(c.id) } else { digged.insert(c.id) }
        diggShown[c.id] = before
    }

    @ViewBuilder
    private func replyBlock(_ c: DYComment) -> some View {
        let got = replies[c.id] ?? []
        VStack(alignment: .leading, spacing: 10) {
            ForEach(got) { r in row(r) }
            if replyErr[c.id] != nil {
                Button { replyErr[c.id] = nil; Task { await loadReplies(c) } } label: {
                    Text("回复加载失败，点此重试").font(.caption).foregroundStyle(.themeTextSecondary)
                }
                .buttonStyle(.plain)
            } else if replies[c.id] == nil || (replyMore[c.id] ?? false) {
                Button { Task { await loadReplies(c) } } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 18, height: 1)
                        Text(replies[c.id] == nil ? "展开 \(c.replies) 条回复" : "展开更多回复")
                        if replyLoading.contains(c.id) { ProgressView().controlSize(.mini) }
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.themeTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.replies")
            }
        }
        .padding(.leading, 42)
    }

    private func loadReplies(_ c: DYComment) async {
        guard !replyLoading.contains(c.id) else { return }
        replyLoading.insert(c.id)
        defer { replyLoading.remove(c.id) }
        do {
            let r = try await bridge.fetchReplies(aweme.id, commentID: c.id, cursor: replyCursor[c.id] ?? 0)
            DYLiveModel.log("DDREPLY cid=\(c.id) n=\(r.items.count) first=\(r.items.first?.text ?? "-")")
            let seen = Set((replies[c.id] ?? []).map(\.id))
            replies[c.id, default: []].append(contentsOf: r.items.filter { !seen.contains($0.id) })
            replyCursor[c.id] = r.cursor
            replyMore[c.id] = r.hasMore && !r.items.isEmpty
            replyErr[c.id] = nil
        } catch {
            DYLiveModel.log("DDREPLY cid=\(c.id) error=\(error)")
            replyErr[c.id] = "回复加载失败：\(error.localizedDescription)"
        }
    }

    private func load() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let t0 = DDPerf.ms
            let r = try await bridge.fetchComments(aweme.id, cursor: cursor)
            if cursor == 0 { DYLiveModel.log("DDPERF comments.firstPage took \(DDPerf.ms - t0)ms id=\(aweme.id)") }
            try Task.checkCancellation()
            let previousCursor = cursor
            let seen = Set(items.map(\.id))
            items.append(contentsOf: r.items.filter { !seen.contains($0.id) })
            for c in r.items where c.userDigged == 1 { digged.insert(c.id) }
            cursor = r.cursor
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != previousCursor
            total = max(total, r.total, aweme.stats.comment)
            error = nil
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_AUTOREPLY"] == "1", let c = items.first(where: { $0.replies > 0 }), replies[c.id] == nil {
                Task { await loadReplies(c) }
            }
            #endif
        } catch is CancellationError {
            // View lifecycle cancellations are routine, not a failed comment page.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 评论表情

/// 评论输入框的表情面板（纯 emoji，跟着文字一起发，不依赖抖音的表情包接口）
enum DYCommentEmoji {
    static let all: [String] = [
        "😀", "😄", "😁", "😂", "🤣", "😊", "😍", "🥰",
        "😘", "😎", "🤩", "🥳", "😏", "😅", "😅", "🙃",
        "😢", "😭", "😤", "😡", "🤬", "😱", "😨", "😰",
        "🤔", "🤨", "😐", "😑", "🙄", "😴", "🥱", "🤯",
        "😳", "🥺", "😬", "🤐", "🤫", "🤭", "😷", "🤒",
        "👍", "👎", "👏", "🙏", "💪", "🤝", "👌", "✌️",
        "👊", "🫶", "❤️", "💔", "🔥", "🎉", "🎊", "💯",
        "⭐", "✨", "🌹", "🌸", "🍺", "🍻", "☕", "🧋",
        "🍜", "🍚", "🍗", "🍰", "🎮", "⚽", "🏀", "🚀",
        "💰", "🎁", "🐶", "🐱", "🐼", "🦁", "🐸", "🦄"
    ]
}

// MARK: - 评论配图 / 表情包贴纸

/// 评论里的图片与贴纸：缩略图按原比例限高显示，点开全屏横滑看原图（同图集用 TabView 分页）
struct DYCommentMedia: View {
    let comment: DYComment
    @State private var viewer: DYCommentViewerTarget?

    private var pics: [DYCommentImage] { comment.images ?? [] }

    var body: some View {
        content.fullScreenCover(item: $viewer) { t in DYCommentImageViewer(target: t) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) { media }
    }

    @ViewBuilder
    private var media: some View {
        if let s = comment.sticker {
            // 贴纸：表情包尺寸，不放大
            thumb(s, maxSide: 96)
                .onTapGesture { viewer = DYCommentViewerTarget(images: [s], start: 0) }
                .accessibilityIdentifier("douyin.comment.sticker")
        }
        if !pics.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(pics.prefix(3).enumerated()), id: \.offset) { i, img in
                    thumb(img, maxSide: pics.count == 1 ? 160 : 96)
                        .overlay(alignment: .bottomTrailing) {
                            if i == 2, pics.count > 3 {
                                Text("+\(pics.count - 3)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                    .padding(4)
                            }
                        }
                        .onTapGesture { viewer = DYCommentViewerTarget(images: pics, start: i) }
                }
            }
            .accessibilityIdentifier("douyin.comment.images")
        }
    }

    private func thumb(_ img: DYCommentImage, maxSide: CGFloat) -> some View {
        let ratio = (img.w > 0 && img.h > 0) ? img.w / img.h : 1
        let w = ratio >= 1 ? maxSide : maxSide * ratio
        let h = ratio >= 1 ? maxSide / ratio : maxSide
        return CachedAsyncImage(url: URL(string: img.thumb)) { i in i.resizable().scaledToFill() }
            placeholder: { Color.primary.opacity(0.08) }
            .frame(width: max(w, 44), height: max(h, 44))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

struct DYCommentViewerTarget: Identifiable {
    let id = UUID()
    let images: [DYCommentImage]
    let start: Int
}

struct DYCommentImageViewer: View {
    let target: DYCommentViewerTarget
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(target.images.enumerated()), id: \.offset) { i, img in
                    CachedAsyncImage(url: URL(string: img.full)) { v in v.resizable().scaledToFit() }
                        placeholder: { ProgressView().tint(.white) }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: target.images.count > 1 ? .always : .never))
            .ignoresSafeArea()
            .onTapGesture { dismiss() }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.4)))
            }
            .padding(16)
            .accessibilityIdentifier("douyin.comment.viewer.close")
        }
        .onAppear { page = target.start }
    }
}
