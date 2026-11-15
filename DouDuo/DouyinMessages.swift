// 消息中心（对齐抖音消息页）：顶部朋友头像 → 互动/粉丝/系统/私信入口 → 点进分类二级页。
// 全部内容在同一个 ScrollView 里滚动，分类入口不固定在顶部。
// Duo：根页通过 Dock 切换栏目；详情返回走系统 toolbar 或左缘手势。
import SwiftUI
import WebKit
import CryptoKit

struct DYCachedNoticePage: Codable, Equatable {
    var items: [DYNotice] = []
    var maxTime = 0
    var hasMore = true
}

/// 消息按登录会话分区缓存；只保存会话的哈希，不保存 cookie/token。
@MainActor
final class DYMessageCache: ObservableObject {
    static let shared = DYMessageCache()
    /// 当前打开的会话；root 与「陌生人消息」二级页共用同一份状态
    @Published var selectedChat: DYConversationRow?
    /// Memory-only route for a banner tap. Not part of the saved snapshot.
    @Published var directRouteID: String?
    /// 陌生人二级列表（网页展开陌生人面板后读出的每个人）与总未读
    @Published var strangerRows: [DYConversationRow] = []
    @Published var strangerUnread: Int?
    /// 主列表里「我没关注」的单聊：抖音网页把它们混在普通会话里，按官方 App 归到陌生人
    @Published var unfollowedRows: [DYConversationRow] = []
    /// sec_uid → follow_status（0 未关注 / 1 已关注 / 2 互关），落盘让下次进来分类不闪
    @Published var follow: [String: Int] = [:]
    private var followChecked = Set<String>()
    /// Local to this account. Hiding never deletes the official conversation or history.
    @Published private(set) var hiddenConversations: [String: DYConversationRow] = [:]

    func hide(_ row: DYConversationRow) {
        hiddenConversations[row.id] = row
        persistHiddenConversations()
    }
    func unhide(_ id: String) {
        guard hiddenConversations.removeValue(forKey: id) != nil else { return }
        persistHiddenConversations()
    }
    func reconcileHiddenConversations(_ rows: [DYConversationRow]) {
        let restored = rows.filter { row in
            hiddenConversations[row.id].map { row.hasNewMessage(since: $0) } ?? false
        }
        guard !restored.isEmpty else { return }
        for row in restored { hiddenConversations.removeValue(forKey: row.id) }
        persistHiddenConversations()
    }
    private func persistHiddenConversations() {
        snapshot.hiddenConversations = hiddenConversations
        save()
    }

    func isUnfollowed(_ row: DYConversationRow) -> Bool {
        guard !row.stranger, row.kind == 1, let sec = row.sec, !sec.isEmpty else { return false }
        return follow[sec] == 0
    }

    /// 查单聊对方的关注关系；每次启动每人只查一次（关注关系可能变）
    func resolveFollow(_ secs: [String]) async {
        let need = Array(Set(secs.filter { !$0.isEmpty && !followChecked.contains($0) }))
        guard !need.isEmpty, let web = chatModel.web else { return }
        let account = scope
        need.forEach { followChecked.insert($0) }
        let js = """
        const out = {};
        await Promise.all(secs.map(async s => {
          try {
            const r = await fetch('/aweme/v1/web/user/profile/other/?device_platform=webapp&aid=6383&sec_user_id=' + encodeURIComponent(s), { credentials: 'include' });
            const u = (JSON.parse(await r.text()) || {}).user || {};
            if (typeof u.follow_status === 'number') out[s] = u.follow_status;
          } catch (e) {}
        }));
        return JSON.stringify(out);
        """
        guard let str = try? await web.callAsyncJavaScript(js, arguments: ["secs": need], contentWorld: .page) as? String,
              let d = str.data(using: .utf8),
              let m = try? JSONDecoder().decode([String: Int].self, from: d) else {
            if scope == account { need.forEach { followChecked.remove($0) } }
            return
        }
        guard scope == account else { return }
        need.filter { m[$0] == nil }.forEach { followChecked.remove($0) }
        follow.merge(m) { _, new in new }
        snapshot.follow = follow; save()
        DYLiveModel.log("DDSTRANGER follow resolved=\(m.count) unfollowed=\(m.values.filter { $0 == 0 }.count)")
    }
    struct Snapshot: Codable {
        /// 结构版本：DYNotice 加了 images（评论配图）后升 2；旧文件缺该字段，消息页必须作废重拉
        var v: Int = 1
        static let currentV = 2
        var pages: [String: DYCachedNoticePage] = [:]
        var counts: [Int: Int] = [:]
        var friends: [DYFriend] = []
        var conversations: [DYConversationRow] = []
        var follow: [String: Int]?
        var friendCursor: String?
        var friendHasMore: Bool?
        var hiddenConversations: [String: DYConversationRow]?
    }
    var snapshot = { var s = Snapshot(); s.v = Snapshot.currentV; return s }()
    let chatModel = DouyinWebModel()
    private var retainedChatWeb: WKWebView?
    @Published private(set) var scope = ""
    /// Increments on every real scope change, including a return to a previous account.
    @Published private(set) var scopeGeneration = 0
    /// True only when a Douyin session cookie is present. The cookie value is not stored.
    @Published private(set) var hasSession = false
    var accountScope: String { scope }
    private var refreshing = Set<String>()
    private var friendsRefreshing = Set<String>()
    private var lastSavedData: Data?
    private var file: URL? {
        #if DEBUG
        if DYMessageFixture.enabled { return nil }
        #endif
        guard !scope.isEmpty else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("message-cache-v3", isDirectory: true).appendingPathComponent(scope + ".json")
    }
    func prepare() async {
        #if DEBUG
        if DYMessageFixture.enabled {
            if scope != DYMessageFixture.scope {
                scope = DYMessageFixture.scope
                snapshot = Snapshot()
                selectedChat = nil; strangerRows = []; strangerUnread = nil; unfollowedRows = []
                follow = [:]; followChecked = []; hiddenConversations = [:]
            }
            return
        }
        #endif
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let identity = cookies.filter { $0.domain.hasSuffix("douyin.com") && ["sessionid", "sessionid_ss", "uid_tt"].contains($0.name) }
            .sorted { $0.name < $1.name }.map { $0.name + "=" + $0.value }.joined(separator: "|")
        let next = SHA256.hash(data: Data((identity.isEmpty ? "guest" : identity).utf8)).map { String(format: "%02x", $0) }.joined()
        hasSession = !identity.isEmpty
        guard next != scope else { DYPeopleCache.shared.activate(scope: scope); return }
        let changingAccount = !scope.isEmpty
        scope = next
        scopeGeneration &+= 1
        var fresh = Snapshot(); fresh.v = Snapshot.currentV
        snapshot = fresh; lastSavedData = nil
        if let file, let data = try? Data(contentsOf: file), var cached = try? JSONDecoder().decode(Snapshot.self, from: data) {
            if cached.v < 2 {
                // 旧缓存的评论通知没有 images 字段且 refresh 不会重取老通知：作废消息页重拉（朋友/会话历史保留）
                cached.pages = [:]
                cached.v = Snapshot.currentV
                DYLiveModel.log("DDMSGCACHE schema v<2 → pages cleared")
            }
            snapshot = cached; lastSavedData = data
            // 旧版写进缓存的 ddimg:// 头像还原成原地址：原生列表加载不了 ddimg，那 20 个好友头像就是这么空的
            var repaired = 0
            for i in snapshot.conversations.indices {
                let fixed = DYChatImageCache.originalURL(snapshot.conversations[i].avatar)
                if fixed != snapshot.conversations[i].avatar { snapshot.conversations[i].avatar = fixed; repaired += 1 }
            }
            if repaired > 0 { lastSavedData = nil; save(); DYLiveModel.log("DDMSGCACHE repaired ddimg avatars=\(repaired)") }
        }
        selectedChat = nil; strangerRows = []; strangerUnread = nil; unfollowedRows = []
        follow = snapshot.follow ?? [:]; followChecked = []
        hiddenConversations = snapshot.hiddenConversations ?? [:]
        DYPeopleCache.shared.activate(scope: scope)
        if !DYPeopleCache.shared.hasFriendsSnapshot && !snapshot.friends.isEmpty {
            DYPeopleCache.shared.mergeFriends(snapshot.friends, scope: scope)
        }
        if changingAccount {
            // 丢弃旧账号的DOM，避免新scope误读取旧页面；视图用scope作为实例ID重建。
            let old = chatModel.web
            old?.stopLoading()
            old?.removeFromSuperview()
            chatModel.web = nil
            retainedChatWeb = nil
            if DYDMProbe.enabled { DYChatWebSession.shared.noteAccountReset() }
        }
    }
    func retainChat() { retainedChatWeb = chatModel.web }
    func save() {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let file, let data = try? encoder.encode(snapshot), data != lastSavedData else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSavedData = data
        } catch { DYLiveModel.log("DDMSGCACHE save failed") }
    }
    func page(_ group: Int) -> DYCachedNoticePage? { snapshot.pages[String(group)] }
    func refresh(_ group: Int, bridge: DouyinBridge) async throws -> DYCachedNoticePage {
        let account = scope, key = scope + "|" + String(group)
        if refreshing.contains(key) { return page(group) ?? DYCachedNoticePage() }
        refreshing.insert(key)
        defer { refreshing.remove(key) }
        let old = page(group)
        let boundary = Int(old?.items.map(\.time).max() ?? 0)
        let known = Set(old?.items.map(\.id) ?? [])
        var incoming: [DYNotice] = []
        var cursor = 0
        var initialCursor = 0
        var initialMore = false
        for batch in 0..<12 {
            let fresh = try await bridge.notices(group: group, maxTime: cursor, minTime: boundary)
            guard scope == account else { throw CancellationError() }
            if batch == 0 { initialCursor = fresh.maxTime; initialMore = fresh.hasMore }
            incoming.append(contentsOf: fresh.items)
            if !fresh.hasMore || fresh.items.isEmpty || fresh.maxTime == cursor || fresh.items.contains(where: { known.contains($0.id) }) { break }
            // 没有缓存时只取首页，历史仍由用户下滑分页获取。
            if old == nil { break }
            cursor = fresh.maxTime
        }
        var byID = Dictionary((old?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for notice in incoming { byID[notice.id] = notice }
        let merged = Array(byID.values.sorted { $0.time == $1.time ? $0.id > $1.id : $0.time > $1.time }.prefix(500))
        let result = DYCachedNoticePage(items: merged, maxTime: old?.maxTime ?? initialCursor, hasMore: old?.hasMore ?? initialMore)
        if page(group) != result { snapshot.pages[String(group)] = result; save() }
        DYLiveModel.log("DDMSGCACHE refresh group=\(group) min=\(boundary) new=\(incoming.filter { !known.contains($0.id) }.count) cached=\(merged.count)")
        return result
    }
    func store(_ page: DYCachedNoticePage, group: Int) { snapshot.pages[String(group)] = page; save() }
    func markReadAfterExit(_ groups: Set<Int>, bridge: DouyinBridge) async {
        for group in groups {
            do {
                _ = try await bridge.notices(group: group, maxTime: 0, markRead: true)
                for key in Array(snapshot.pages.keys) {
                    guard var page = snapshot.pages[key] else { continue }
                    for i in page.items.indices {
                        let type = page.items[i].type
                        if key == String(group) || (group == 2 && type == 31) || (group == 3 && type == 41) || (group == 401 && type == 33) {
                            page.items[i].hasRead = true
                        }
                    }
                    snapshot.pages[key] = page
                }
                DYLiveModel.log("DDNOTICE read-on-exit group=\(group)")
            } catch { DYLiveModel.log("DDNOTICE read-on-exit failed group=\(group)") }
        }
        if let values = try? await bridge.noticeCounts() {
            snapshot.counts = Dictionary(values.map { ($0.group, $0.count) }, uniquingKeysWith: { a, _ in a })
        }
        save()
    }
}

struct DYConversationRow: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    /// var：网页图片缓存改写过的 ddimg:// 地址要还原成原地址（见 DYChatImageCache.originalURL）
    var avatar: String?
    let preview: String
    let time: String
    let badge: String
    let index: String
    /// true = 行在网页「陌生人面板」里（打开时要先展开面板）
    let stranger: Bool
    /// 网页 IM 会话类型：1 单聊 / 2 群聊
    var kind: Int?
    /// 单聊对方 sec_uid，用来查关注关系
    var sec: String?
    var observedAt: Double? = nil
    var streak: DYConversationStreak?
    var isPinned: Bool?
    /// Server message time (seconds since 1970), independent of relative labels.
    var lastMessageTime: Double?
    var lastMessageID: String?
}

extension DYConversationRow {
    /// Ignore clock labels, read receipts, pin/name/avatar changes and older pages.
    func hasNewMessage(since hidden: DYConversationRow) -> Bool {
        if let current = lastMessageTime, let previous = hidden.lastMessageTime {
            if current != previous { return current > previous }
        }
        if let current = lastMessageID, let previous = hidden.lastMessageID,
           !current.isEmpty, !previous.isEmpty { return current != previous }
        return preview != hidden.preview || (Int(badge) ?? 0) > (Int(hidden.badge) ?? 0)
    }

    var sortTime: Double { sortTime(at: Date()) }
    func sortTime(at now: Date) -> Double {
        if let lastMessageTime, lastMessageTime.isFinite, lastMessageTime > 0 { return lastMessageTime }
        let captured = observedAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return Self.parseTime(time, now: captured ?? now)
    }

    static func parseTime(_ value: String, now: Date) -> Double {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 0 }
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        func groups(_ pattern: String) -> [Int]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  m.range.length == (t as NSString).length else { return nil }
            return (1..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? -1 : Int((t as NSString).substring(with: m.range(at: i))) ?? -1
            }
        }
        func clock(_ base: Date, _ h: Int, _ m: Int) -> Double {
            guard (0...23).contains(h), (0...59).contains(m) else { return 0 }
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base)?.timeIntervalSince1970 ?? 0
        }
        if ["现在", "刚刚", "刚才"].contains(t) { return now.timeIntervalSince1970 }
        if let p = groups(#"^(\d+)\s*秒前$"#) { return now.timeIntervalSince1970 - Double(p[0]) }
        if let p = groups(#"^(\d+)\s*分钟前$"#) { return now.timeIntervalSince1970 - Double(p[0]) * 60 }
        if let p = groups(#"^(\d+)\s*小时前$"#) { return now.timeIntervalSince1970 - Double(p[0]) * 3600 }
        if let p = groups(#"^(\d+)\s*天前$"#) { return cal.date(byAdding: .day, value: -p[0], to: day)?.timeIntervalSince1970 ?? 0 }
        for (prefix, days) in [("今天", 0), ("昨天", -1), ("前天", -2)] where t.hasPrefix(prefix) {
            guard let base = cal.date(byAdding: .day, value: days, to: day) else { return 0 }
            let rest = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return base.timeIntervalSince1970 }
            let p = rest.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? clock(base, p[0], p[1]) : 0
        }
        if let p = groups(#"^(\d{1,2}):(\d{2})$"#) {
            let ts = clock(day, p[0], p[1])
            if ts > now.timeIntervalSince1970 + 3600, let yesterday = cal.date(byAdding: .day, value: -1, to: day) { return clock(yesterday, p[0], p[1]) }
            return ts
        }
        if let p = groups(#"^(?:(\d{4})[/-])?(\d{1,2})[/-](\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?$"#) {
            var year = p[0] >= 0 ? p[0] : cal.component(.year, from: now)
            func date(_ y: Int) -> Date? {
                let c = DateComponents(year: y, month: p[1], day: p[2], hour: p[3] >= 0 ? p[3] : 0, minute: p[4] >= 0 ? p[4] : 0)
                guard let d = cal.date(from: c), cal.component(.month, from: d) == p[1], cal.component(.day, from: d) == p[2] else { return nil }
                return d
            }
            guard var d = date(year) else { return 0 }
            if p[0] < 0, d > now { year -= 1; guard let last = date(year) else { return 0 }; d = last }
            return d.timeIntervalSince1970
        }
        // 未识别的时间排最后，不能回退成“现在”。
        return 0
    }
    static func byTimeDesc(_ a: DYConversationRow, _ b: DYConversationRow) -> Bool {
        if (a.isPinned == true) != (b.isPinned == true) { return a.isPinned == true }
        let now = Date(), first = a.sortTime(at: now), second = b.sortTime(at: now)
        return first != second ? first > second : a.id < b.id
    }
}

enum DYNoticeGroup: Int, CaseIterable, Identifiable {
    case all = 700
    case comment = 2
    case digg = 3
    case fans = 401
    case system = 961

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .comment: "评论"
        case .digg: "赞"
        case .fans: "粉丝"
        case .system: "系统"
        }
    }
}

/// 消息二级页
enum DYMsgRoute: Hashable {
    case interactive, fans, system, stranger

    var title: String {
        switch self {
        case .interactive: "互动消息"
        case .fans: "粉丝消息"
        case .system: "系统通知"
        case .stranger: "陌生人消息"
        }
    }
    var isNotice: Bool { self != .stranger }

    /// 退出分类要标已读的服务端分组号
    var readGroups: [Int] {
        switch self {
        case .interactive: [2, 3]
        case .fans: [401]
        case .system: [961]
        case .stranger: []
        }
    }

    /// 标题下拉可切的接口分组（互动页 = 全部/评论/赞）
    var filters: [DYNoticeGroup] {
        switch self {
        case .interactive: [.all, .comment, .digg]
        case .fans: [.fans]
        case .system: [.system]
        case .stranger: []
        }
    }

    func filterTitle(_ g: DYNoticeGroup) -> String {
        guard self == .interactive else { return title }
        switch g {
        case .comment: return "评论"
        case .digg: return "赞"
        default: return "全部互动"
        }
    }
}

/// notice 列表里的 type（不是 group）：31 评论 / 41 赞 / 9009 推荐 / 33 关注
enum DYNoticeKind {
    static let follow = 33
    static func isInteractive(_ n: DYNotice) -> Bool {
        n.type != follow && (n.author != nil || (n.awemeID ?? "").isEmpty == false)
    }
}

// MARK: - 根页

struct DYMessagesScreen: View {
    @Environment(\.dismiss) private var dismissRoot
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let bridge: DouyinBridge
    var onClose: (() -> Void)? = nil
    let onWeb: (URL) -> Void
    var forwardedShare: DYForwardReceipt? = nil

    @State private var navigation = DYMessageNavigation()
    @State private var visitedRoutes: Set<DYMsgRoute> = []
    @State private var openingChat: String?
    /// 网页 DOM 真的切到这条会话了没有：没切之前用原生遮罩盖住，避免闪一下会话列表
    @State private var chatDOMReady = true
    @State private var sidebarVisible = false
    @AppStorage("douyin_message_sidebar_fraction_v1") private var sidebarFraction = 0.36
    @State private var sidebarWidth: CGFloat = 320
    @State private var messageSize: CGSize = .zero
    @State private var messageTopInset: CGFloat = 0
    @State private var isHalfFolded = false
    @StateObject private var composer = DYChatComposerModel()
    @State private var chatAuthor: DYAweme.Author?
    @State private var showChatOptions = false
    @State private var changingConversation: String?
    @State private var deletingConversation: DYConversationRow?
    @State private var actionError: String?
    @State private var openedFromShare = false
    @State private var shareOpenFailed = false
    @State private var shareOpenAttempt = 0
    @State private var handledShareRequest = ""
    /// 上游「Duo 经典布局」下分享进来的聊天保留底部页签；本分支没有这个布局
    private var keepsSharedChatDock: Bool { false }
    private var compactSidebar: Bool { sidebarVisible && sidebarWidth < 250 }
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @StateObject private var chatModel = DYMessageCache.shared.chatModel
    @State private var viewedGroups: [DYMsgRoute: Set<Int>] = [:]
    @State private var conversations: [DYConversationRow] = []
    @ObservedObject private var cache = DYMessageCache.shared
    private var selectedChat: DYConversationRow? { cache.selectedChat }
    @State private var chatStatus = "正在加载私信…"
    /// 聊天里点朋友分享的视频 → 原生播放器（网页 ddMsg 通道触发）
    @State private var videoPlay: DYMessagePlay?
    /// 顶部头像栏 = 朋友（互相关注），来自 familiar/atlist，不是粉丝
    @State private var friends: [DYFriend] = []
    @State private var counts: [Int: Int] = [:]
    @State private var recent: [DYNotice] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            GeometryReader { safeGeometry in
                messageContent
                    .onChange(of: safeGeometry.safeAreaInsets.top, initial: true) { _, value in messageTopInset = value }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("douyin.messages.root")
                    .ignoresSafeArea(.container, edges: keepsSharedChatDock ? [.top] : [.top, .bottom])
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .backgroundPreferenceValue(DYMessageRowBoundsKey.self) { bounds in
                        pinnedRowBackdrop(bounds)
                    }
                    .background {
                        GeometryReader { _ in
                            if sidebarVisible {
                                Rectangle().fill(.regularMaterial).overlay(theme.messages.sidebarTint)
                                    .frame(width: sidebarWidth)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .ignoresSafeArea(.all, edges: [.top, .bottom])
                            } else if !navigation.hasDetail {
                                theme.messages.sidebarTint.ignoresSafeArea()
                            }
                        }
                    }
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                    .scrollEdgeEffectHidden(true, for: .all)
                    .toolbar {
                        // The message center is a root tab. Only its detail pages go back.
                        if !navigation.hasDetail {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("返回", systemImage: "chevron.backward") { if let onClose { onClose() } else { dismissRoot() } }
                                    .tint(.white)
                            }
                        }
                        if navigation.hasDetail {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("返回", systemImage: "chevron.backward", action: backFromMessage)
                                    .tint(.white)
                                    .disabled(openingChat != nil)
                                    .accessibilityIdentifier("douyin.messages.back")
                            }
                        }
                        if navigation.isChat {
                            if #available(iOS 27.1, *) {
                                ToolbarItem(placement: .primaryAction) { chatOptionsButton }
                                    .axisBehavior(.verticalPreferred)
                                    .visibilityPriority(.high)
                            } else {
                                ToolbarItem(placement: .primaryAction) { chatOptionsButton }
                            }
                        }
                    }
            }

        }
        .preferredColorScheme(.dark)
        .overlay {
            if openingChat == "forwarded-share", let forwardedShare {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开“\(forwardedShare.contact.name)”")
                }
                .padding(24).glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .alert("暂未打开会话", isPresented: $shareOpenFailed) {
            Button("重试") { shareOpenAttempt += 1 }
            Button("返回", role: .cancel) { onClose?() }
        } message: { Text("会话可能还在同步，请稍后重试。重试只打开聊天，不会再次发送。") }
        .task(id: "\(forwardedShare?.id.uuidString ?? "")-\(shareOpenAttempt)") {
            guard let forwardedShare else { return }
            let request = "\(forwardedShare.id.uuidString)-\(shareOpenAttempt)"
            guard handledShareRequest != request else { return }
            await openSharedConversation(forwardedShare)
            if !Task.isCancelled { handledShareRequest = request }
        }
        .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "请稍后重试") }
        .alert("删除这条会话？", isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } })) {
            Button("删除", role: .destructive) {
                if let row = deletingConversation { Task { await changeConversation(row, action: .delete) } }
                deletingConversation = nil
            }
            Button("取消", role: .cancel) { deletingConversation = nil }
        } message: { Text("会话将从消息列表移除。") }
        .task(id: navigation.chatID) {
            guard let id = navigation.chatID else { return }
            while !Task.isCancelled, navigation.chatID == id {
                if let web = chatModel.web, let snapshot = await DYChatWebBridge.snapshot(web, headerInset: messageTopInset + 72),
                   !Task.isCancelled, snapshot.id == id, navigation.chatID == id {
                    composer.setAccountScope(cache.accountScope)
                    await composer.refresh(web: web, id: id)
                    if var row = cache.selectedChat, row.id == id, row.streak != snapshot.streak {
                        row.streak = snapshot.streak
                        cache.selectedChat = row
                        updateConversation(row)
                    }
                }
                do { try await Task.sleep(for: .seconds(composer.isEditing ? 2 : 1)) } catch { return }
            }
        }
        .onChange(of: navigation.chatID) { _, id in
            if id == nil { composer.disconnect() }
        }
        .onChange(of: cache.accountScope) { _, scope in composer.setAccountScope(scope) }
        .onAppear {
            if let row = selectedChat { navigation.openChat(row.id, from: navigation.category) }
            else if navigation.isChat { _ = navigation.back() }
        }
        .onChange(of: cache.directRouteID) { _, id in
            if let id {
                navigation.openChat(id, from: nil)
            } else if navigation.isChat, cache.selectedChat == nil {
                _ = navigation.back()
            }
        }
        .task { await loadRoot() }
        .task {
            // 网页聊天页 → App：点分享视频卡片跳原生播放（DouyinWebView 的 ddMsg 通道）
            if #available(iOS 27.1, *) { DYLiveModel.log("DDMSG layout=resizable") } else { DYLiveModel.log("DDMSG layout=legacy") }
            chatModel.onAppMessage = { json in
                guard let data = json.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                switch obj["type"] as? String {
                case "video":
                    guard let id = obj["id"] as? String, !id.isEmpty else { return }
                    Task { @MainActor in
                        do {
                            let item = try await self.bridge.awemeDetail(id)
                            self.videoPlay = DYMessagePlay(item: item)
                            DYLiveModel.log("DDMSGVIDEO jump \(id) kind=\(item.images.isEmpty ? "video" : "gallery\(item.images.count)")")
                        } catch {
                            DYLiveModel.log("DDMSGVIDEO detail fail \(id): \(error.localizedDescription)")
                        }
                    }
                case "video-miss":
                    // 抽不到 aweme_id 时回传卡片线索（类名 / 图片数 / 链接 / payload 类型 / HTML 片段），用来迭代选择器
                    let cls = obj["classes"] as? String ?? "-"
                    let imgs = (obj["images"] as? NSNumber)?.intValue ?? -1
                    let hrefs = (obj["hrefs"] as? [String])?.joined(separator: " ") ?? "-"
                    let awe = obj["aweType"] as? String ?? "-"
                    let keys = obj["keys"] as? String ?? "-"
                    let iid = obj["itemId"] as? String ?? "-"
                    DYLiveModel.log("DDVIDEOTAP miss cls=\(cls) img=\(imgs) awe=\(awe) id=\(iid) hrefs=\(hrefs) keys=\(keys)")
                    let chain = obj["chain"] as? String ?? "-"
                    let err = obj["err"] as? String ?? "-"
                    DYLiveModel.log("DDVIDEOTAP chain=\(chain) err=\(err)")
                    DYLiveModel.log("DDVIDEOTAP html " + String((obj["html"] as? String ?? "").prefix(400)))
                case "video-probe":
                    let classes = (obj["classes"] as? [String]) ?? []
                    DYLiveModel.log("DDVIDEOPROBE " + classes.joined(separator: " | "))
                default:
                    break
                }
            }
        }
        .fullScreenCover(item: $videoPlay) { p in
            // 信息里点开的分享视频：一关掉就把它的声音彻底收掉（见 DYListPlayer.hardStopOnDismiss）
            DYListPlayer(bridge: bridge, title: p.item.desc.isEmpty ? "视频" : p.item.desc,
                         items: [p.item], start: 0, onAuthor: { _ in }, hardStopOnDismiss: true)
        }
        .sheet(item: $chatAuthor) { author in
            NavigationStack {
                DYAuthorScreen(bridge: bridge, author: author, onWeb: onWeb)
            }
            .preferredColorScheme(.dark)
        }
        .task {
            while !Task.isCancelled {
                if !navigation.isChat && openingChat == nil && changingConversation == nil { await readConversations() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: navigation.detail) { old, current in
            // 只有真正退出分类才标已读；打开视频/作者弹层不算退出分类。
            guard old != current, case .category(let route) = old else { return }
            let seen = viewedGroups.removeValue(forKey: route) ?? []
            Task {
                await DYMessageCache.shared.markReadAfterExit(seen, bridge: bridge)
                counts = DYMessageCache.shared.snapshot.counts
                recent = DYMessageCache.shared.page(700)?.items ?? recent
            }
        }
        .onDisappear { DYMessageCache.shared.retainChat() }
    }

    /// Both panes keep their identity while resizing. Explicit widths make the
    /// divider authoritative; ArrangementView treats layout ratios as preferences.
    @ContentBuilder
    private var messageContent: some View {
        if #available(iOS 27.1, *) {
            GeometryReader { geo in
                let split = horizontalSizeClass == .regular && DYMessageSidebarLayout.showsSplit(in: geo.size, window: chatModel.windowSize)
                let folded = isHalfFolded || DYDuoMetrics.foldIsActive(geo)
                let hinge = DYDuoMetrics.hingeSplit(geo)
                let foldCenter = hinge.flatMap { $0.book ? ($0.video.maxX + $0.panel.minX) / 2 : nil }
                    ?? (geo.size.width + geo.safeAreaInsets.trailing - geo.safeAreaInsets.leading) / 2
                let listWidth = split ? (folded ? foldCenter : DYMessageSidebarLayout.listWidth(fraction: sidebarFraction, in: geo.size.width)) : geo.size.width
                let detailWidth = split ? geo.size.width - listWidth : geo.size.width
                let rtl = layoutDirection == .rightToLeft
                let direction: CGFloat = rtl ? -1 : 1
                let routeAnimation: Animation? = split ? nil : .easeInOut(duration: reduceMotion ? 0.12 : 0.26)
                ZStack(alignment: .topLeading) {
                    root
                        .frame(width: listWidth, height: geo.size.height)
                        .clipped()
                        .padding(.trailing, split ? detailWidth : 0)
                        .offset(x: !split && navigation.hasDetail && !reduceMotion ? -direction * geo.size.width * 0.18 : 0)
                        .opacity(!navigation.hasDetail || split ? 1 : 0)
                        .animation(routeAnimation, value: navigation.hasDetail)
                        .allowsHitTesting(!navigation.hasDetail || split)
                        .accessibilityHidden(navigation.hasDetail && !split)
                    if split && !navigation.hasDetail {
                        ContentUnavailableView("选择一条消息", systemImage: "bubble.left.and.bubble.right",
                            description: Text("在左侧选择会话，继续聊天。"))
                            .frame(width: detailWidth, height: geo.size.height)
                            .padding(.leading, listWidth)
                    }
                    detailPane
                        .frame(width: detailWidth, height: geo.size.height)
                        .clipped()
                        // Place the pane in layout coordinates. A visual offset
                        // leaves Duo's half-fold clipping on the original pane.
                        .padding(.leading, split ? listWidth : 0)
                        .offset(x: !split && !navigation.hasDetail && !reduceMotion ? direction * geo.size.width : 0)
                        .opacity(navigation.hasDetail ? 1 : 0.001)
                        .animation(routeAnimation, value: navigation.hasDetail)
                        .allowsHitTesting(navigation.hasDetail)
                        .accessibilityHidden(!navigation.hasDetail)
                    if split && !folded {
                        let dragTop = messageTopInset + 72
                        let dragHeight = max(44, geo.size.height - dragTop - 88)
                        DYMessageDivider(fraction: $sidebarFraction, width: geo.size.width)
                            .frame(height: dragHeight)
                            // Keep the hit target on the chat side so swiping a
                            // conversation works. Leave the avatar and composer
                            // clear so the transparent target never swallows taps.
                            .position(x: rtl ? detailWidth - 22 : listWidth + 22, y: dragTop + dragHeight / 2)
                    }
                }
                .clipped()
                .onChange(of: split, initial: true) { _, value in sidebarVisible = value }
                .onChange(of: listWidth, initial: true) { _, value in sidebarWidth = value }
                .onChange(of: geo.size, initial: true) { _, size in
                    messageSize = size
                }
                .onHingeChange { _, context in isHalfFolded = context.hinge?.status == .partiallyOpen }
            }
            .modifier(DYEdgeSwipeBack(action: backFromMessage))
        } else {
            legacyMessageContent
        }
    }

    /// iOS 27.1 以下回退：全屏覆盖（原行为）
    private var legacyMessageContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                root
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(navigation.hasDetail ? 0 : 1)
                    .allowsHitTesting(!navigation.hasDetail)
                    .accessibilityHidden(navigation.hasDetail)
                detailPane
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(navigation.hasDetail ? 1 : 0.001)
                    .allowsHitTesting(navigation.hasDetail)
                    .accessibilityHidden(!navigation.hasDetail)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: geo.size, initial: true) { _, value in
                messageSize = value
                // 记住真实尺寸：下次关闭信息页时网页按这个尺寸留在后台，回来不用整页重排
                DYChatWebSession.shared.noteMessagesSize(value)
            }
        }
        .clipped()
        .modifier(DYEdgeSwipeBack(action: backFromMessage))
    }

    private var strangerBadge: Int {
        let panel = cache.strangerUnread ?? strangerConversations.reduce(0) { $0 + (Int($1.badge) ?? 0) }
        return panel + unfollowedConversations.reduce(0) { $0 + (Int($1.badge) ?? ($1.badge.isEmpty ? 0 : 1)) }
    }
    private var strangerSummary: String {
        if let first = unfollowedConversations.first ?? cache.strangerRows.first {
            return first.preview.isEmpty ? first.name : "\(first.name)：\(first.preview)"
        }
        guard let box = strangerConversations.first else { return "非好友发来的私信" }
        return box.preview.isEmpty ? "非好友发来的私信" : box.preview
    }
    /// 置顶会话的底色延伸到 Duo 系统竖栏后面（行内控件仍留在安全区里）
    private func pinnedRowBackdrop(_ bounds: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { (geo: GeometryProxy) in
            if !sidebarVisible && !navigation.hasDetail, let viewport = bounds["viewport"] {
                let visible: CGRect = geo[viewport]
                ForEach(friendConversations.filter { $0.isPinned == true }) { (row: DYConversationRow) in
                    if let anchor = bounds[row.id] {
                        let rect: CGRect = geo[anchor].intersection(visible)
                        if !rect.isNull, rect.height > 0 {
                            theme.messages.pinnedRow
                                .frame(width: geo.size.width, height: rect.height)
                                .position(x: geo.size.width / 2, y: rect.midY)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var friendConversations: [DYConversationRow] { conversations.filter { !$0.stranger && !cache.isUnfollowed($0) && cache.hiddenConversations[$0.id] == nil } }
    private var unfollowedConversations: [DYConversationRow] { conversations.filter { cache.isUnfollowed($0) } }
    private var strangerConversations: [DYConversationRow] { conversations.filter(\.stranger) }

    private var conversationRows: some View {
        Group {
            if conversations.isEmpty {
                Text(chatStatus).font(.footnote).foregroundStyle(.secondary).padding(20)
            }
            ForEach(friendConversations) { row in
                Button { Task { await openConversation(row) } } label: {
                    DYConversationCell(row: row, compact: compactSidebar)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.conversation.row")
                .listRowBackground(navigation.chatID == row.id ? theme.messages.selectedRow : row.isPinned == true ? theme.messages.pinnedRow : .clear)
                .accessibilityAddTraits(navigation.chatID == row.id ? .isSelected : [])
                .disabled(openingChat != nil || changingConversation != nil)
                .accessibilityValue(row.isPinned == true ? "已置顶" : "")
                .anchorPreference(key: DYMessageRowBoundsKey.self, value: .bounds) {
                    row.isPinned == true ? [row.id: $0] : [:]
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button(row.isPinned == true ? "取消置顶" : "置顶", systemImage: row.isPinned == true ? "pin.slash" : "pin.fill") {
                        Task { await changeConversation(row, action: row.isPinned == true ? .unpin : .pin) }
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", systemImage: "trash", role: .destructive) { deletingConversation = row }
                    Button("不显示", systemImage: "eye.slash") {
                        Task { await hideConversation(row) }
                    }
                    .tint(.gray)
                    .accessibilityHint("仅从此账号的本机列表隐藏，收到新消息时恢复，聊天记录保留")
                }
            }
            // Hidden rows still belong to the official list; keep pagination available
            // even when every loaded friend conversation is hidden locally.
            if conversations.contains(where: { !$0.stranger && !cache.isUnfollowed($0) }) {
                Button("加载更多会话") {
                    Task {
                        _ = try? await chatModel.web?.evaluateJavaScript(Self.scrollConversationsJS)
                        try? await Task.sleep(for: .milliseconds(500))
                        await readConversations()
                    }
                }
                .font(.footnote).padding(16)
            }
        }
    }

    private func hideConversation(_ row: DYConversationRow) async {
        guard changingConversation == nil, openingChat == nil else { return }
        let account = cache.accountScope
        changingConversation = row.id
        defer { changingConversation = nil }
        if navigation.chatID == row.id {
            guard !composer.working else { return }
            guard cache.accountScope == account else { return }
            openedFromShare = false
            _ = navigation.back()
            restoreConversationList()
        }
        cache.hide(row)
    }

    private func updateConversation(_ row: DYConversationRow) {
        if let index = conversations.firstIndex(where: { $0.id == row.id }) { conversations[index] = row }
        conversations.sort(by: DYConversationRow.byTimeDesc)
        cache.snapshot.conversations = conversations
        cache.save()
    }

    private func changeConversation(_ row: DYConversationRow, action: DYChatWebBridge.Action) async {
        guard changingConversation == nil, openingChat == nil, let web = chatModel.web else { return }
        changingConversation = row.id
        let scope = cache.accountScope
        defer { changingConversation = nil }
        do {
            try await DYChatOpener.change(row, action: action, web: web)
            guard cache.accountScope == scope else { return }
            if action == .delete {
                cache.unhide(row.id)
                conversations.removeAll { $0.id == row.id }
                cache.snapshot.conversations = conversations
                cache.save()
                if navigation.chatID == row.id { backFromMessage() }
            } else {
                var updated = row
                updated.isPinned = action == .pin
                updateConversation(updated)
                if cache.selectedChat?.id == row.id { cache.selectedChat = updated }
            }
            await readConversations()
        } catch {
            guard cache.accountScope == scope else { return }
            actionError = "操作未完成，请刷新会话后重试。"
        }
    }

    private var chatOptionsButton: some View {
        Button("更多", systemImage: "ellipsis") { showChatOptions = true }
            .tint(.white)
            .accessibilityIdentifier("douyin.messages.more")
            .popover(isPresented: $showChatOptions) {
                if let web = chatModel.web, let id = navigation.chatID {
                    DYChatOptionsPopover(web: web, conversationID: id) {
                        Task { await readConversations() }
                    }
                    .presentationCompactAdaptation(.popover)
                    .preferredColorScheme(.dark)
                }
            }
            .onChange(of: showChatOptions) { _, showing in
                if !showing, let web = chatModel.web, let id = navigation.chatID {
                    Task { await DYChatWebBridge.closeOptions(web, id: id) }
                }
            }
    }

    private func readConversations() async {
        guard let web = chatModel.web else { return }
        let account = DYMessageCache.shared.accountScope
        guard !account.isEmpty else { return }
        // 读取与合并都交给 DYConversationSync：后台预热和消息页用的是同一套逻辑
        let outcome = await DYConversationSync.read(web: web, account: account)
        guard DYMessageCache.shared.accountScope == account else { return }
        if let status = outcome.status { chatStatus = status }
        if !outcome.rows.isEmpty {
            if conversations != outcome.rows { conversations = outcome.rows }
            if let selected = cache.selectedChat,
               let row = outcome.rows.first(where: { $0.id == selected.id }), row != selected {
                cache.selectedChat = row
            }
            chatStatus = ""
            let unfollowed = unfollowedConversations
            if unfollowed != cache.unfollowedRows { cache.unfollowedRows = unfollowed }
        }
    }

    private func openConversation(_ row: DYConversationRow) async {
        guard openingChat == nil else { return }
        let started = Date()
        openingChat = row.id
        defer { openingChat = nil }
        guard !composer.working else { return }
        guard let web = chatModel.web else {
            chatStatus = "私信页面还没准备好，请稍后再试"
            DYLiveModel.log("DDCHAT open miss no-web")
            return
        }
        // 乐观跳转：点下就进聊天界面（原生表头 + 转圈），DOM 切换在后台完成。
        // 以前要等网页 DOM 切完才跳，那段时间就是老板说的「点了要等很久」。
        chatDOMReady = false
        cache.selectedChat = row
        navigation.openChat(row.id, from: nil)
        var result = await DYChatOpener.open(row, web: web)
        if case .notReady = result {
            try? await Task.sleep(for: .milliseconds(1200))
            result = await DYChatOpener.open(row, web: web)
        }
        switch result {
        case .opened:
            openedFromShare = false
            // 揭开前把所有「之后才会定」的布局一次定好（仍在黑底转圈后面做）：
            //   ① 原生输入框接管：隐藏网页输入框、定高度和底部留白（以前要等 1s 轮询才做 → 输入框跳）
            //   ② 顶部留白（原生表头高度）（以前默认 72，轮询后改成真实值 → 消息整体下移）
            //   ③ 等列表和输入框位置不再变
            let t1 = Date()
            composer.setAccountScope(cache.accountScope)
            await composer.refresh(web: web, id: row.id)
            _ = await DYChatWebBridge.snapshot(web, headerInset: messageTopInset + 72)
            let settled = await DYChatOpener.settle(web)
            guard navigation.chatID == row.id else { return }
            chatDOMReady = true
            DYLiveModel.log("DDCHAT open stranger=\(row.stranger) ms=\(Int(Date().timeIntervalSince(started) * 1000)) prep_ms=\(Int(Date().timeIntervalSince(t1) * 1000)) settle=\(settled.frames)f/\(settled.ms)ms composer=\(composer.isConnected(to: row.id))")
            Task { [weak web] in
                guard let web else { return }
                let shifts = await DYChatOpener.measureShifts(web)
                DYLiveModel.log("DDCHAT_SHIFT id=\(row.id.suffix(6)) after_reveal=\(shifts)")
            }
        case .notReady:
            chatStatus = "私信页面还没加载好，请稍后重试"
            DYLiveModel.log("DDCHAT open miss dom-not-ready")
            rollbackOpen()
        case .notFound:
            chatStatus = "会话位置已变化，正在刷新，请再点一次"
            DYLiveModel.log("DDCHAT open miss not-found")
            rollbackOpen()
            await readConversations()
        }
    }

    /// 打开失败退回列表（乐观跳转的反向操作），别把人留在空白的聊天页
    private func rollbackOpen() {
        chatDOMReady = true
        _ = navigation.back()
        cache.selectedChat = nil
        restoreConversationList()
    }

    private func openSharedConversation(_ receipt: DYForwardReceipt) async {
        guard openingChat == nil else { return }
        openingChat = "forwarded-share"
        defer { openingChat = nil }
        await cache.prepare()
        guard cache.accountScope == receipt.accountScope else {
            actionError = "登录账号已变化，请在消息列表中重新选择会话。"
            return
        }
        guard !composer.working else { return }
        navigation = DYMessageNavigation()
        cache.selectedChat = nil
        for _ in 0..<80 {
            guard !Task.isCancelled, cache.accountScope == receipt.accountScope else { return }
            if let web = chatModel.web, !web.isLoading {
                await DYChatOpener.restoreList(web)
                if let row = await DYChatOpener.openForwarded(receipt.contact, web: web),
                   cache.accountScope == receipt.accountScope {
                    cache.unhide(row.id)
                    cache.selectedChat = row
                    updateConversation(row)
                    openedFromShare = true
                    navigation.openChat(row.id, from: nil)
                    return
                }
                break
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        shareOpenFailed = true
    }

    private func backFromMessage() {
        guard navigation.hasDetail, openingChat == nil else { return }
        #if DEBUG
        let started = Date()
        #endif
        Task {
            guard !composer.working else { return }
            openedFromShare = false
            let wasChat = navigation.isChat
            if navigation.back() { return }
            #if DEBUG
            DYLiveModel.log("DDCHAT_TIMING back_native_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            #endif
            guard wasChat else { return }
            restoreConversationList()
        }
    }

    private func restoreConversationList() {
        // Native cached rows are available immediately; web cleanup is serialized below.
        chatDOMReady = true
        let wasStranger = cache.selectedChat?.stranger == true
        cache.selectedChat = nil
        chatModel.web?.endEditing(true)
        Task {
            if let web = chatModel.web {
                await DYChatOpener.restoreList(web, collapseStrangerPanel: wasStranger)
            }
            await readConversations()
        }
    }

    private func selectCategory(_ route: DYMsgRoute) {
        guard openingChat == nil, !composer.working else { return }
        openedFromShare = false
        visitedRoutes.insert(route)
        let wasChat = navigation.isChat
        navigation.select(route)
        if wasChat { restoreConversationList() }
    }

    /// Lists retain identity/scroll position, while the chat WKWebView stays mounted.
    private var detailPane: some View {
        ZStack {
            ForEach([DYMsgRoute.interactive, .fans, .system, .stranger], id: \.self) { route in
                if visitedRoutes.contains(route) {
                    let visible = !navigation.isChat && navigation.category == route
                    let active = visible
                    Group {
                        if route == .stranger {
                            DYStrangerListScreen(isActive: active, embedded: true,
                                onOpen: { row in navigation.openChat(row.id, from: .stranger) },
                                onOpeningChanged: { openingChat = $0 ? "stranger" : nil })
                        } else {
                            DYNoticeListScreen(bridge: bridge, route: route, onWeb: onWeb,
                                onViewedGroup: { group in viewedGroups[route, default: []].insert(group) },
                                isActive: active, embedded: true)
                        }
                    }
                    .offset(x: !sidebarVisible && !reduceMotion && navigation.isChat && navigation.category == route
                        ? (layoutDirection == .rightToLeft ? 1 : -1) * messageSize.width * 0.18 : 0)
                    .opacity(visible ? 1 : 0)
                    .animation(sidebarVisible ? nil : .easeInOut(duration: reduceMotion ? 0.12 : 0.26), value: navigation.isChat)
                    .allowsHitTesting(active)
                    .accessibilityElement(children: .contain)
                    .accessibilityHidden(!active)
                }
            }
            chatPane
                .offset(x: !sidebarVisible && !reduceMotion && navigation.category != nil && !navigation.isChat
                    ? (layoutDirection == .rightToLeft ? -1 : 1) * messageSize.width : 0)
                .opacity(navigation.isChat ? 1 : 0.001)
                .animation(sidebarVisible ? nil : .easeInOut(duration: reduceMotion ? 0.12 : 0.26), value: navigation.isChat)
                .allowsHitTesting(navigation.isChat)
                .accessibilityHidden(!navigation.isChat)
        }
    }

    @ViewBuilder
    private var chatWeb: some View {
        if DYDMProbe.enabled {
            DYChatProbeSurface(model: chatModel)
        } else {
            DouyinWebContainer(model: chatModel, zoom: 1,
                start: URL(string: "https://www.douyin.com/chat")!, reuseExisting: true)
        }
    }

    private var chatPane: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            chatWeb
                .opacity(chatDOMReady ? 1 : 0)
                .accessibilityIdentifier("douyin.messages.chat.detail")
            if !chatDOMReady, navigation.isChat {
                // 打开会话期间：原生黑底 + 转圈，不露网页的会话列表
                ZStack {
                    Color.black
                    ProgressView().tint(.white)
                }
                .transition(.opacity)
                .allowsHitTesting(true)
            }
            if navigation.isChat, let row = selectedChat {
                let author: DYAweme.Author? = row.kind == 1 && !(row.sec ?? "").isEmpty
                    ? .init(name: row.name, avatar: row.avatar, secUid: row.sec) : nil
                DYChatHeader(row: row, maximumWidth: max(160, messageSize.width - (sidebarVisible ? sidebarWidth : 0) - 24),
                    onProfile: author.map { target in { chatAuthor = target } })
                .padding(12)
                .padding(.top, messageTopInset)
            }
        }
        .overlay(alignment: .bottom) {
            if composer.isConnected(to: navigation.chatID) {
                DYChatComposer(model: composer, active: navigation.isChat && openingChat == nil)
                    .padding(.horizontal, 16).padding(.bottom, composer.bottomInset)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// 陌生人聚合项展开后，进第一屏里第一个真实会话（没有则停在陌生人列表，也能返回）
    /// 主列表：普通会话 + 陌生人聚合项。陌生人二级面板（StrangerConversationList）里的行不算主列表
    static let conversationsJS = #"""
    (() => {
      const accountScope = window.__ddAccountScope || '';
      const inStranger = e => !!e.closest('[class*="StrangerConversationList"]');
      const badgeOf = e => {
        const b = e.querySelector('[class*="UnReadCount"].semi-badge, [class*="digitsNumber"], [class*="badge-count"]');
        if (b && b.textContent.trim()) return b.textContent.trim();
        return e.querySelector('[class*="UnReadCount"], [class*="badge-dot"]') ? '•' : '';
      };
      const convOf = e => {
        const k = Object.keys(e).find(k => k.startsWith('__reactFiber'));
        let f = k ? e[k] : null;
        for (let i = 0; f && i < 6; i++, f = f.return) if (f.memoizedProps?.conversation) return f.memoizedProps.conversation;
        return null;
      };
      const normal = [...document.querySelectorAll('[data-e2e="conversation-item"]')].filter(e => !inStranger(e));
      const box = document.querySelector('[class*="conversationStrangerBoxwrapper"]');
      const rows = normal.map((e, i) => [e, i, false]).concat(box ? [[box, 0, true]] : []);
      const extracted = rows.map(([e, idx, stranger]) => {
        const txt = s => e.querySelector(s)?.textContent?.trim() || '';
        const name = stranger
          ? (txt('[class*="StrangerBoxtitle"]') || '陌生人消息')
          : (txt('[class="conversationConversationItemtitle"]') || e.innerText.split('\n')[0].trim());
        const avatar = e.querySelector('img')?.src || null;
        const preview = txt('[class*="HinttextBox"]') || txt('[class*="StrangerBoxdesc"]') || txt('[class*="ConversationItemDescleft"]');
        const time = txt('[class*="timeStr"]') || txt('[class*="TimeStr"]');
        const c = stranger ? null : convOf(e);
        const lastMessage = c?.lastVisibleMessage || c?.lastMessage;
        const created = Number(c?.lastVisibleMessage?.createdAt || c?.lastMessage?.createdAt);
        const messageID = lastMessage?.serverId || lastMessage?.clientId || lastMessage?.id;
        const lastMessageID = messageID == null ? null : String(messageID);
        const lastMessageTime = Number.isFinite(created) && created > 0 ? (created > 1e11 ? created / 1000 : created) : null;
        const id = stranger ? 'stranger-aggregate' : typeof c?.id === 'string' && c.id ? 'conversation:' + c.id : name + '|' + (avatar || '') + '|' + stranger;
        const flame = e.querySelector('[class*="commonStreakstreakContainer"]');
        const streak = flame ? {text:flame.textContent.trim(),icon:flame.querySelector('img')?.src || null} : null;
        return { id, name, avatar, preview, time, badge: badgeOf(e), index: String(idx), stranger, streak, lastMessageTime, lastMessageID,
                 isPinned: String(e.className || '').includes('isStickOnTop'),
                 kind: c ? Number(c.type) : null, sec: c?.toParticipantSecUserId || null };
      }).filter(x => x.name);
      let state = window.__ddConversationDelta;
      if (!state || state.scope !== accountScope) state = window.__ddConversationDelta = {
        scope: accountScope, baseline: new Map(), sequence: 0, nonce: Date.now() + '-' + Math.random(), pending: null
      };
      const pending = new Map(state.baseline), changed = [];
      for (const row of extracted) {
        const fingerprint = JSON.stringify(row);
        if (state.baseline.get(row.id) !== fingerprint) changed.push(row);
        pending.set(row.id, fingerprint);
      }
      const revision = state.nonce + ':' + (++state.sequence);
      state.pending = {revision, rows: pending};
      return JSON.stringify({items: changed, revision, visible: extracted.length});
    })()
    """#

    /// 只有原生层成功合并后才推进差异基线；异常、换账号、乱序ACK不能吞掉更新。
    static let conversationsAckJS = #"""
    const state = window.__ddConversationDelta;
    if (!state?.pending || state.pending.revision !== revision) return false;
    state.baseline = state.pending.rows; state.pending = null;
    return true;
    """#

    struct ConversationDelta: Decodable {
        let items: [DYConversationRow]
        let revision: String
        let visible: Int
    }

    private static let scrollConversationsJS = #"""
    (() => {
      const root = document.querySelector('[class*="ConversationListwrapper"]');
      if (!root) return false;
      const list = [root, ...root.querySelectorAll('div')].find(e => e.scrollHeight > e.clientHeight + 10 && /auto|scroll/.test(getComputedStyle(e).overflowY));
      if (!list) return false;
      list.scrollTop += list.clientHeight * 0.8;
      list.dispatchEvent(new Event('scroll', { bubbles: true }));
      return true;
    })()
    """#

    private var root: some View {
        VStack(spacing: 0) {
            HStack {
                Text("消息").font(compactSidebar ? .headline : .title2.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(height: theme.messages.headerHeight)
            .padding(.top, messageTopInset)
            .background(theme.messages.sidebarTint)
            .accessibilityIdentifier("douyin.messages.list.title")
            Divider()
            List {
                Group {
                    friendStrip
                    categoryStrip
                    conversationRows
                    if let error, recent.isEmpty {
                        VStack(spacing: 10) {
                            Text(error).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                            Button("重试") { Task { await loadRoot() } }.buttonStyle(.bordered)
                        }
                        .padding(24)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollEdgeEffectHidden(true, for: .all)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("douyin.messages.list")
            .transformAnchorPreference(key: DYMessageRowBoundsKey.self, value: .bounds) { bounds, viewport in
                bounds["viewport"] = viewport
            }
            .refreshable { await loadRoot() }
        }
        .background(theme.messages.sidebarTint)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var friendStrip: some View {
        if !friends.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(friends) { p in
                        Button { openFriend(p) } label: {
                            VStack(spacing: 6) {
                                CachedAsyncImage(url: p.avatar.flatMap(URL.init(string:))) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Circle().fill(Color.white.opacity(0.1))
                                }
                                .frame(width: 58, height: 58)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                Text(p.name)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // 横向 ScrollView 默认会铺进安全区（Duo 侧栏下面），裁回内容框
            .scrollClipDisabled(false)
            .clipped()
        }
    }

    private var categoryStrip: some View {
        Group {
            if compactSidebar {
                Menu {
                    Button("互动消息", systemImage: "heart") { selectCategory(.interactive) }
                    Button("粉丝消息", systemImage: "person") { selectCategory(.fans) }
                    Button("系统消息", systemImage: "bell") { selectCategory(.system) }
                    Button("陌生人消息", systemImage: "person.crop.circle.badge.questionmark") { selectCategory(.stranger) }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "square.grid.2x2").font(.title3)
                        Text("消息分类").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                }
                .accessibilityIdentifier("douyin.messages.categories")
            } else {
                HStack(alignment: .top, spacing: 0) {
                    category(.interactive, icon: "heart.fill", tint: .pink,
                        badge: (counts[DYNoticeGroup.comment.rawValue] ?? 0) + (counts[DYNoticeGroup.digg.rawValue] ?? 0))
                    category(.fans, icon: "person.fill", tint: .blue, badge: counts[DYNoticeGroup.fans.rawValue] ?? 0)
                    category(.system, icon: "bell.fill", tint: .gray, badge: counts[DYNoticeGroup.system.rawValue] ?? 0)
                    category(.stranger, icon: "person.crop.circle.badge.questionmark", tint: .orange, badge: strangerBadge)
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
    }

    private func category(_ route: DYMsgRoute, icon: String, tint: Color, badge: Int) -> some View {
        Button { selectCategory(route) } label: {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 34, height: 34)
                    .background(tint, in: .circle)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : String(badge)).font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(theme.accent.color(for: scheme), in: .capsule)
                                .offset(x: 8, y: -4)
                        }
                    }
                Text(route == .system ? "系统消息" : route.title).font(.caption2)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(navigation.category == route ? theme.accent.color(for: scheme) : .primary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(.rect)
        }
        .accessibilityIdentifier("douyin.messages.\(route)")
        .accessibilityValue(badge > 0 ? "\(badge) 条未读" : "")
    }

    private func loadRoot() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let t0 = Date()
        let cache = DYMessageCache.shared
        await cache.prepare()
        // 先还原本地数据，不清空列表、不挡着等网络；随后只合并增量。
        counts = cache.snapshot.counts
        friends = DYPeopleCache.shared.hasFriendsSnapshot ? DYPeopleCache.shared.friends : cache.snapshot.friends
        if conversations != cache.snapshot.conversations {
            conversations = cache.snapshot.conversations.sorted(by: DYConversationRow.byTimeDesc)
        }
        recent = cache.page(700)?.items ?? []
        // 进信息页的首屏成本：缓存直出花多久（老板要求「打开就不重新加载」）
        DYLiveModel.log("DDMSGROOT cached_ms=\(Int(Date().timeIntervalSince(t0) * 1000)) chats=\(conversations.count) recent=\(recent.count)")
        #if DEBUG
        if DYMessageFixture.enabled { return }
        #endif
        DYLiveModel.log("DDMSGCACHE restore root=\(recent.count) chats=\(conversations.count) friends=\(friends.count)")
        // 三路并发：计数、最近通知、（首次才拉的）朋友列表互不依赖，别排队等
        async let refreshedCounts = bridge.noticeCounts()
        async let refreshedRecent = cache.refresh(700, bridge: bridge)
        async let refreshedFriends = missingFriends()
        if let groups = try? await refreshedCounts {
            counts = Dictionary(groups.map { ($0.group, $0.count) }, uniquingKeysWith: { a, _ in a })
            cache.snapshot.counts = counts
        }
        do {
            recent = try await refreshedRecent.items
            error = nil
        } catch {
            if recent.isEmpty { self.error = error.localizedDescription }
        }
        let fetchedFriends = await refreshedFriends
        if !DYPeopleCache.shared.hasFriendsSnapshot {
            // 朋友没有增量游标：整份只取一次并落盘，之后进消息页不再重拉。
            let fetched = fetchedFriends
            if !fetched.isEmpty {
                DYPeopleCache.shared.mergeFriends(fetched, scope: cache.accountScope, complete: true)
                friends = DYPeopleCache.shared.friends
                cache.snapshot.friends = friends
            }
        } else if friends != DYPeopleCache.shared.friends {
            friends = DYPeopleCache.shared.friends
        }
        cache.save()
    }

    private func missingFriends() async -> [DYFriend] {
        guard !DYPeopleCache.shared.hasFriendsSnapshot else { return [] }
        return (try? await bridge.followingUsers().items) ?? []
    }

    /// Use the same native author screen as the recommendation feed.
    private func openFriend(_ f: DYFriend) {
        guard !f.secUid.isEmpty else { return }
        chatAuthor = .init(name: f.name, avatar: f.avatar, secUid: f.secUid)
    }
}

// MARK: - 二级页（互动 / 粉丝 / 系统）

struct DYNoticeListScreen: View {
    let bridge: DouyinBridge
    let route: DYMsgRoute
    let onWeb: (URL) -> Void
    let onViewedGroup: (Int) -> Void
    let isActive: Bool
    let embedded: Bool
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var emojiStore = DYEmojiStore.shared

    @State private var group: DYNoticeGroup
    @State private var items: [DYNotice] = []
    @State private var maxTime = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var author: DYAweme.Author?
    @State private var player: DYMessagePlay?
    @State private var opening = false
    @State private var loadGen = 0
    @State private var loadedGroup: DYNoticeGroup?
    @State private var activationGeneration = 0
    /// 长评论展开
    @State private var expanded: Set<String> = []
    @State private var truncated: Set<String> = []
    /// 直接回复评论
    @State private var replying: DYNotice?
    @State private var replyDraft = ""
    @State private var replySending = false
    @State private var replyErr: String?
    @State private var replied: Set<String> = []
    @State private var toast: String?
    @FocusState private var replyFocused: Bool

    init(bridge: DouyinBridge, route: DYMsgRoute, onWeb: @escaping (URL) -> Void, onViewedGroup: @escaping (Int) -> Void,
         isActive: Bool = true, embedded: Bool = false) {
        self.bridge = bridge
        self.route = route
        self.onWeb = onWeb
        self.onViewedGroup = onViewedGroup
        self.isActive = isActive
        self.embedded = embedded
        let group = route.filters.first ?? .all
        _group = State(initialValue: group)
        let cached = DYMessageCache.shared.page(group.rawValue)
        _items = State(initialValue: cached?.items ?? [])
        _maxTime = State(initialValue: cached?.maxTime ?? 0)
        _hasMore = State(initialValue: cached?.hasMore ?? true)
    }

    var body: some View {
        presentedList.frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if opening { ProgressView().tint(.white) } }
        .background(Color.black.ignoresSafeArea())

        .foregroundStyle(.white)
        .task(id: "\(group.rawValue):\(isActive)") {
            guard isActive else { return }
            // 进哪个分类就记下它对应的服务端分组，退出时一起标已读（评论+赞同属互动）
            route.readGroups.forEach { onViewedGroup($0) }
            if loadedGroup != group {
                let requested = group
                await reload(reset: true)
                if !Task.isCancelled { loadedGroup = requested }
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_READ_AUDIT"] == "1", let values = try? await bridge.noticeCounts() {
                DYLiveModel.log("DDREADAUDIT inside-category " + values.map { "\($0.group)=\($0.count)" }.joined(separator: ","))
            }
            #endif
        }
        .task(id: isActive) { if isActive { await emojiStore.load(bridge: bridge) } }
        .onChange(of: isActive) { _, active in
            activationGeneration += 1
            if !active { replyFocused = false }
        }
        .sheet(item: $author) { a in
            NavigationStack {
                DYAuthorScreen(bridge: bridge, author: a, onWeb: onWeb)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(.black)
        }
        .fullScreenCover(item: $player) { p in
            DYListPlayer(bridge: bridge, title: p.item.desc.isEmpty ? "视频" : p.item.desc, items: [p.item], start: 0,
                         onAuthor: { author = $0.author }, commentFocus: p.focus)
        }
        .safeAreaInset(edge: .bottom) { if replying != nil { replyBar } }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .padding(.bottom, replying == nil ? 40 : 120)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: 直接回复评论

    @ViewBuilder
    private var presentedList: some View {
        if embedded {
            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    if route.filters.count > 1 {
                        Menu { filterChoices } label: {
                            HStack(spacing: 6) {
                                Text(route.filterTitle(group))
                                Image(systemName: "chevron.down").font(.caption)
                            }
                            .font(.headline)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("douyin.notice.filter")
                    } else {
                        Text(route.title).font(.headline).padding(.vertical, 14)
                    }
                    Spacer(minLength: 0)
                }
                .background(theme.media.strongScrim.color(for: scheme))
                Divider()
                list
            }
        } else {
            list
                .navigationTitle(route.filterTitle(group))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { filterChoices }
        }
    }

    private var filterChoices: some View {
        ForEach(route.filters) { g in
            Button { group = g } label: {
                if g == group { Label(route.filterTitle(g), systemImage: "checkmark") }
                else { Text(route.filterTitle(g)) }
            }
            .accessibilityIdentifier("douyin.notice.filter.\(g.rawValue)")
        }
    }

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let n = replying {
                HStack(spacing: 6) {
                    Text("回复 @\(n.name.isEmpty ? "抖音用户" : n.name)").font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    Spacer()
                    Button { closeReply() } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                        .accessibilityIdentifier("douyin.notice.reply.cancel")
                }
            }
            if let e = replyErr { Text(e).font(.caption2).foregroundStyle(.red) }
            HStack(spacing: 8) {
                TextField("回复评论…", text: $replyDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($replyFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .accessibilityIdentifier("douyin.notice.reply.input")
                if replyFocused {
                    Button { replyFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.body)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel("收起键盘")
                }
                let empty = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { Task { await sendReply() } } label: {
                    if replySending { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "paperplane.fill").font(.body.weight(.semibold)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(empty ? Color.white.opacity(0.35) : Color.white)
                .disabled(empty || replySending)
                .accessibilityIdentifier("douyin.notice.reply.send")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private func startReply(_ n: DYNotice) {
        if replying?.id != n.id { replyDraft = "" }
        replying = n; replyErr = nil
        replyFocused = true
    }

    private func closeReply() {
        replying = nil; replyDraft = ""; replyErr = nil; replyFocused = false
    }

    private func sendReply() async {
        guard let n = replying, let aweme = n.awemeID, let cid = n.cid else { return }
        let text = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !replySending else { return }
        replySending = true
        defer { replySending = false }
        do {
            // 一级评论：reply_id = 它；楼中楼：reply_id = 一级评论、reply_to_reply_id = 这条（网页同款）
            _ = try await bridge.publishComment(aweme, text: text, replyID: n.parentCid ?? cid,
                                                replyToReplyID: n.parentCid == nil ? nil : cid)
            replied.insert(n.id)
            closeReply()
            showToast("已回复")
        } catch {
            replyErr = "发送失败：\(error.localizedDescription)"
        }
    }

    private func showToast(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if toast == s { toast = nil } }
    }

    /// 互动「全部」走 700 分组，要剔掉关注和系统类
    private var visibleItems: [DYNotice] {
        guard route == .interactive, group == .all else { return items }
        return items.filter(DYNoticeKind.isInteractive)
    }

    @ViewBuilder
    private var list: some View {
        if let error, items.isEmpty {
            VStack(spacing: 12) {
                Text(error).font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                Button("重试") { Task { await reload(reset: true) } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if items.isEmpty && loading {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleItems.isEmpty && !hasMore {
            Text("暂无消息").font(.footnote).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleItems) { n in
                        VStack(alignment: .leading, spacing: 0) {
                            Button { Task { await open(n) } } label: { row(n) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(n.isComment ? "douyin.notice.comment" : (n.awemeID == nil ? "douyin.notice.author" : "douyin.notice.video"))
                                .accessibilityValue(n.hasRead ? "已读" : "未读")
                            if n.isComment { commentActions(n) }
                        }
                        Divider().background(Color.white.opacity(0.08))
                    }
                    if hasMore {
                        ProgressView().tint(.white).padding()
                            .onAppear { Task { await reload(reset: false) } }
                    }
                }
            }
            .refreshable { await reload(reset: true) }
        }
    }

    private func row(_ n: DYNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(url: n.avatar.flatMap(URL.init(string:))) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                if !n.hasRead {
                    Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: 2, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(n.name.isEmpty ? "抖音用户" : n.name)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if n.isComment {
                    Text(n.action).font(.caption).foregroundStyle(.white.opacity(0.5))
                    commentText(n)
                    if let q = n.quote, !q.isEmpty {
                        HStack(spacing: 6) {
                            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2)
                            emojiStore.rich(q).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    emojiStore.rich(n.detail.isEmpty ? n.action : "\(n.action) · \(n.detail)")
                        .font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
                // 评论配图：最多显示 3 张缩略图
                if let imgs = n.images, !imgs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(imgs.prefix(3)), id: \.self) { s in
                            CachedAsyncImage(url: URL(string: s)) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .padding(.top, 2)
                    .accessibilityIdentifier("douyin.notice.commentImages")
                }
                Text(DYFormat.time(n.time)).font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            if let c = n.cover, let u = URL(string: c) {
                CachedAsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }
                    .frame(width: 44, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// 评论正文：默认 3 行，超出才出「展开」
    private func commentText(_ n: DYNotice) -> some View {
        let open = expanded.contains(n.id)
        var detail = n.detail
        #if DEBUG
        // 验收用：把评论正文拉长，检查「展开」只在超过 3 行时出现
        if ProcessInfo.processInfo.environment["DOUDUO_LONGNOTICE"] == "1" { detail = String(repeating: detail + "。", count: 5) }
        #endif
        let text = emojiStore.rich(detail).font(.subheadline)
        return text
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(open ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                // 量完整高度和 3 行高度，比较是否被截断
                ZStack {
                    text.fixedSize(horizontal: false, vertical: true).hidden()
                        .background(GeometryReader { full in
                            text.lineLimit(3).fixedSize(horizontal: false, vertical: true).hidden()
                                .background(GeometryReader { cut in
                                    Color.clear.onAppear { markTruncated(n.id, full.size.height > cut.size.height + 1) }
                                        .onChange(of: full.size.height) { _, h in markTruncated(n.id, h > cut.size.height + 1) }
                                })
                        })
                }
                .hidden()
            }
    }

    private func markTruncated(_ id: String, _ isCut: Bool) {
        if isCut { if !truncated.contains(id) { truncated.insert(id) } }
        else if truncated.contains(id) { truncated.remove(id) }
    }

    /// 评论下方：展开/收起 + 回复
    private func commentActions(_ n: DYNotice) -> some View {
        HStack(spacing: 18) {
            if truncated.contains(n.id) {
                let open = expanded.contains(n.id)
                Button {
                    withAnimation(.snappy) { if open { expanded.remove(n.id) } else { expanded.insert(n.id) } }
                } label: {
                    Label(open ? "收起" : "展开", systemImage: open ? "chevron.up" : "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityIdentifier("douyin.notice.expand")
            }
            Button { startReply(n) } label: {
                Label(replied.contains(n.id) ? "已回复" : "回复", systemImage: "arrowshape.turn.up.left")
            }
            .accessibilityIdentifier("douyin.notice.reply")
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.leading, 70)
        .padding(.trailing, 16)
        .padding(.top, -4)
        .padding(.bottom, 12)
    }

    private func reload(reset: Bool) async {
        guard isActive else { return }
        if !reset && (!hasMore || loading) { return }
        loadGen += 1
        let gen = loadGen
        let requestedGroup = group.rawValue
        let cache = DYMessageCache.shared
        loading = true
        defer { if gen == loadGen { loading = false } }
        if reset {
            let cached = cache.page(requestedGroup)
            items = cached?.items ?? []
            maxTime = cached?.maxTime ?? 0
            hasMore = cached?.hasMore ?? true
            error = nil
        }
        do {
            let page: DYCachedNoticePage
            if reset {
                page = try await cache.refresh(requestedGroup, bridge: bridge)
            } else {
                let next = try await bridge.notices(group: requestedGroup, maxTime: maxTime)
                let seen = Set(items.map(\.id))
                page = DYCachedNoticePage(items: items + next.items.filter { !seen.contains($0.id) },
                                          maxTime: next.maxTime,
                                          hasMore: next.hasMore && !next.items.isEmpty && next.maxTime != maxTime)
                cache.store(page, group: requestedGroup)
            }
            guard gen == loadGen, !Task.isCancelled else { return }
            items = page.items
            maxTime = page.maxTime
            hasMore = page.hasMore
            error = nil
            DYLiveModel.log("DDNOTICE group=\(requestedGroup) n=\(items.count) read=deferred-until-exit")
        } catch {
            guard gen == loadGen, !Task.isCancelled else { return }
            if items.isEmpty { self.error = error.localizedDescription }
            DYLiveModel.log("DDNOTICE error \(error.localizedDescription)")
        }
    }

    private func open(_ n: DYNotice) async {
        guard isActive else { return }
        let generation = activationGeneration
        if n.type == 33, let a = n.author {
            author = a
            return
        }
        guard let id = n.awemeID, !id.isEmpty, id != "0" else {
            if let a = n.author { author = a }
            return
        }
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do {
            let item = try await bridge.awemeDetail(id)
            guard generation == activationGeneration else { return }
            // 评论通知：进视频直接打开评论区并定位到这条评论
            player = DYMessagePlay(item: item, focus: n.commentFocus)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 公共部件


// MARK: - 打开会话（root 与陌生人二级页共用）

/// 私信走网页：普通会话在主列表（onMouseDown 选中）；陌生人先点「陌生人消息」聚合项（React onClick）
/// 展开 StrangerConversationList 面板，面板里每个人同样是 conversation-item（onMouseDown）。
@MainActor
enum DYChatOpener {
    enum Result { case opened, notReady, notFound }

    /// 等聊天网页「不再动」：消息列表高度、输入框位置连续 3 帧不变才算稳（最多 ~700ms）。
    /// 揭开前调用——以前一切换就揭开，老板看到的是网页边渲染边挪输入框、挪消息。
    /// 返回 (采样次数, 毫秒)。
    static func settle(_ web: WKWebView) async -> (frames: Int, ms: Int) {
        let js = #"""
        const t0 = performance.now();
        const sig = () => {
          const list = document.querySelector('[class*="messageMessageListlist"]');
          const input = document.querySelector('[class*="componentsRightPanelinputArea"]');
          const r = input?.getBoundingClientRect();
          return [list?.scrollHeight || 0, r ? Math.round(r.top) : -1, r ? Math.round(r.height) : -1].join('|');
        };
        let last = '', same = 0, n = 0;
        while (n < 18 && same < 3) {
          await new Promise(r => requestAnimationFrame(() => setTimeout(r, 30)));
          const s = sig(); same = (s === last) ? same + 1 : 0; last = s; n++;
        }
        // 输入框最终位置定了，再定一次消息列表底部留白，免得揭开后再跳
        const ir = document.querySelector('[class*="messageMsgInputinputRow"]')?.getBoundingClientRect();
        if (ir && ir.height > 0) document.documentElement.style.setProperty('--dd-composer-inset', (innerHeight - ir.top + 16) + 'px');
        return n + ',' + Math.round(performance.now() - t0);
        """#
        guard let r = (try? await web.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)) as? String else { return (0, 0) }
        let parts = r.split(separator: ",").compactMap { Int($0) }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }

    /// 揭开后 1.5s 内输入框/列表还挪了几次（验证用，正常应为 0）
    static func measureShifts(_ web: WKWebView) async -> Int {
        let js = #"""
        const sig = () => {
          const list = document.querySelector('[class*="messageMessageListlist"]');
          const input = document.querySelector('[class*="componentsRightPanelinputArea"]');
          const r = input?.getBoundingClientRect();
          return [list ? Math.round(list.getBoundingClientRect().top) : -1, r ? Math.round(r.top) : -1].join('|');
        };
        let last = sig(), shifts = 0;
        for (let i = 0; i < 30; i++) {
          await new Promise(r => setTimeout(r, 50));
          const s = sig(); if (s !== last) { shifts++; last = s; }
        }
        return shifts;
        """#
        return ((try? await web.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)) as? NSNumber)?.intValue ?? -1
    }

    /// Serialize DOM mutations. Foreground navigation cancels the scan before
    /// acquiring this lock; scan cleanup must finish before a new chat opens.
    private static var busy: Task<Void, Never>?
    private static func exclusive<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        while let running = busy { await running.value; if busy == running { busy = nil } }
        var result: T?
        let t = Task { @MainActor in result = await work() }
        busy = t
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        if busy == t { busy = nil }
        return result!
    }
    private static weak var visibleChatWeb: WKWebView?

    static func waitFor(_ web: WKWebView, _ selector: String, timeoutMS: Int = 12000) async -> Bool {
        let probe = "document.querySelectorAll(" + jsString(selector) + ").length"
        var waited = 0
        while waited < timeoutMS, !Task.isCancelled {
            // 页面加载中查到的 0 会被误判成「没有会话」
            // evaluateJavaScript 的数字回来是 NSNumber（可能桥成 Double），统一按 NSNumber 取
            if !web.isLoading, let n = (try? await web.evaluateJavaScript(probe)) as? NSNumber, n.intValue > 0 { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
            waited += 50
        }
        return false
    }

    private static weak var scanWeb: WKWebView?
    private static var scanTask: Task<[DYConversationRow]?, Never>?
    private static var scanID: UUID?
    private static var scanScope = ""
    private static weak var cachedWeb: WKWebView?
    private static var cachedScope = ""
    private static var cachedRows: [DYConversationRow] = []
    private static var cachedAt = Date.distantPast

    /// User navigation interrupts the JS scan at its next 25 ms yield. The lock
    /// stays held until cleanup finishes, so an old scan cannot close a new chat.
    static func cancelStrangerScan() async {
        guard let task = scanTask else { return }
        task.cancel()
        if let web = scanWeb {
            _ = try? await web.evaluateJavaScript("window.__ddStrangerScan = null; true")
        }
        _ = await task.value
    }

    static func strangerRows(_ web: WKWebView) async -> [DYConversationRow]? {
        let account = DYMessageCache.shared.accountScope
        if cachedWeb === web, cachedScope == account, Date().timeIntervalSince(cachedAt) < 60 {
            #if DEBUG
            DYLiveModel.log("DDSTRANGER_TIMING cache_hit rows=\(cachedRows.count)")
            #endif
            return cachedRows
        }
        if let running = scanTask {
            if scanWeb === web, scanScope == account {
                let rows = await running.value
                guard !running.isCancelled, !Task.isCancelled, DYMessageCache.shared.accountScope == account else { return nil }
                return rows
            }
            await cancelStrangerScan()
        }
        guard visibleChatWeb !== web, !Task.isCancelled else { return nil }
        #if DEBUG
        let started = Date()
        DYLiveModel.log("DDSTRANGER_TIMING scan_start")
        #endif
        let id = UUID()
        scanID = id
        scanWeb = web
        scanScope = account
        let task = Task { @MainActor () -> [DYConversationRow]? in
            await exclusive {
                guard !Task.isCancelled, visibleChatWeb !== web else { return nil }
                return await strangerRowsUnlocked(web, token: id.uuidString)
            }
        }
        scanTask = task
        let rows = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor in
                guard scanID == id else { return }
                await cancelStrangerScan()
            }
        }
        #if DEBUG
        DYLiveModel.log("DDSTRANGER_TIMING scan_end_ms=\(Int(Date().timeIntervalSince(started) * 1000)) rows=\(rows?.count ?? 0) cancelled=\(task.isCancelled)")
        #endif
        if scanID == id { scanID = nil; scanTask = nil; scanWeb = nil }
        guard !task.isCancelled, !Task.isCancelled, DYMessageCache.shared.accountScope == account else { return nil }
        if let rows {
            cachedWeb = web; cachedScope = account; cachedRows = rows; cachedAt = Date()
        }
        return rows
    }

    private static func scanScript(_ script: String) -> String {
        let sleep = "const sleep = ms => new Promise(r => setTimeout(r, ms));"
        let cancellable = """
        const sleep = async ms => {
          const end = Date.now() + ms;
          do {
            if (window.__ddStrangerScan !== token) throw new Error('scan cancelled');
            await new Promise(r => setTimeout(r, Math.min(25, Math.max(0, end - Date.now()))));
          } while (Date.now() < end);
          if (window.__ddStrangerScan !== token) throw new Error('scan cancelled');
        };
        """
        return "if (window.__ddStrangerScan !== token) throw new Error('scan cancelled');\n" + script.replacingOccurrences(of: sleep, with: cancellable)
    }

    private static func strangerRowsUnlocked(_ web: WKWebView, token: String) async -> [DYConversationRow]? {
        guard visibleChatWeb !== web, !Task.isCancelled else { return nil }
        _ = try? await web.callAsyncJavaScript("window.__ddStrangerScan = token;", arguments: ["token": token], contentWorld: .page)
        guard await waitFor(web, "[data-e2e=\"conversation-item\"], [class*=\"conversationStrangerBoxwrapper\"]"), !Task.isCancelled else { return nil }
        let shown: Int
        do {
            guard let value = try await web.callAsyncJavaScript(scanScript(openStrangerPanelJS), arguments: ["token": token], contentWorld: .page) as? NSNumber else { return nil }
            shown = value.intValue
        } catch {
            #if DEBUG
            let failure = error as NSError
            DYLiveModel.log("DDSTRANGER_TIMING scan_error code=\(failure.code)")
            #endif
            await collapseStranger(web)
            return nil
        }
        if shown == 0, !Task.isCancelled {
            await collapseStranger(web)
            return []
        }
        let json: String?
        if shown > 0, !Task.isCancelled {
            json = try? await web.callAsyncJavaScript(scanScript(collectStrangerJS), arguments: ["token": token], contentWorld: .page) as? String
        } else { json = nil }
        await collapseStranger(web)
        guard !Task.isCancelled, let json, let data = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([DYConversationRow].self, from: data) else { return nil }
        return rows
    }

    /// 打开一个会话：普通会话在主列表里找；陌生人在展开后的陌生人面板里找。按名字+头像精确匹配，不按位置猜。
    /// Shell classes verified from a live read-only IM layout capture. Keep all message,
    /// composer, attachment and event-handler subtrees unchanged.
    static let chatChromeCSS = #"""
    :root { --dd-chat-canvas: __DD_CHAT_CANVAS__; --dd-chat-separator: __DD_CHAT_SEPARATOR__; }
    html, body { width:100%!important; min-width:0!important; height:100%!important; margin:0!important; overflow:hidden!important; background:transparent!important; }
    .dd-chat-ancestor { background:transparent!important; }
    .dd-chat-page-sibling { visibility:hidden!important; pointer-events:none!important; }
    #douyin-temp-sidebar { display:none!important; }
    .chatDark { position:fixed!important; inset:0!important; width:100%!important; height:100%!important; max-height:none!important; border:0!important; border-radius:0!important; background:transparent!important; }
    [class*="componentsEntrywrapper"] > .semi-resizable-resizable { display:none!important; }
    [class*="componentsEntrywrapper"] { box-sizing:border-box!important; min-width:0!important; width:100%!important; height:100%!important; max-height:none!important; margin:0!important; border:0!important; border-radius:0!important; background:transparent!important; }
    [class*="componentsRightPanelwrapper"] { box-sizing:border-box!important; width:100%!important; max-width:none!important; flex:1!important; min-width:0!important; min-height:0!important; height:100%!important; background:transparent!important; }
    [class*="RightPanelHeaderconvHeader"] { display:none!important; }
    [class*="componentsRightPanelnotHeaderArea"] { position:relative!important; flex:1!important; min-height:0!important; background:transparent!important; }
    [class*="messageMessageListwrapper"] { flex:1!important; min-height:0!important; height:100%!important; background:transparent!important; }
    [class*="messageMessageListlist"] { box-sizing:border-box!important; padding-top:var(--dd-header-inset,72px)!important; padding-bottom:var(--dd-composer-inset,100px)!important; scroll-padding-top:var(--dd-header-inset,72px); scroll-padding-bottom:var(--dd-composer-inset,100px); background:transparent!important; }
    [class*="componentsRightPanelinputArea"] { position:absolute!important; inset:auto 0 0!important; z-index:2; box-sizing:border-box!important; padding:8px 16px var(--dd-native-composer-bottom,24px)!important; background:transparent!important; border:0!important; }
    [class*="messageMsgInputcontainer"], [class*="messageMsgInputinputColumn"] { background:transparent!important; border:0!important; padding:0!important; }
    [class*="messageMsgInputinputRow"] { position:relative!important; box-sizing:border-box!important; width:100%!important; min-height:44px!important; padding:4px 12px!important; border:0!important; border-radius:999px!important; background:#242424!important; align-items:center!important; }
    html[data-dd-native-composer] [class*="messageMsgInputinputRow"] { height:var(--dd-native-composer-height,44px)!important; opacity:0!important; pointer-events:none!important; }
    [class*="messageEditorimChatEditorContainer"] { min-width:0!important; flex:1!important; background:transparent!important; }
    [class*="messageEditorinputArea"] { min-height:28px!important; max-height:160px!important; overflow-y:auto!important; background:transparent!important; border:0!important; }
    [class*="messageMsgInputinputAction"] { flex-shrink:0!important; background:transparent!important; }
    html[data-dd-row-action] [class*="ConversationItemMenuwrapper"] { visibility:hidden!important; pointer-events:none!important; }
    [class*="conversationConversationInfowrapper"] { position:absolute!important; right:0!important; width:300px!important; visibility:hidden!important; pointer-events:none!important; }
    """#

    static func change(_ row: DYConversationRow, action: DYChatWebBridge.Action, web: WKWebView) async throws {
        await cancelStrangerScan()
        let success = await exclusive {
            do { try await DYChatWebBridge.change(row, action: action, web: web); return true }
            catch { return false }
        }
        if !success { throw DYChatWebBridge.BridgeError.unavailable }
    }

    static func open(_ row: DYConversationRow, web: WKWebView) async -> Result {
        await cancelStrangerScan()
        return await exclusive {
            let r = await openUnlocked(row, web: web)
            if case .opened = r { visibleChatWeb = web }
            return r
        }
    }

    /// 上游「分享成功后直接打开那条会话」：依赖上游单人转发的回执与官网运行时。
    /// 本分支保留自己的多人转发，不产生回执，所以这里不会被调用。
    static func openForwarded(_ contact: DYForwardContact, web: WKWebView) async -> DYConversationRow? {
        nil
    }

    private static func openUnlocked(_ row: DYConversationRow, web: WKWebView) async -> Result {
        let scope = row.stranger ? "[class*=\"StrangerConversationList\"] " : ""
        if row.stranger {
            guard await waitFor(web, "[data-e2e=\"conversation-item\"], [class*=\"conversationStrangerBoxwrapper\"]") else { return .notReady }
            let shown = ((try? await web.callAsyncJavaScript(openStrangerPanelJS, arguments: [:], contentWorld: .page)) as? NSNumber)?.intValue ?? 0
            guard shown > 0 else { return .notFound }
        } else {
            await collapseStranger(web)
        }
        guard await waitFor(web, scope + "[data-e2e=\"conversation-item\"]") else { return .notReady }
        let script = #"""
          const inStranger = e => !!e.closest('[class*="StrangerConversationList"]');
          const titleOf = e => (e.querySelector('[class="conversationConversationItemtitle"]')?.textContent || '').trim();
          const find = () => {
            const rows = [...document.querySelectorAll('[data-e2e="conversation-item"]')].filter(e => (stranger === '1') === inStranger(e));
            if (id.startsWith('conversation:')) {
              const exact = rows.find(e => {
                let f=e[Object.keys(e).find(k=>k.startsWith('__reactFiber'))];
                for(let i=0;f && i<8;i++,f=f.return) if(f.memoizedProps?.conversation) return 'conversation:'+f.memoizedProps.conversation.id === id;
                return false;
              });
              return exact || null;
            }
            const exact = rows.filter(e => titleOf(e) === name && (!avatar || e.querySelector('img')?.src === avatar));
            if(exact.length === 1) return exact[0];
            const named=rows.filter(e=>titleOf(e) === name);
            return named.length === 1 ? named[0] : null;
          };
          let row = find();
          // 虚拟列表：不在可视区就逐屏往下找
          if (!row) {
            const wrap = document.querySelector(stranger === '1' ? '[class*="StrangerConversationListlistWrapper"]' : '[class*="ConversationListwrapper"]');
            const sc = wrap && [wrap, ...wrap.querySelectorAll('div')].find(e => e.scrollHeight > e.clientHeight + 5);
            if (sc) {
              sc.scrollTop = 0; sc.dispatchEvent(new Event('scroll', { bubbles: true }));
              for (let i = 0; i < 40 && !row; i++) {
                await new Promise(r => setTimeout(r, 200));
                row = find();
                if (row || sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 2) break;
                sc.scrollTop += Math.max(200, sc.clientHeight * 0.8);
                sc.dispatchEvent(new Event('scroll', { bubbles: true }));
              }
            }
          }
          if (!row) return 'miss';
          row.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 }));
          let style = document.getElementById('dd-chat-only');
          if (!style) { style = document.createElement('style'); style.id = 'dd-chat-only'; document.head.append(style); }
          style.textContent = appearanceCSS;
          window.__ddNativeChatID = id;
          // The website also paints backdrops outside the IM ancestor chain.
          // Hide those existing siblings so transparent input chrome exposes
          // the native glass rather than the site's full-width page canvas.
          for (let e=document.querySelector('[class*="componentsEntrywrapper"]');e?.parentElement;e=e.parentElement) {
            e.parentElement.classList.add('dd-chat-ancestor');
            for (const sibling of e.parentElement.children) {
              if (sibling !== e && !['HEAD','STYLE','SCRIPT','LINK','META'].includes(sibling.tagName)) sibling.classList.add('dd-chat-page-sibling');
            }
          }
          window.__wuweiMinWidth = 320;
          window.__wuweiFixViewport?.();
          window.dispatchEvent(new Event('resize'));
          return 'ok';
        """#
        let colors = DDTheme().messages
        let appearanceCSS = chatChromeCSS
            .replacingOccurrences(of: "__DD_CHAT_CANVAS__", with: colors.canvasCSS)
            .replacingOccurrences(of: "__DD_CHAT_SEPARATOR__", with: colors.separatorCSS)
        let r = try? await web.callAsyncJavaScript(script, arguments: ["id": row.id, "name": row.name, "avatar": row.avatar ?? "", "stranger": row.stranger ? "1" : "0", "appearanceCSS": appearanceCSS], contentWorld: .page)
        if (r as? String) == "ok" { return .opened }
        DYLiveModel.log("DDCHAT opener miss stranger=\(row.stranger)")
        return .notFound
    }

    static func restoreList(_ web: WKWebView, collapseStrangerPanel: Bool = false) async {
        await cancelStrangerScan()
        await exclusive {
        visibleChatWeb = nil
        _ = try? await web.evaluateJavaScript("document.getElementById('dd-chat-only')?.remove(); document.querySelectorAll('.dd-chat-ancestor').forEach(e=>e.classList.remove('dd-chat-ancestor')); document.querySelectorAll('.dd-chat-page-sibling').forEach(e=>e.classList.remove('dd-chat-page-sibling')); window.__ddNativeChatID=null; delete document.documentElement.dataset.ddNativeComposer; document.querySelectorAll('[class*=messageMsgInputinputRow]').forEach(e=>e.removeAttribute('aria-hidden')); document.querySelectorAll('[class*=messageMsgInputinputRow] [contenteditable]').forEach(e=>e.removeAttribute('inputmode')); true")
        if collapseStrangerPanel { await collapseStranger(web) }
        }
    }

    private static func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(data: d, encoding: .utf8)!.dropFirst().dropLast())
    }

    /// 收起陌生人面板（面板头部「‹ 陌生人消息」挂的 React onClick），回到主会话列表
    static let collapseStrangerJS = #"""
    (() => {
      const h = document.querySelector('[class*="StrangerConversationListhead"]');
      if (!h) return 'closed';
      const k = Object.keys(h).find(k => k.startsWith('__reactProps'));
      if (k && h[k].onClick) { h[k].onClick({ stopPropagation(){}, preventDefault(){}, currentTarget: h, target: h }); return 'react'; }
      h.click(); return 'click';
    })()
    """#

    static func collapseStranger(_ web: WKWebView) async {
        guard let result = try? await web.evaluateJavaScript(collapseStrangerJS) as? String,
              result != "closed" else { return }
        for _ in 0..<20 {
            let open = (try? await web.evaluateJavaScript("!!document.querySelector('[class*=StrangerConversationListhead]')")) as? Bool ?? false
            if !open { return }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
    }

    /// 主列表是虚拟列表，「陌生人消息」聚合项可能不在可视区：先从顶部逐屏找到它，再调 React onClick 展开。
    /// 展开后等行数稳定（隐藏的网页渲染慢，首屏常常只有 1 行）。返回 true = 面板已展开且有行。
    static let openStrangerPanelJS = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const rowSel = '[class*="StrangerConversationList"] [data-e2e="conversation-item"]';
    if (!document.querySelector(rowSel)) {
      const findBox = () => document.querySelector('[class*="conversationStrangerBoxwrapper"]');
      let box = findBox();
      if (!box) {
        const wrap = document.querySelector('[class*="ConversationListwrapper"]');
        const sc = wrap && [wrap, ...wrap.querySelectorAll('div')].find(e => e.scrollHeight > e.clientHeight + 5);
        if (sc) {
          sc.scrollTop = 0; sc.dispatchEvent(new Event('scroll', { bubbles: true })); await sleep(250);
          for (let i = 0; i < 40 && !(box = findBox()); i++) {
            if (sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 2) break;
            sc.scrollTop += Math.max(200, sc.clientHeight * 0.8);
            sc.dispatchEvent(new Event('scroll', { bubbles: true })); await sleep(250);
          }
        }
      }
      if (!box) return false;
      const k = Object.keys(box).find(k => k.startsWith('__reactProps'));
      if (k && box[k].onClick) box[k].onClick({ stopPropagation(){}, preventDefault(){}, currentTarget: box, target: box }); else box.click();
    }
    // Opening a chat only needs the first mounted row; full collection owns pagination.
    for (let waited = 0; waited < 12000; waited += 50) {
      const n = document.querySelectorAll(rowSel).length;
      if (n > 0) return n;
      await sleep(50);
    }
    return 0;
    """#

    /// 逐屏滚动虚拟列表采集全部陌生人会话（callAsyncJavaScript 函数体，可 await）
    private static let collectStrangerJS = #"""
    const sel = '[class*="StrangerConversationList"] [data-e2e="conversation-item"]';
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    // A cold panel may initially mount only one row. Stabilization belongs to
    // this cancellable background collection, never the foreground chat opener.
    if (document.querySelectorAll(sel).length <= 1) {
      for (let waited = 0; waited < 4000; waited += 100) {
        await sleep(100);
        if (document.querySelectorAll(sel).length > 1) break;
      }
    }
    const wrap = document.querySelector('[class*="StrangerConversationListlistWrapper"]');
    const sc = wrap && [wrap, ...wrap.querySelectorAll('div')].find(e => e.scrollHeight > e.clientHeight + 5);
    const seen = new Map();
    let order = 0;
    const grab = () => document.querySelectorAll(sel).forEach(e => {
      const txt = s => e.querySelector(s)?.textContent?.trim() || '';
      const name = txt('[class="conversationConversationItemtitle"]');
      if (!name) return;
      const avatar = e.querySelector('img')?.src || null;
      const id = 's|' + name + '|' + (avatar || '');
      if (seen.has(id)) return;
      const b = e.querySelector('[class*="UnReadCount"].semi-badge, [class*="digitsNumber"]');
      const badge = b && b.textContent.trim() ? b.textContent.trim() : (e.querySelector('[class*="UnReadCount"]') ? '•' : '');
      const y = e.getBoundingClientRect().top + (sc ? sc.scrollTop : 0);
      seen.set(id, { id, name, avatar, preview: txt('[class*="HinttextBox"]'), time: txt('[class*="timeStr"]'), observedAt: Date.now()/1000, badge, index: '0', stranger: true, _y: y, _o: order++ });
    });
    grab();
    if (sc) {
      sc.scrollTop = 0; sc.dispatchEvent(new Event('scroll', { bubbles: true })); await sleep(250); grab();
      for (let i = 0; i < 80; i++) {
        if (sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 2) {
          // 到底了：等网页懒加载下一页，高度不再增长才算真到底
          const h = sc.scrollHeight; let grew = false;
          for (let w = 0; w < 4; w++) { await sleep(400); if (sc.scrollHeight > h) { grew = true; break; } }
          if (!grew) break;
        }
        sc.scrollTop += Math.max(200, sc.clientHeight * 0.8);
        sc.dispatchEvent(new Event('scroll', { bubbles: true }));
        await sleep(250); grab();
      }
      sc.scrollTop = 0; sc.dispatchEvent(new Event('scroll', { bubbles: true }));
    }
    const rows = [...seen.values()].sort((a, b) => a._y - b._y || a._o - b._o)
      .map((r, i) => { delete r._y; delete r._o; r.index = String(i); return r; });
    return JSON.stringify(rows);
    """#
}

// MARK: - 陌生人消息（原生二级页）

struct DYStrangerListScreen: View {
    var isActive = true
    var embedded = false
    var onOpen: ((DYConversationRow) -> Void)? = nil
    var onOpeningChanged: (Bool) -> Void = { _ in }
    @ObservedObject private var cache = DYMessageCache.shared
    @Environment(\.dismiss) private var dismiss
    @State private var status = "正在读取陌生人消息…"
    @State private var opening: String?

    /// Merge both sources, then keep the same pin/time ordering as the main list.
    private var allRows: [DYConversationRow] {
        let ids = Set(cache.unfollowedRows.map(\.id))
        return (cache.unfollowedRows + cache.strangerRows.filter { !ids.contains($0.id) }).sorted(by: DYConversationRow.byTimeDesc)
    }

    @ViewBuilder var body: some View {
        if embedded {
            content.safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Text(DYMsgRoute.stranger.title).font(.headline).padding(.vertical, 14)
                    Divider()
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            content.navigationTitle(DYMsgRoute.stranger.title).navigationBarTitleDisplayMode(.inline)
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if allRows.isEmpty {
                    Text(status).font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(28)
                }
                ForEach(allRows) { row in
                    Button { Task { await open(row) } } label: { line(row) }
                        .buttonStyle(.plain)
                        .disabled(opening != nil)
                        .accessibilityIdentifier("douyin.stranger.row")
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .overlay { if opening != nil { ProgressView().tint(.white) } }
        .task(id: isActive) { if isActive { await refresh() } else { await DYChatOpener.cancelStrangerScan() } }
    }

    private func refresh() async {
        guard let web = cache.chatModel.web else { status = "私信页面还没加载好"; return }
        guard let rows = await DYChatOpener.strangerRows(web) else {
            DYLiveModel.log("DDSTRANGER rows=nil (box not ready)")
            status = "私信页面还没加载好，请稍后重试"; return
        }
        cache.strangerRows = rows
        cache.strangerUnread = rows.reduce(0) { $0 + (Int($1.badge) ?? ($1.badge.isEmpty ? 0 : 1)) }
        if rows.isEmpty { status = "暂无陌生人消息" }
        DYLiveModel.log("DDSTRANGER rows=\(rows.count) unread=\(cache.strangerUnread ?? 0)")
    }

    private func line(_ row: DYConversationRow) -> some View {
        DYConversationCell(row: row)
    }

    /// 共用同一个网页聊天；嵌入模式由父级保存陌生人列表作为返回目的地。
    private func open(_ row: DYConversationRow) async {
        guard isActive else { return }
        guard let web = cache.chatModel.web else { return }
        opening = row.id
        onOpeningChanged(true)
        defer { opening = nil; onOpeningChanged(false) }
        switch await DYChatOpener.open(row, web: web) {
        case .opened:
            cache.selectedChat = row
            if let onOpen { onOpen(row) } else { dismiss() }
        case .notReady: status = "私信页面还没加载好，请稍后重试"
        case .notFound:
            status = "这条会话位置变了，已刷新列表，请再点一次"
            await refresh()
        }
    }
}

/// 根页（fullScreenCover）没有导航栈可退，用左缘右滑关闭
struct DYEdgeSwipeBack: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onEnded { v in
                    if v.startLocation.x < 30, v.translation.width > 70,
                       abs(v.translation.height) < abs(v.translation.width) {
                        action()
                    }
                }
        )
    }
}

// MARK: - 当前作品转发给抖音朋友

/// 原生转发浮层；官网仅作后台数据与发送桥，登录时才显式进入官网。
private struct DYForwardActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
private extension EnvironmentValues {
    var dyForwardAction: (() -> Void)? {
        get { self[DYForwardActionKey.self] }
        set { self[DYForwardActionKey.self] = newValue }
    }
}

/// 状态挂在稳定的菜单外层，而不是会随原生菜单关闭而销毁的条目里。
struct DYForwardPresentation: ViewModifier {
    let item: DYAweme
    @State private var showing = false
    func body(content: Content) -> some View {
        content.environment(\.dyForwardAction, { showing = true })
            .fullScreenCover(isPresented: $showing) {
                DYForwardScreen(item: item).presentationBackground(.clear)
            }
    }
}

struct DYForwardMenu: View {
    let item: DYAweme
    let bridge: DouyinBridge?
    let foreground: Color
    @Environment(\.dyForwardAction) private var showFriends
    var body: some View {
        Button { showFriends?() } label: {
            Label("转发", systemImage: "arrowshape.turn.up.right")
        }
        .disabled(showFriends == nil)
        .accessibilityIdentifier("douyin.forward.menu")
    }
}

/// 原生转发浮层；官网仅作后台数据与发送桥，登录时才显式进入官网。
struct DYForwardScreen: View {
    let item: DYAweme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @StateObject private var model = DYForwardWebModel.cachedNative
    @State private var accountPrepared = false
    /// 多选：按点选顺序依次发送，官网组件一次只接受一个收件人。
    @State private var picked: [DYForwardContact] = []
    @State private var confirming = false
    @State private var showContacts = false
    @State private var groupsOnly = false
    @State private var query = ""
    @State private var showLogin = false
    @State private var showOtherApps = false

    private var actions: [DYForwardPanelAction] {
        var result: [DYForwardPanelAction] = []
        if !model.contacts.isEmpty { result.append(.init(id: "private", title: "私信", symbol: "paperplane.fill")) }
        if model.contacts.contains(where: { $0.kind == 2 }) { result.append(.init(id: "groups", title: "分享至群", symbol: "person.2.fill")) }
        result.append(.init(id: "copy", title: "复制链接", symbol: "link"))
        result.append(.init(id: "other", title: "其他分享", symbol: "square.and.arrow.up"))
        if model.loginRequired { result.append(.init(id: "login", title: "登录抖音", symbol: "person.crop.circle")) }
        else if !model.loading && model.contacts.isEmpty { result.append(.init(id: "retry", title: "重新加载", symbol: "arrow.clockwise")) }
        return result
    }
    /// 启动预加载已按账号恢复过朋友缓存：面板直接显示，不等 cookie 校验（校验在后台做，账号变了会自动清空重载）。
    private var prepared: Bool { accountPrepared || !model.accountScope.isEmpty }
    private var visibleContacts: [DYForwardContact] {
        model.contacts.filter { (!groupsOnly || $0.kind == 2) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.media.strongScrim.color(for: scheme).opacity(0.24).ignoresSafeArea()
                    .onTapGesture { if !model.sending { dismiss() } }
                DYNativeForwardPanel(contacts: prepared ? model.contacts : [], loading: !prepared || model.loading || model.sending,
                                     status: prepared ? model.message : "正在恢复朋友缓存…", actions: prepared ? actions : [],
                                     selected: Set(picked.map(\.id)), onSend: { if !model.sending && !picked.isEmpty { confirming = true } },
                                     onContact: { if !model.sending { toggle($0) } },
                                     onAction: perform, onClose: { if !model.sending { dismiss() } })
                    .frame(width: max(0, min(560, geo.size.width - 32)))
                // 挂载真实官方分享组件，保留React事件与鉴权，但不让网页进入用户界面或无障碍树。
                if prepared && !model.layoutFixture {
                    DYForwardWebContainer(model: model, url: item.webURL)
                        .id(model.accountScope)
                        .frame(width: 760, height: 640)
                        .frame(width: 1, height: 1).clipped().opacity(0.001)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .interactiveDismissDisabled(model.sending)
        .alert("确认转发", isPresented: $confirming) {
            Button("发送") { let targets = picked; picked = []; Task { await model.send(to: targets, itemURL: item.webURL) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(picked.count == 1 ? "将当前作品发送给“\(picked.first?.name ?? "")”？"
                 : "将当前作品依次发送给 \(picked.count) 人：\(picked.map(\.name).joined(separator: "、"))？")
        }
        .sheet(isPresented: $showContacts) {
            NavigationStack {
                List(visibleContacts) { contact in
                    Button { toggle(contact) } label: {
                        HStack {
                            CachedAsyncImage(url: contact.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                                placeholder: { Image(systemName: contact.kind == 2 ? "person.2.circle" : "person.circle") }
                                .frame(width: 44, height: 44).clipShape(Circle())
                            Text(contact.name).foregroundStyle(.themeTextPrimary)
                            Spacer(minLength: 0)
                            let on = picked.contains { $0.id == contact.id }
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(on ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityAddTraits(picked.contains { $0.id == contact.id } ? .isSelected : [])
                }
                .searchable(text: $query, prompt: "搜索已加载的朋友或群")
                .navigationTitle(groupsOnly ? "选择群聊" : "选择朋友")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { showContacts = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(picked.isEmpty ? "发送" : "发送(\(picked.count))") {
                            showContacts = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if !picked.isEmpty { confirming = true } }
                        }
                        .disabled(picked.isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showLogin, onDismiss: { Task { await restorePeople() } }) { DYForwardOfficialScreen(item: item) }
        .sheet(isPresented: $showOtherApps) { DYForwardSystemShare(url: item.webURL) }
        .task { await restorePeople() }
        // 分享浮层不暂停视频：缓存模型持有同一个只读官网上下文，下次打开无需重建SDK/重新拉整份朋友。
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false; model.release() }
    }
    private func restorePeople() async {
        if model.layoutFixture { accountPrepared = true; return }
        await DYMessageCache.shared.prepare()
        model.restorePeople(scope: DYMessageCache.shared.accountScope)
        accountPrepared = true
    }
    private func toggle(_ contact: DYForwardContact) {
        if let index = picked.firstIndex(where: { $0.id == contact.id }) { picked.remove(at: index) }
        else if picked.count < DYForwardWebModel.maxRecipients { picked.append(contact) }
        else { model.message = "一次最多选择 \(DYForwardWebModel.maxRecipients) 个" }
    }
    private func perform(_ action: String) {
        guard !model.sending else { return }
        switch action {
        case "private", "groups": groupsOnly = action == "groups"; query = ""; showContacts = true
        case "copy": UIPasteboard.general.url = item.webURL; model.message = "链接已复制"
        case "other": showOtherApps = true
        case "login": showLogin = true
        case "retry": model.web?.reload()
        default: break
        }
    }
}

private struct DYForwardSystemShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DYForwardOfficialScreen: View {
    let item: DYAweme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DYForwardWebModel()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    if model.loading { ProgressView() }
                    Text(model.message).font(.footnote).foregroundStyle(.themeTextSecondary)
                    Spacer(minLength: 0)
                }
                .padding()
                .accessibilityIdentifier("douyin.forward.status")
                DYForwardWebContainer(model: model, url: item.webURL)
                    .accessibilityIdentifier("douyin.forward.web")
            }
            .background(GlassBackground())
            .navigationTitle("转发给抖音朋友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.accessibilityIdentifier("douyin.forward.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(model.fullPage ? "返回分享" : "完整官网") { model.toggleFullPage() }
                }
            }
        }
        .onAppear { DDPlayback.shared.pauseAll(reason: .cover) }
        .onDisappear {
            model.stop()
            DDPlayback.shared.releaseCover()
        }
    }
}

/// 由官网已加载的分享组件处理选人、登录、签名与视频卡片协议；不拼造私信请求。
@MainActor final class DYForwardWebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let cachedNative = DYForwardWebModel(nativeOnly: true)
    @Published var panelVisible = false
    @Published private(set) var accountScope = ""
    @Published var message = "正在打开抖音官方分享面板…"
    @Published var loading = true
    @Published var fullPage = false
    @Published var contacts: [DYForwardContact] = []
    @Published var loginRequired = false
    @Published var sending = false
    let nativeOnly: Bool
    let layoutFixture: Bool
    var expectedID = ""
    weak var web: WKWebView?
    var retainedWeb: WKWebView?
    private var readyForSend = false
    private var bridgeFailed = false
    private var navigationGeneration = UUID()
    private var lastRemoteRefresh: Date?
    private var preloadTarget: URL?
    private var lastPreloadAttempt: Date?
    private var opening: Task<Void, Never>?
    init(nativeOnly: Bool = false) {
        self.nativeOnly = nativeOnly
        #if DEBUG && targetEnvironment(simulator)
        self.layoutFixture = nativeOnly && ProcessInfo.processInfo.environment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] == "1"
        #else
        self.layoutFixture = false
        #endif
        super.init()
        #if DEBUG && targetEnvironment(simulator)
        if layoutFixture {
            contacts = (1...9).map { .init(id: "layout-fixture-\($0)", name: "合成测试\($0)", avatar: nil, kind: $0 == 9 ? 2 : 1) }
            loading = false; message = "合成布局测试（不会发送消息）"
        }
        #endif
    }

    func restorePeople(scope: String, refreshRemote: Bool = true) {
        if accountScope != scope {
            stop(); web?.navigationDelegate = nil; retainedWeb = nil; web = nil
            navigationGeneration = UUID(); accountScope = scope
            readyForSend = false; bridgeFailed = false; sending = false; lastRemoteRefresh = nil; expectedID = ""
            preloadTarget = nil; lastPreloadAttempt = nil
        }
        let cache = DYPeopleCache.shared
        cache.activate(scope: scope)
        if contacts != cache.contacts { contacts = cache.contacts }
        loading = !cache.hasContactsSnapshot
        message = cache.hasContactsSnapshot ? "已恢复朋友缓存，后台同步变化" : "正在加载分享联系人…"
        DYLiveModel.log("DDPEOPLE restore contacts=\(contacts.count) warm=\(retainedWeb != nil)")
        if refreshRemote, let web {
            if web.isLoading { return }
            // 官网没有好友变更游标：温上下文仅本地差异扫描，最多每5分钟后台校准一次来源快照。
            if DYForwardRefreshPolicy.shouldRefresh(lastUpdate: lastRemoteRefresh) { web.reload() }
            else { openPanel() }
        }
    }

    private struct Snapshot: Decodable {
        let state: String; let items: [DYForwardContact]
        let isDelta: Bool?; let removed: [String]?; let revision: String?
    }
    static let maxRecipients = 9
    /// 官网ShareeList一次只确认一个收件人：多选按顺序逐个发送，未确认的不自动重发。
    func send(to requested: [DYForwardContact], itemURL: URL) async {
        guard !layoutFixture else { message = "合成布局测试：未发送任何消息"; return }
        let targets = requested.filter { row in contacts.contains { $0.id == row.id } }.prefix(Self.maxRecipients)
        guard !sending, !targets.isEmpty else { return }
        let account = accountScope, target = itemURL.lastPathComponent
        sending = true; message = "正在准备转发…"
        defer { if accountScope == account { sending = false } }
        var sent: [String] = [], unconfirmed: [String] = [], rejected: [String] = [], skipped: [String] = []
        var blocked: String?
        for (index, contact) in targets.enumerated() {
            guard !Task.isCancelled, accountScope == account else { return }
            if blocked != nil { skipped.append(contact.name); continue }
            if index > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            let progress = targets.count > 1 ? "（\(index + 1)/\(targets.count)）" : ""
            guard var state = await sendOne(contact, itemURL: itemURL, account: account, target: target, progress: progress) else { return }
            if state == "not-ready" {
                // 官网发完一条可能收起分享面板：此时尚未发送，重新打开后只重试这一次。
                readyForSend = false; openPanel()
                guard let retried = await sendOne(contact, itemURL: itemURL, account: account, target: target, progress: progress) else { return }
                state = retried
            }
            switch state {
            case "sent": sent.append(contact.name)
            case "rejected": rejected.append(contact.name)
            case "login", "bridge-not-ready", "not-ready", "wrong-work": blocked = state; skipped.append(contact.name)
            case "missing-recipient": skipped.append(contact.name)
            default: unconfirmed.append(contact.name)
            }
        }
        guard accountScope == account else { return }
        if targets.count == 1, let name = targets.first?.name {
            if !sent.isEmpty { message = "已转发给“\(name)”" }
            else if !rejected.isEmpty { message = "抖音未接受本次转发，请到消息中核对" }
            else if blocked == "login" { message = "请先登录抖音，尚未发送" }
            else if blocked == "bridge-not-ready" { message = "转发组件尚未就绪，尚未发送，请稍后重试" }
            else if !skipped.isEmpty { message = "当前作品或朋友列表已变化，请重新打开转发" }
            else { message = "发送未确认，请到抖音消息核对，勿重复发送" }
            return
        }
        var parts = ["已转发 \(sent.count)/\(targets.count) 人"]
        if !unconfirmed.isEmpty { parts.append("未确认：\(unconfirmed.joined(separator: "、"))（请到抖音消息核对，勿重复发送）") }
        if !rejected.isEmpty { parts.append("抖音未接受：\(rejected.joined(separator: "、"))") }
        if !skipped.isEmpty {
            let reason = blocked == "login" ? "需先登录抖音" : blocked == nil ? "朋友列表已变化" : "转发组件未就绪"
            parts.append("尚未发送：\(skipped.joined(separator: "、"))（\(reason)）")
        }
        message = parts.joined(separator: "；")
    }
    /// 返回nil表示账号或作品已切换，整批作废；其余为单个收件人的结果状态。
    private func sendOne(_ contact: DYForwardContact, itemURL: URL, account: String, target: String, progress: String) async -> String? {
        let deadline = Date().addingTimeInterval(40)
        while web == nil && Date() < deadline {
            guard !Task.isCancelled, accountScope == account else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let web, accountScope == account else { return nil }
        if expectedID != target || web.url?.path != itemURL.path {
            readyForSend = false; bridgeFailed = false; loginRequired = false; expectedID = target
            web.load(URLRequest(url: itemURL))
        }
        while !readyForSend && Date() < deadline && !loginRequired && !bridgeFailed {
            guard !Task.isCancelled, accountScope == account, expectedID == target else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard accountScope == account, expectedID == target else { return nil }
        guard readyForSend else { return loginRequired ? "login" : "bridge-not-ready" }
        message = "正在转发\(progress)…"
        do {
            let raw = try await web.callAsyncJavaScript(
                "return JSON.stringify(await window.__ddNativeForward.send(expected, recipient));",
                arguments: ["expected": expectedID, "recipient": contact.id], contentWorld: .page) as? String
            guard accountScope == account, expectedID == target else { return nil }
            let data = raw?.data(using: .utf8)
            let response = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            DYLiveModel.log("DDFORWARD send=\(response?["state"] ?? "unconfirmed") source=\(response?["source"] ?? "unknown") elapsed_ms=\(response?["elapsed_ms"] ?? "unknown")")
            return response?["state"] ?? "unconfirmed"
        } catch {
            guard accountScope == account, expectedID == target else { return nil }
            let failure = error as NSError
            DYLiveModel.log("DDFORWARD send=unconfirmed source=webkit code=\(failure.code)")
            return "unconfirmed"
        }
    }

    func stop() { opening?.cancel(); opening = nil; web?.stopLoading() }
    /// 分享面板关闭：彻底释放官网上下文，不在后台挂着整页抖音。朋友列表在磁盘缓存里，下次打开先秒显再刷新。
    func release() {
        guard !sending else { return }
        stop()
        web?.navigationDelegate = nil; web?.uiDelegate = nil
        web = nil; retainedWeb = nil
        readyForSend = false; expectedID = ""; preloadTarget = nil
        DYLiveModel.log("DDPEOPLE share page released")
    }
    /// 温启动：网页仍在上一条作品且分享组件已就绪，只做一次差异扫描，不重新加载页面。
    func warmPanel() {
        guard let web, web.url?.lastPathComponent == expectedID else { return }
        openPanel()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration = UUID(); readyForSend = false; bridgeFailed = false; opening?.cancel()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.lastPathComponent == expectedID else { return }
        lastRemoteRefresh = Date(); openPanel()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail() }
    }
    private func fail() {
        readyForSend = false; bridgeFailed = true; loading = false
        message = contacts.isEmpty ? "官网加载失败，请关闭后重试" : "已显示朋友缓存，后台同步暂时失败"
    }
    func toggleFullPage() {
        fullPage.toggle()
        if fullPage {
            opening?.cancel()
            web?.evaluateJavaScript("document.getElementById('dd-forward-focus')?.remove()")
            message = "抖音官网：请核对朋友后再发送"
            loading = false
        } else { openPanel() }
    }
    private func openPanel() {
        opening?.cancel()
        guard !fullPage else { return }
        loading = nativeOnly ? !DYPeopleCache.shared.hasContactsSnapshot : true
        loginRequired = false; bridgeFailed = false
        if !sending { message = nativeOnly && !contacts.isEmpty ? "已显示朋友缓存，后台同步变化" : nativeOnly ? "正在加载分享联系人…" : "正在打开抖音官方分享面板…" }
        let generation = navigationGeneration, account = accountScope, work = expectedID
        opening = Task { [weak self] in
            for _ in 0..<80 {
                guard !Task.isCancelled, let self, let web = self.web,
                      self.navigationGeneration == generation, self.accountScope == account, self.expectedID == work else { return }
                if let raw = try? await web.evaluateJavaScript(Self.openPanelJS) as? String,
                   let data = raw.data(using: .utf8),
                   let response = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let state = response["state"], state == "ready" || state == "login" {
                    guard !Task.isCancelled, self.navigationGeneration == generation, self.accountScope == account, self.expectedID == work else { return }
                    if self.nativeOnly {
                        if state == "login" {
                            self.readyForSend = false; self.loginRequired = true; self.loading = false
                            self.message = self.contacts.isEmpty ? "登录抖音后显示可转发的朋友" : "已显示朋友缓存，登录抖音后可转发"
                            return
                        }
                        if let json = try? await web.callAsyncJavaScript("return JSON.stringify(window.__ddNativeForward.read(expected, true));", arguments: ["expected": work], contentWorld: .page) as? String,
                           let bytes = json.data(using: .utf8), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: bytes),
                           snapshot.state == "ready" || snapshot.state == "empty" {
                            guard !Task.isCancelled, self.navigationGeneration == generation, self.accountScope == account, self.expectedID == work else { return }
                            #if DEBUG
                            if let description = try? await web.callAsyncJavaScript("return JSON.stringify(window.__ddNativeForward.describe(expected));", arguments: ["expected": work], contentWorld: .page) as? String {
                                print("DDFORWARD_PUBLIC_SCHEMA " + description)
                            }
                            #endif
                            let cache = DYPeopleCache.shared
                            guard cache.scope == account else { return }
                            if snapshot.isDelta == true, let removed = snapshot.removed, !removed.isEmpty {
                                let deleted = Set(removed)
                                cache.mergeContacts(cache.contacts.filter { !deleted.contains($0.id) } + snapshot.items, scope: account, complete: true)
                            } else {
                                cache.mergeContacts(snapshot.items, scope: account, complete: snapshot.isDelta != true)
                            }
                            if self.contacts != cache.contacts { self.contacts = cache.contacts }
                            self.loginRequired = false; self.loading = false; self.readyForSend = true
                            if !self.sending { self.message = self.contacts.isEmpty ? "官网暂无可读取的分享联系人" : "选择朋友转发当前作品" }
                            if let revision = snapshot.revision {
                                _ = try? await web.callAsyncJavaScript("return window.__ddNativeForward.ack(revision);", arguments: ["revision": revision], contentWorld: .page)
                            }
                            DYLiveModel.log("DDFORWARD native-contacts=\(self.contacts.count) changed=\(snapshot.items.count) removed=\(snapshot.removed?.count ?? 0)")
                            return
                        }
                    } else {
                        self.loading = false
                        self.message = state == "login" ? "请先在下方登录抖音，再选择朋友" : "使用抖音官方分享面板；请核对朋友后再发送"
                        DYLiveModel.log("DDFORWARD panel=\(state)")
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled, let self, self.navigationGeneration == generation, self.accountScope == account, self.expectedID == work else { return }
            if let diag = try? await self.web?.evaluateJavaScript("JSON.stringify({path:location.pathname,entries:[...document.querySelectorAll('[data-e2e]')].map(e=>e.getAttribute('data-e2e')).filter(s=>/share/.test(s)),props:(()=>{const e=document.querySelector('[data-e2e=video-player-share]');const k=e&&Object.keys(e).find(k=>k.startsWith('__reactProps'));return k?Object.keys(e[k]):[]})(),panel:!!document.querySelector('[data-e2e=video-share-container]')})") as? String {
                DYLiveModel.log("DDFORWARD diag=\(diag)")
            }
            guard !Task.isCancelled, self.navigationGeneration == generation, self.accountScope == account else { return }
            self.loading = false; self.readyForSend = false; self.bridgeFailed = true
            self.message = self.nativeOnly ? (self.contacts.isEmpty ? "朋友同步暂未就绪，请稍后重试" : "已显示朋友缓存，后台同步暂未完成") : "暂未打开官网分享面板，可点“完整官网”手动打开"
            DYLiveModel.log("DDFORWARD panel=unavailable")
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") { webView.load(URLRequest(url: url)) }
        return nil
    }

    /// 原生层只读官网联系人；发送复用官网ShareeList.confirmSharee及其业务回执。
    static let nativeBridgeJS = #"""
    (() => {
      const identifier = value => {
        if (typeof value === 'number' && !Number.isSafeInteger(value)) return null;
        if (typeof value === 'string' || typeof value === 'number' || typeof value === 'bigint') return String(value);
        return null;
      };
      const kind = user => user.type === 2 || user.type === 'group' ? 2 : 1;
      const key = user => { const id = identifier(user.uid); return id ? kind(user) + '|' + id : null; };
      function inspect(expected) {
        if (location.hostname !== 'www.douyin.com' || location.pathname.replace(/\/$/, '') !== '/video/' + expected) return {state: 'wrong-work'};
        const panel = document.querySelector('[data-e2e="video-share-container"]');
        if (!panel) return {state: 'not-ready'};
        if (/登录后分享|扫码登录|登录其他账号/.test(panel.textContent || '')) return {state: 'login'};
        const fiberKey = Object.keys(panel).find(k => k.startsWith('__reactFiber') || k.startsWith('__reactInternalInstance'));
        let root = fiberKey && panel[fiberKey];
        if (root) {
          let top = root, depth = 0;
          while (top.return && depth++ < 100) top = top.return;
          if (top.stateNode?.current && top.stateNode.current !== top && root.alternate) root = root.alternate;
        }
        const stack = root ? [root] : [], seen = new Set();
        let store = null, list = null, confirm = null;
        while (stack.length && seen.size < 5000) {
          const node = stack.pop(); if (!node || seen.has(node)) continue; seen.add(node);
          const p = node.memoizedProps || {};
          if (p.shareStore && p.shareStore.awemeInfo) store = p.shareStore;
          if (Array.isArray(p.value?.mixedList)) list = p.value.mixedList;
          // ShareeList给行组件的同名包装会吞掉第四参；只选拥有业务回执的列表层。
          if (typeof p.confirmSharee === 'function' && typeof p.closeBoard === 'function' &&
              typeof p.handleShareSuccess === 'function' && typeof p.handleShareError === 'function') confirm = p.confirmSharee;
          if (node.child) stack.push(node.child);
          if (node !== root && node.sibling) stack.push(node.sibling);
        }
        if (!store || !list || !confirm) return {state: 'not-ready'};
        if (identifier(store.awemeInfo.awemeId) !== expected) return {state: 'wrong-work'};
        return {state: list.length ? 'ready' : 'empty', store, list, confirm};
      }
      let peopleBaseline = new Map(), peopleHasBaseline = false, peopleSequence = 0, peoplePending = null;
      const peopleNonce = Date.now() + '-' + Math.random();
      window.__ddNativeForward = {
        describe(expected) {
          const snapshot = inspect(expected);
          if (!snapshot.confirm) return {state: snapshot.state};
          const store = snapshot.store;
          const methods = {};
          let object = store;
          for (let i=0; i<3 && object; i++,object=Object.getPrototypeOf(object)) {
            for (const key of Object.getOwnPropertyNames(object)) {
              if (/share|message|text|confirm/i.test(key)) {
                const value = store[key];
                if (typeof value === 'function') methods[key] = String(value).slice(0,6000);
              }
            }
          }
          const chunks = Object.keys(window).filter(k => k.startsWith('webpackChunk'));
          let runtime;
          for (const name of chunks) {
            try { window[name].push([[987654321], {}, r => { runtime = r; }]); } catch (_) {}
            if (runtime) break;
          }
          const found = [];
          for (const [id, module] of Object.entries(runtime?.c || {})) {
            const exports = module?.exports;
            const candidates = [exports];
            try { candidates.push(...Object.values(exports || {})); } catch (_) {}
            for (const value of candidates) {
              if (value && typeof value.sendMessage === 'function' && typeof value.getConversationByIdWithOnlineAsync === 'function') {
                found.push({id, source:String(value.sendMessage), keys:Object.keys(value)});
                window.__ddShareSDK = value;
              }
            }
            if (exports && typeof exports === 'object') {
              for (const [key,value] of Object.entries(exports)) {
                if (value && typeof value === 'object' && 'TEXT' in value && /SHARE/.test(Object.keys(value).join(',')))
                  found.push({id,key,types:value});
              }
            }
          }
          for (const [id, factory] of Object.entries(runtime?.m || {})) {
            const source = String(factory);
            if (!(source.includes('getConversationByIdWithOnlineAsync') && source.includes('sendMessage')) &&
                !(source.includes('SHARE_AWEME') && source.includes('TEXT'))) continue;
            try {
              const exports = runtime(id);
              for (const [key,value] of Object.entries(exports || {})) {
                if (value && typeof value.sendMessage === 'function' && typeof value.getConversationByIdWithOnlineAsync === 'function') {
                  found.push({id,key,source:String(value.sendMessage).slice(0,16000),keys:Object.keys(value)});
                  window.__ddShareSDK = value;
                }
                if (value && typeof value === 'object' && 'TEXT' in value && 'SHARE_AWEME' in value) {
                  found.push({id,key,types:value}); window.__ddShareTypes = value;
                }
              }
            } catch (_) {}
          }
          return {found};
        },
        read(expected, incremental = false) {
          const snapshot = inspect(expected), items = [], seen = new Set();
          for (const user of snapshot.list || []) {
            const id = key(user), name = user.remark_name || user.nickname;
            if (!id || seen.has(id) || typeof name !== 'string' || !name.trim()) continue;
            seen.add(id);
            const avatar = user.avatar_thumb?.url_list?.[0];
            items.push({id, name, avatar: typeof avatar === 'string' ? avatar : null, kind: kind(user)});
          }
          if (!incremental || !['ready','empty'].includes(snapshot.state)) return {state: snapshot.state, items};
          const current = new Map(items.map(row => [row.id, JSON.stringify(row)]));
          const changed = peopleHasBaseline ? items.filter(row => peopleBaseline.get(row.id) !== current.get(row.id)) : items;
          const removed = peopleHasBaseline ? [...peopleBaseline.keys()].filter(id => !current.has(id)) : [];
          const revision = peopleNonce + ':' + (++peopleSequence);
          peoplePending = {revision, rows: current};
          return {state: snapshot.state, items: changed, removed, isDelta: peopleHasBaseline, revision};
        },
        ack(revision) {
          if (!peoplePending || peoplePending.revision !== revision) return false;
          peopleBaseline = peoplePending.rows; peopleHasBaseline = true; peoplePending = null;
          return true;
        },
        async send(expected, recipient) {
          const snapshot = inspect(expected);
          if (snapshot.state !== 'ready') return {state: snapshot.state};
          const user = snapshot.list.find(user => key(user) === recipient);
          if (!user) return {state: 'missing-recipient'};
          return await new Promise(resolve => {
            let complete = false;
            const started = Date.now();
            const finish = (state, source) => {
              if (complete) return;
              complete = true; clearTimeout(timer);
              resolve({state, source, elapsed_ms: String(Date.now() - started)});
            };
            const timer = setTimeout(() => finish('unconfirmed', 'timeout'), 20000);
            try {
              const pending = snapshot.confirm(user, kind(user) === 2 ? 'group' : 'user', snapshot.list,
                response => finish(response?.success === true ? 'sent' : response?.success === false ? 'rejected' : 'unconfirmed', 'callback'));
              // 精确列表层的第四参由官方afterSend/onSendFinished调用，兼容新旧SDK。
              // Promise完成只代表函数返回，不是发送成功。
              Promise.resolve(pending).catch(() => finish('unconfirmed', 'exception'));
            } catch (e) { finish('unconfirmed', 'exception'); }
          });
        }
      };
    })()
    """#

    /// 仅触发官网分享入口的 hover，不点击朋友或发送按钮，也不把打开面板当成发送成功。
    static let openPanelJS = #"""
    (() => {
      const result = state => JSON.stringify({state});
      if (location.hostname !== 'www.douyin.com' || !/^\/video\/\d+\/?$/.test(location.pathname)) return result('wrong-page');
      const entry = document.querySelector('[data-e2e="video-share-icon-container"]') || document.querySelector('[data-e2e="video-player-share"]');
      if (!entry) return result('loading');
      let panel = document.querySelector('[data-e2e="video-share-container"]');
      if (!panel || !panel.textContent.trim()) {
        for (let node = entry, depth = 0; node && depth < 5; node = node.parentElement, depth++) {
          const key = Object.keys(node).find(k => k.startsWith('__reactProps'));
          const hover = key && node[key] && node[key].onMouseEnter;
          if (typeof hover !== 'function') continue;
          hover({currentTarget: node, target: entry, preventDefault(){}, stopPropagation(){}});
          return result('loading');
        }
        return result('loading');
      }
      if (!document.getElementById('dd-forward-focus')) {
        const style = document.createElement('style'); style.id = 'dd-forward-focus';
        style.textContent = `
          body { margin: 0 !important; overflow: hidden !important; }
          body * { visibility: hidden !important; }
          [data-dd-forward-ancestor] { transform: none !important; filter: none !important; overflow: visible !important; contain: none !important; }
          [data-e2e="video-share-container"], [data-e2e="video-share-container"] * { visibility: visible !important; }
          [data-e2e="video-share-container"] { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; z-index: 2147483000 !important; overflow: auto !important; }
          [data-e2e="video-share-container"] > div { display: flex !important; width: 100% !important; max-width: 100% !important; min-width: 0 !important; min-height: 100% !important; box-sizing: border-box !important; }
        `;
        document.head.appendChild(style);
        for (let n = panel.parentElement; n && n !== document.body; n = n.parentElement) {
          n.setAttribute('data-dd-forward-ancestor', '');
        }
      }
      const text = panel.textContent || '';
      return result(/登录后分享|扫码登录|登录其他账号/.test(text) ? 'login' : 'ready');
    })()
    """#
}

/// Contact data is account scoped and independent of whichever video is playing.
enum DYForwardRefreshPolicy {
    static func shouldRefresh(lastUpdate: Date?, now: Date = Date()) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) >= 300
    }
}

private struct DYForwardWebContainer: UIViewRepresentable {
    @ObservedObject var model: DYForwardWebModel
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        // 复用上次打开时的只读官网上下文：朋友数据与安全SDK都不必重新加载。
        if let existing = model.retainedWeb {
            model.web = existing
            existing.navigationDelegate = model; existing.uiDelegate = model
            if existing.url?.lastPathComponent != url.lastPathComponent {
                model.expectedID = url.lastPathComponent
                existing.load(URLRequest(url: url))
            } else {
                model.warmPanel()
            }
            return existing
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(WKUserScript(source: DYForwardWebModel.nativeBridgeJS,
                                                               injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: #"""
        (() => {
          const media = HTMLMediaElement.prototype;
          media.play = function(){ this.muted = true; try { this.pause() } catch(e){} return Promise.resolve() };
          const fix = () => {
            let meta = document.querySelector('meta[name=viewport]');
            if (!meta && document.head) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta) }
            if (meta) meta.content = 'width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover';
          };
          document.addEventListener('DOMContentLoaded', fix); fix();
        })()
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = DouyinWeb.userAgent
        web.navigationDelegate = model; web.uiDelegate = model; model.web = web
        model.expectedID = url.lastPathComponent
        #if DEBUG
        web.isInspectable = true
        #endif
        web.load(URLRequest(url: url))
        model.retainedWeb = web
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url?.lastPathComponent != url.lastPathComponent, model.expectedID != url.lastPathComponent {
            model.expectedID = url.lastPathComponent
            uiView.load(URLRequest(url: url))
        }
    }
}

private struct DYMessagePlay: Identifiable {
    let id = UUID()
    let item: DYAweme
    var focus: DYCommentFocus? = nil
}

extension DYMessagesScreen {
    /// 顶栏红点用的未读合计。700 有数用 700，否则加总。
    static func badge(_ groups: [DYNoticeCount]) -> Int {
        if let all = groups.first(where: { $0.group == DYNoticeGroup.all.rawValue }) { return all.count }
        return groups.reduce(0) { $0 + $1.count }
    }
}
