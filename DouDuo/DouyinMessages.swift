// 消息中心（对齐抖音消息页）：顶部朋友头像 → 互动/粉丝/系统/私信入口 → 点进分类二级页。
// 全部内容在同一个 ScrollView 里滚动，分类入口不固定在顶部。
// Duo：返回键走系统 toolbar（自动进右侧竖向侧栏）；根页左缘右滑关闭，二级页系统原生左缘返回上一层。
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
    /// 陌生人二级列表（网页展开陌生人面板后读出的每个人）与总未读
    @Published var strangerRows: [DYConversationRow] = []
    @Published var strangerUnread: Int?
    /// 主列表里「我没关注」的单聊：抖音网页把它们混在普通会话里，按官方 App 归到陌生人
    @Published var unfollowedRows: [DYConversationRow] = []
    /// sec_uid → follow_status（0 未关注 / 1 已关注 / 2 互关），落盘让下次进来分类不闪
    @Published var follow: [String: Int] = [:]
    private var followChecked = Set<String>()

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
        var pages: [String: DYCachedNoticePage] = [:]
        var counts: [Int: Int] = [:]
        var friends: [DYFriend] = []
        var conversations: [DYConversationRow] = []
        var follow: [String: Int]?
        var friendCursor: String?
        var friendHasMore: Bool?
    }
    var snapshot = Snapshot()
    let chatModel = DouyinWebModel()
    private var retainedChatWeb: WKWebView?
    @Published private(set) var scope = ""
    var accountScope: String { scope }
    private var refreshing = Set<String>()
    private var friendsRefreshing = Set<String>()
    private var lastSavedData: Data?
    private var file: URL? {
        guard !scope.isEmpty else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("message-cache-v2", isDirectory: true).appendingPathComponent(scope + ".json")
    }
    func prepare() async {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let identity = cookies.filter { $0.domain.hasSuffix("douyin.com") && ["sessionid", "sessionid_ss", "uid_tt"].contains($0.name) }
            .sorted { $0.name < $1.name }.map { $0.name + "=" + $0.value }.joined(separator: "|")
        let next = SHA256.hash(data: Data((identity.isEmpty ? "guest" : identity).utf8)).map { String(format: "%02x", $0) }.joined()
        guard next != scope else { DYPeopleCache.shared.activate(scope: scope); return }
        let changingAccount = !scope.isEmpty
        scope = next
        snapshot = Snapshot(); lastSavedData = nil
        if let file, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = cached; lastSavedData = data
        }
        selectedChat = nil; strangerRows = []; strangerUnread = nil; unfollowedRows = []
        follow = snapshot.follow ?? [:]; followChecked = []
        DYPeopleCache.shared.activate(scope: scope)
        if !DYPeopleCache.shared.hasFriendsSnapshot && !snapshot.friends.isEmpty {
            DYPeopleCache.shared.mergeFriends(snapshot.friends, scope: scope)
        }
        if changingAccount {
            // 丢弃旧账号的DOM，避免新scope误读取旧页面；视图用scope作为实例ID重建。
            chatModel.web?.stopLoading(); chatModel.web = nil; retainedChatWeb = nil
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
    let avatar: String?
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
    let bridge: DouyinBridge
    let onClose: () -> Void
    let onWeb: (URL) -> Void

    @State private var path: [DYMsgRoute] = []
    @StateObject private var chatModel = DYMessageCache.shared.chatModel
    @State private var viewedGroups: [DYMsgRoute: Set<Int>] = [:]
    @State private var conversations: [DYConversationRow] = []
    @ObservedObject private var cache = DYMessageCache.shared
    private var selectedChat: DYConversationRow? { cache.selectedChat }
    @State private var chatStatus = "正在加载私信…"
    /// 顶部头像栏 = 朋友（互相关注），来自 familiar/atlist，不是粉丝
    @State private var friends: [DYFriend] = []
    @State private var counts: [Int: Int] = [:]
    @State private var recent: [DYNotice] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            messageContent
                .navigationTitle(selectedChat?.name ?? "消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Duo：返回/关闭走系统 cancellationAction，系统把它放进右侧竖向侧栏
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回", systemImage: "chevron.backward", action: backFromMessage)
                            .accessibilityIdentifier("douyin.messages.back")
                    }
                }
                .navigationDestination(for: DYMsgRoute.self) { r in
                    if r == .stranger {
                        DYStrangerListScreen()
                    } else {
                        DYNoticeListScreen(bridge: bridge, route: r, onWeb: onWeb, onViewedGroup: { group in viewedGroups[r, default: []].insert(group) })
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task { await loadRoot() }
        .task {
            // 预读陌生人面板：入口角标显示真实未读、二级页秒开
            try? await Task.sleep(for: .seconds(3))
            // 网页首屏可能还没挂上，最多等 ~20s
            for _ in 0..<10 {
                if let web = chatModel.web, let rows = await DYChatOpener.strangerRows(web) {
                    cache.strangerRows = rows
                    cache.strangerUnread = rows.reduce(0) { $0 + (Int($1.badge) ?? ($1.badge.isEmpty ? 0 : 1)) }
                    DYLiveModel.log("DDSTRANGER preload rows=\(rows.count) unread=\(cache.strangerUnread ?? 0)")
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task {
            while !Task.isCancelled {
                if selectedChat == nil { await readConversations() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: path) { old, current in
            // 只有真正退出分类才标已读；打开视频/作者弹层不算退出分类。
            guard old.count > current.count, let route = old.last else { return }
            let seen = viewedGroups.removeValue(forKey: route) ?? []
            Task {
                await DYMessageCache.shared.markReadAfterExit(seen, bridge: bridge)
                counts = DYMessageCache.shared.snapshot.counts
                recent = DYMessageCache.shared.page(700)?.items ?? recent
            }
        }
        .onDisappear { DYMessageCache.shared.retainChat() }
    }

    /// 同一个网页实例持续连接；首页只读取会话行，点会话后才显示聊天面板。
    private var messageContent: some View {
        GeometryReader { geo in
          ZStack(alignment: .topLeading) {
            root
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(selectedChat == nil ? 1 : 0)
                .allowsHitTesting(selectedChat == nil)
                .accessibilityHidden(selectedChat != nil)
            DouyinWebContainer(model: chatModel, zoom: 1, start: URL(string: "https://www.douyin.com/chat")!, reuseExisting: true)
                .frame(width: selectedChat == nil ? 760 : geo.size.width,
                       height: selectedChat == nil ? 640 : geo.size.height)
                .opacity(selectedChat == nil ? 0.001 : 1)
                .allowsHitTesting(selectedChat != nil)
                .accessibilityHidden(selectedChat == nil)
                .accessibilityIdentifier("douyin.messages.chat.detail")
          }
          .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
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
    private var friendConversations: [DYConversationRow] { conversations.filter { !$0.stranger && !cache.isUnfollowed($0) } }
    private var unfollowedConversations: [DYConversationRow] { conversations.filter { cache.isUnfollowed($0) } }
    private var strangerConversations: [DYConversationRow] { conversations.filter(\.stranger) }

    private var conversationRows: some View {
        VStack(spacing: 0) {
            if conversations.isEmpty {
                Text(chatStatus).font(.footnote).foregroundStyle(.secondary).padding(20)
            }
            ForEach(friendConversations) { row in
                Button { Task { await openConversation(row) } } label: {
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: row.avatar.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                        }
                        .frame(width: 50, height: 50).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.name).font(.body.weight(.semibold)).lineLimit(1)
                            Text(row.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 7) {
                            Text(row.time).font(.caption2).foregroundStyle(.secondary)
                            if !row.badge.isEmpty {
                                Text(row.badge).font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.red))
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.conversation.row")
                .accessibilityValue(row.stranger ? "stranger" : "friend")
            }
            if !friendConversations.isEmpty {
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

    private func readConversations() async {
        guard let web = chatModel.web else { return }
        let account = DYMessageCache.shared.accountScope
        guard !account.isEmpty else { return }
        do {
            _ = try? await web.callAsyncJavaScript("window.__ddAccountScope = scope;", arguments: ["scope": account], contentWorld: .page)
            guard let result = try await web.evaluateJavaScript(Self.conversationsJS) as? String,
                  let data = result.data(using: .utf8) else { return }
            let delta = try JSONDecoder().decode(ConversationDelta.self, from: data)
            guard DYMessageCache.shared.accountScope == account else { return }
            if delta.items.isEmpty {
                if conversations.isEmpty && delta.visible == 0 {
                    let text = (try? await web.evaluateJavaScript("document.body.innerText")) as? String ?? ""
                    chatStatus = text.contains("验证码登录") ? "私信需要登录，请使用网页版 / 登录" : "正在加载会话；如无记录可稍后重试"
                } else {
                    chatStatus = ""
                }
                _ = try? await web.callAsyncJavaScript(Self.conversationsAckJS, arguments: ["revision": delta.revision], contentWorld: .page)
                return
            }
            let updated = Dictionary(delta.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let existing = Set(conversations.map(\.id))
            let merged = delta.items.filter { !existing.contains($0.id) } + conversations.map { updated[$0.id] ?? $0 }
            if merged != conversations {
                conversations = merged
                DYMessageCache.shared.snapshot.conversations = merged
                DYMessageCache.shared.save()
            }
            // 合并成功才推进网页差异基线；失败或换账号时下次仍会重发这些行。
            _ = try? await web.callAsyncJavaScript(Self.conversationsAckJS, arguments: ["revision": delta.revision], contentWorld: .page)
            DYMessageCache.shared.retainChat()
            chatStatus = ""
            await cache.resolveFollow(conversations.compactMap { $0.kind == 1 ? $0.sec : nil })
            let unfollowed = unfollowedConversations
            if unfollowed != cache.unfollowedRows { cache.unfollowedRows = unfollowed }
        } catch {
            chatStatus = "私信加载失败，请稍后重试"
        }
    }

    private func openConversation(_ row: DYConversationRow) async {
        guard let web = chatModel.web else { return }
        var result = await DYChatOpener.open(row, web: web)
        if case .notReady = result {
            try? await Task.sleep(for: .milliseconds(1500))
            result = await DYChatOpener.open(row, web: web)
        }
        switch result {
        case .opened:
            cache.selectedChat = row
            DYLiveModel.log("DDCHAT open stranger=\(row.stranger) name=\(row.name)")
        case .notReady:
            chatStatus = "私信页面还没加载好，请稍后重试"
            DYLiveModel.log("DDCHAT open miss dom-not-ready name=\(row.name)")
        case .notFound:
            chatStatus = "会话位置已变化，正在刷新，请再点一次"
            await readConversations()
        }
    }

    private func backFromMessage() {
        guard cache.selectedChat != nil else { onClose(); return }
        let wasStranger = cache.selectedChat?.stranger == true
        cache.selectedChat = nil
        Task {
            if let web = chatModel.web {
                await DYChatOpener.restoreList(web)
                if wasStranger { await DYChatOpener.collapseStranger(web) }
            }
            await readConversations()
        }
    }

    /// 陌生人聚合项展开后，进第一屏里第一个真实会话（没有则停在陌生人列表，也能返回）
    /// 主列表：普通会话 + 陌生人聚合项。陌生人二级面板（StrangerConversationList）里的行不算主列表
    private static let conversationsJS = #"""
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
        const id = stranger ? 'stranger-aggregate' : typeof c?.id === 'string' && c.id ? 'conversation:' + c.id : name + '|' + (avatar || '') + '|' + stranger;
        return { id, name, avatar, preview, time, badge: badgeOf(e), index: String(idx), stranger,
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
    private static let conversationsAckJS = #"""
    const state = window.__ddConversationDelta;
    if (!state?.pending || state.pending.revision !== revision) return false;
    state.baseline = state.pending.rows; state.pending = null;
    return true;
    """#

    private struct ConversationDelta: Decodable {
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    friendStrip
                    entry(icon: "heart.fill", tint: Color(red: 0.95, green: 0.30, blue: 0.55),
                          title: "互动消息", subtitle: interactSummary,
                          badge: (counts[DYNoticeGroup.comment.rawValue] ?? 0) + (counts[DYNoticeGroup.digg.rawValue] ?? 0),
                          id: "douyin.messages.interactive") { path.append(.interactive) }
                    entry(icon: "person.fill", tint: Color(red: 0.25, green: 0.55, blue: 0.95),
                          title: "粉丝消息", subtitle: fansSummary,
                          badge: counts[DYNoticeGroup.fans.rawValue] ?? 0,
                          id: "douyin.messages.fans") { path.append(.fans) }
                    entry(icon: "bell.fill", tint: Color(red: 0.55, green: 0.55, blue: 0.60),
                          title: "系统通知", subtitle: (counts[DYNoticeGroup.system.rawValue] ?? 0) > 0 ? "有新通知" : "没有新通知",
                          badge: counts[DYNoticeGroup.system.rawValue] ?? 0,
                          id: "douyin.messages.system") { path.append(.system) }
                    entry(icon: "person.crop.circle.badge.questionmark", tint: Color(red: 0.98, green: 0.62, blue: 0.20),
                          title: "陌生人消息", subtitle: strangerSummary,
                          badge: strangerBadge,
                          id: "douyin.messages.stranger") { path.append(.stranger) }
                    conversationRows
                    if let error, recent.isEmpty {
                        VStack(spacing: 10) {
                            Text(error).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                            Button("重试") { Task { await loadRoot() } }.buttonStyle(.bordered)
                        }
                        .padding(24)
                    }
                }
            }
            .refreshable { await loadRoot() }
        }
        .background(Color.black.ignoresSafeArea())
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

    private var interactSummary: String {
        guard let h = recent.first(where: DYNoticeKind.isInteractive) else { return "没有新互动" }
        let who = h.name.isEmpty ? "抖音用户" : h.name
        return "\(who) \(h.action)"
    }

    private var fansSummary: String {
        guard let h = recent.first(where: { $0.type == DYNoticeKind.follow }) else {
            return (counts[DYNoticeGroup.fans.rawValue] ?? 0) > 0 ? "有新的粉丝" : "没有新粉丝"
        }
        return "\(h.name) 关注了你"
    }

    private func entry(icon: String, tint: Color, title: String, subtitle: String, badge: Int,
                       id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint).frame(width: 50, height: 50)
                    Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityValue(String(badge))
        .accessibilityLabel(title)
    }

    private func loadRoot() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let cache = DYMessageCache.shared
        await cache.prepare()
        // 先还原本地数据，不清空列表、不挡着等网络；随后只合并增量。
        counts = cache.snapshot.counts
        friends = DYPeopleCache.shared.hasFriendsSnapshot ? DYPeopleCache.shared.friends : cache.snapshot.friends
        if conversations != cache.snapshot.conversations { conversations = cache.snapshot.conversations }
        recent = cache.page(700)?.items ?? []
        DYLiveModel.log("DDMSGCACHE restore root=\(recent.count) chats=\(conversations.count) friends=\(friends.count)")
        // Independent reads start together after cached content has been restored.
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

    /// 点朋友头像：打开他的主页（网页版）
    private func openFriend(_ f: DYFriend) {
        guard !f.secUid.isEmpty, let u = URL(string: "https://www.douyin.com/user/\(f.secUid)") else { return }
        onWeb(u)
    }
}

// MARK: - 二级页（互动 / 粉丝 / 系统）

struct DYNoticeListScreen: View {
    let bridge: DouyinBridge
    let route: DYMsgRoute
    let onWeb: (URL) -> Void
    let onViewedGroup: (Int) -> Void
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

    init(bridge: DouyinBridge, route: DYMsgRoute, onWeb: @escaping (URL) -> Void, onViewedGroup: @escaping (Int) -> Void) {
        self.bridge = bridge
        self.route = route
        self.onWeb = onWeb
        self.onViewedGroup = onViewedGroup
        let group = route.filters.first ?? .all
        _group = State(initialValue: group)
        let cached = DYMessageCache.shared.page(group.rawValue)
        _items = State(initialValue: cached?.items ?? [])
        _maxTime = State(initialValue: cached?.maxTime ?? 0)
        _hasMore = State(initialValue: cached?.hasMore ?? true)
    }

    var body: some View {
        list.frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if opening { ProgressView().tint(.white) } }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(route.filterTitle(group))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            // 互动页点标题切 全部互动 / 评论 / 赞（对齐抖音「全部消息 ▾」）
            if route.filters.count > 1 {
                ForEach(route.filters) { g in
                    Button { group = g } label: {
                        if g == group { Label(route.filterTitle(g), systemImage: "checkmark") }
                        else { Text(route.filterTitle(g)) }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .task(id: group) {
            // 进哪个分类就记下它对应的服务端分组，退出时一起标已读（评论+赞同属互动）
            route.readGroups.forEach { onViewedGroup($0) }
            await reload(reset: true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_READ_AUDIT"] == "1", let values = try? await bridge.noticeCounts() {
                DYLiveModel.log("DDREADAUDIT inside-category " + values.map { "\($0.group)=\($0.count)" }.joined(separator: ","))
            }
            #endif
        }
        .task { await emojiStore.load(bridge: bridge) }
        .sheet(item: $author) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: onWeb)
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
        .fullScreenCover(item: $player) { p in
            DYListPlayer(bridge: bridge, title: p.item.desc.isEmpty ? "视频" : p.item.desc, items: [p.item], start: 0, onAuthor: { author = $0.author })
        }
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
                        Button { Task { await open(n) } } label: { row(n) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(n.awemeID == nil ? "douyin.notice.author" : "douyin.notice.video")
                            .accessibilityValue(n.hasRead ? "已读" : "未读")
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
                emojiStore.rich(n.detail.isEmpty ? n.action : "\(n.action) · \(n.detail)")
                    .font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
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

    private func reload(reset: Bool) async {
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
            guard gen == loadGen else { return }
            items = page.items
            maxTime = page.maxTime
            hasMore = page.hasMore
            error = nil
            DYLiveModel.log("DDNOTICE group=\(requestedGroup) n=\(items.count) read=deferred-until-exit")
        } catch {
            guard gen == loadGen else { return }
            if items.isEmpty { self.error = error.localizedDescription }
            DYLiveModel.log("DDNOTICE error \(error.localizedDescription)")
        }
    }

    private func open(_ n: DYNotice) async {
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
            player = DYMessagePlay(item: item)
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

    /// 网页私信页只有一个：预读陌生人（展开→采集→收起）和打开会话不能交错，
    /// 否则预读收起面板时会把刚选中的会话清掉（表现为聊天页一片空白）。
    private static var busy: Task<Void, Never>?
    private static func exclusive<T>(_ work: @escaping @MainActor () async -> T) async -> T {
        while let running = busy { await running.value; if busy == running { busy = nil } }
        var result: T?
        let t = Task { @MainActor in result = await work() }
        busy = t
        await t.value
        if busy == t { busy = nil }
        return result!
    }
    /// 有会话正在打开/显示时，预读直接跳过
    static var chatVisible = false

    static func waitFor(_ web: WKWebView, _ selector: String, timeoutMS: Int = 12000) async -> Bool {
        let probe = "document.querySelectorAll(" + jsString(selector) + ").length"
        var waited = 0
        while waited < timeoutMS {
            // 页面加载中查到的 0 会被误判成「没有会话」
            // evaluateJavaScript 的数字回来是 NSNumber（可能桥成 Double），统一按 NSNumber 取
            if !web.isLoading, let n = (try? await web.evaluateJavaScript(probe)) as? NSNumber, n.intValue > 0 { return true }
            try? await Task.sleep(for: .milliseconds(300))
            waited += 300
        }
        return false
    }

    /// 展开陌生人面板、采集全部陌生人会话后收起。nil = 网页还没就绪 / 找不到陌生人入口
    static func strangerRows(_ web: WKWebView) async -> [DYConversationRow]? {
        await exclusive { await strangerRowsUnlocked(web) }
    }

    private static func strangerRowsUnlocked(_ web: WKWebView) async -> [DYConversationRow]? {
        if chatVisible { return nil }
        guard await waitFor(web, "[data-e2e=\"conversation-item\"], [class*=\"conversationStrangerBoxwrapper\"]") else { return nil }
        let shown = ((try? await web.callAsyncJavaScript(openStrangerPanelJS, arguments: [:], contentWorld: .page)) as? NSNumber)?.intValue ?? 0
        guard shown > 0 else { DYLiveModel.log("DDSTRANGER panel not opened"); return [] }
        let json = try? await web.callAsyncJavaScript(collectStrangerJS, arguments: [:], contentWorld: .page) as? String
        DYLiveModel.log("DDSTRANGER panel shown=\(shown) collectedBytes=\(json?.count ?? -1)")
        await collapseStranger(web)
        guard let json, let data = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([DYConversationRow].self, from: data) else { return [] }
        return rows
    }

    /// 打开一个会话：普通会话在主列表里找；陌生人在展开后的陌生人面板里找。按名字+头像精确匹配，不按位置猜。
    static func open(_ row: DYConversationRow, web: WKWebView) async -> Result {
        await exclusive {
            let r = await openUnlocked(row, web: web)
            if case .opened = r { chatVisible = true }
            return r
        }
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
            return rows.find(e => titleOf(e) === name && (!avatar || e.querySelector('img')?.src === avatar)) || rows.find(e => titleOf(e) === name);
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
          style.textContent = '[class*="componentsEntrywrapper"] > .semi-resizable-resizable {display:none!important} [class*="componentsRightPanelwrapper"] {width:100%!important;max-width:none!important;flex:1!important;min-width:0!important} [class*="componentsEntrywrapper"] {min-width:0!important;width:100%!important}';
          window.__wuweiMinWidth = 320;
          window.__wuweiFixViewport?.();
          window.dispatchEvent(new Event('resize'));
          return 'ok';
        """#
        let r = try? await web.callAsyncJavaScript(script, arguments: ["name": row.name, "avatar": row.avatar ?? "", "stranger": row.stranger ? "1" : "0"], contentWorld: .page)
        if (r as? String) == "ok" { return .opened }
        DYLiveModel.log("DDCHAT opener miss name=\(row.name) stranger=\(row.stranger) r=\(String(describing: r))")
        return .notFound
    }

    static func restoreList(_ web: WKWebView) async {
        chatVisible = false
        _ = try? await web.evaluateJavaScript("document.getElementById('dd-chat-only')?.remove(); window.__wuweiMinWidth=760; window.__wuweiFixViewport?.(); window.dispatchEvent(new Event('resize')); true")
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
        _ = try? await web.evaluateJavaScript(collapseStrangerJS)
        try? await Task.sleep(for: .milliseconds(300))
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
    // 冷启动时面板先只挂第一行、几秒后才补齐：至少等 3s，且行数连续 2s 不变
    let last = -1, stable = 0, waited = 0;
    while (waited < 12000) {
      const n = document.querySelectorAll(rowSel).length;
      stable = (n > 0 && n === last) ? stable + 1 : 0; last = n;
      if (stable >= 7 && waited >= 3000) break;
      await sleep(300); waited += 300;
    }
    return last;
    """#

    /// 逐屏滚动虚拟列表采集全部陌生人会话（callAsyncJavaScript 函数体，可 await）
    private static let collectStrangerJS = #"""
    const sel = '[class*="StrangerConversationList"] [data-e2e="conversation-item"]';
    const sleep = ms => new Promise(r => setTimeout(r, ms));
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
      seen.set(id, { id, name, avatar, preview: txt('[class*="HinttextBox"]'), time: txt('[class*="timeStr"]'), badge, index: '0', stranger: true, _y: y, _o: order++ });
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
    @ObservedObject private var cache = DYMessageCache.shared
    @Environment(\.dismiss) private var dismiss
    @State private var status = "正在读取陌生人消息…"
    @State private var opening: String?

    /// 先放主列表里「我没关注」的人（较新），再放网页陌生人面板里的人
    private var allRows: [DYConversationRow] {
        let ids = Set(cache.unfollowedRows.map(\.id))
        return cache.unfollowedRows + cache.strangerRows.filter { !ids.contains($0.id) }
    }

    var body: some View {
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
        .navigationTitle(DYMsgRoute.stranger.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if opening != nil { ProgressView().tint(.white) } }
        .task { await refresh() }
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
        HStack(spacing: 12) {
            CachedAsyncImage(url: row.avatar.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
            }
            .frame(width: 50, height: 50).clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(row.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(row.preview).font(.footnote).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                Text(row.time).font(.caption2).foregroundStyle(.white.opacity(0.45))
                if !row.badge.isEmpty {
                    Text(row.badge).font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// 选中这个人 → 回消息根页，由根页全屏显示网页聊天；返回时回到消息根页
    private func open(_ row: DYConversationRow) async {
        guard let web = cache.chatModel.web else { return }
        opening = row.id
        defer { opening = nil }
        switch await DYChatOpener.open(row, web: web) {
        case .opened:
            cache.selectedChat = row
            dismiss()
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
        .onDisappear { model.panelVisible = false }
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
        .onAppear { DDPlayback.shared.pauseAll() }
        .onDisappear {
            model.stop()
            if UIApplication.shared.applicationState == .active { DDPlayback.shared.resumeAll() }
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
    /// Restore disk immediately at launch, then refresh once in the shared hidden context.
    /// Changing the playing video does not request the contact list again.
    func prepareContactPreload(item: DYAweme?) async -> URL? {
        guard !layoutFixture, !sending, !panelVisible else { return nil }
        await DYMessageCache.shared.prepare()
        guard !Task.isCancelled else { return nil }
        restorePeople(scope: DYMessageCache.shared.accountScope, refreshRemote: false)
        if let existing = retainedWeb, let url = existing.url {
            preloadTarget = url
            if !existing.isLoading, DYForwardRefreshPolicy.shouldRefresh(lastUpdate: lastRemoteRefresh) {
                existing.reload()
            }
            return url
        }
        guard let item else { return nil }
        if let lastPreloadAttempt, Date().timeIntervalSince(lastPreloadAttempt) < 60 { return nil }
        lastPreloadAttempt = Date()
        preloadTarget = item.webURL
        return item.webURL
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

/// One host at the feed root, retained across video changes and handed to the share panel.
struct DYForwardPreloadHost: View {
    let item: DYAweme?
    let enabled: Bool
    @ObservedObject private var model = DYForwardWebModel.cachedNative
    @Environment(\.scenePhase) private var scenePhase
    @State private var target: URL?

    var body: some View {
        Group {
            if enabled, !model.panelVisible, let target {
                DYForwardWebContainer(model: model, url: target)
                    .frame(width: 760, height: 640)
                    .frame(width: 1, height: 1).clipped().opacity(0.001)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: enabled && !model.panelVisible ? item?.id ?? "startup" : "") {
            guard enabled, !model.panelVisible else { target = nil; return }
            // The first usable video supplies the official share context. Keep it across swipes.
            guard target == nil else { return }
            let url = await model.prepareContactPreload(item: item)
            guard !Task.isCancelled else { return }
            target = url
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, enabled, !model.panelVisible else { return }
            Task {
                let url = await model.prepareContactPreload(item: item)
                guard !Task.isCancelled, !model.panelVisible else { return }
                target = url
            }
        }
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
}

extension DYMessagesScreen {
    /// 顶栏红点用的未读合计。700 有数用 700，否则加总。
    static func badge(_ groups: [DYNoticeCount]) -> Int {
        if let all = groups.first(where: { $0.group == DYNoticeGroup.all.rawValue }) { return all.count }
        return groups.reduce(0) { $0 + $1.count }
    }
}
