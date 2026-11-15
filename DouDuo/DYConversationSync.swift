import Foundation
import WebKit

/// 会话列表的读取与合并。
/// 以前只有「消息页打开着」才读列表（`DYMessagesScreen.readConversations`），
/// 所以进信息页要等网页登录态、等 DOM、再扫一遍列表；点会话还要现场找行。
/// 抽出来以后后台预热（`DYChatPrewarm`）和消息页共用同一套逻辑：
/// 首页还在刷视频的时候列表就已经读好并落盘了，进消息页直接命中缓存。
@MainActor
enum DYConversationSync {
    struct Outcome {
        var rows: [DYConversationRow] = []
        /// 需要显示给用户的状态文案（空列表/登录失效/失败）
        var status: String?
        var changed = false
    }

    /// 读一次网页会话列表，把差异合并进缓存并落盘。调用方不再自己拼合并逻辑。
    static func read(web: WKWebView, account: String) async -> Outcome {
        let cache = DYMessageCache.shared
        guard !account.isEmpty else { return Outcome() }
        _ = try? await web.callAsyncJavaScript("window.__ddAccountScope = scope;",
                                              arguments: ["scope": account], contentWorld: .page)
        let raw: String?
        do {
            raw = try await web.evaluateJavaScript(DYMessagesScreen.conversationsJS) as? String
        } catch {
            return Outcome(status: "私信加载失败，请稍后重试")
        }
        guard let raw, let data = raw.data(using: .utf8),
              let delta = try? JSONDecoder().decode(DYMessagesScreen.ConversationDelta.self, from: data)
        else { return Outcome() }
        guard cache.accountScope == account else { return Outcome() }

        var outcome = Outcome()
        if delta.items.isEmpty {
            if delta.visible == 0 {
                let text = (try? await web.evaluateJavaScript("document.body.innerText")) as? String ?? ""
                outcome.status = text.contains("验证码登录") ? "私信需要登录，请使用网页版 / 登录" : "正在加载会话；如无记录可稍后重试"
            }
            _ = try? await web.callAsyncJavaScript(DYMessagesScreen.conversationsAckJS,
                                                  arguments: ["revision": delta.revision], contentWorld: .page)
            outcome.rows = cache.snapshot.conversations
            return outcome
        }

        let existing = cache.snapshot.conversations
        let oldRows = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let capturedAt = Date().timeIntervalSince1970
        let rows = delta.items.map { row -> DYConversationRow in
            var next = row
            next.avatar = DYChatImageCache.originalURL(next.avatar)
            if let old = oldRows[row.id], old.time == row.time, old.preview == row.preview {
                next.observedAt = old.observedAt ?? capturedAt
            } else { next.observedAt = capturedAt }
            return next
        }
        let updated = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let existingIDs = Set(existing.map(\.id))
        // 按最后消息时间倒序：有新消息的会话排最上面
        let merged = (rows.filter { !existingIDs.contains($0.id) } + existing.map { updated[$0.id] ?? $0 })
            .sorted(by: DYConversationRow.byTimeDesc)
        cache.reconcileHiddenConversations(merged)
        if merged != existing {
            cache.snapshot.conversations = merged
            cache.save()
            outcome.changed = true
        }
        outcome.rows = merged
        // 合并成功才推进网页差异基线；异常/换账号时下次仍会重发这些行
        _ = try? await web.callAsyncJavaScript(DYMessagesScreen.conversationsAckJS,
                                              arguments: ["revision": delta.revision], contentWorld: .page)
        cache.retainChat()
        await cache.resolveFollow(merged.compactMap { $0.kind == 1 ? $0.sec : nil })
        return outcome
    }
}

/// 信息板块后台预热：刷视频时就把私信网页挂起来、列表读好。
/// 老板要求「进信息页完全不用重新加载」——靠的就是这里在后台把 DOM 和缓存都准备好。
/// 只在 App 前台、且消息页没打开时工作；进后台立刻停，不白耗电。
@MainActor
final class DYChatPrewarm {
    static let shared = DYChatPrewarm()
    private var lastRead = Date.distantPast
    private var lastPrepare = Date.distantPast
    private var lastLog = Date.distantPast
    private var reads = 0
    private var rows = 0
    /// 列表刷新间隔：够新鲜又不烧 CPU（网页自身也在走增量，这里只是兜一层）
    private let interval: TimeInterval = 5

    func tick(web: WKWebView?, messagesVisible: Bool) async {
        guard !messagesVisible else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        let now = Date()
        if now.timeIntervalSince(lastPrepare) > 30 {
            lastPrepare = now
            await DYMessageCache.shared.prepare()
        }
        let cache = DYMessageCache.shared
        guard cache.hasSession, !cache.accountScope.isEmpty else { return }
        guard let web, !web.isLoading else { return }
        guard now.timeIntervalSince(lastRead) >= interval else { return }
        lastRead = now
        let t0 = Date()
        let out = await DYConversationSync.read(web: web, account: cache.accountScope)
        reads += 1
        rows = out.rows.count
        if now.timeIntervalSince(lastLog) > 60 {
            lastLog = now
            DYLiveModel.log("DDMSGPREWARM reads=\(reads) rows=\(rows) last_ms=\(Int(Date().timeIntervalSince(t0) * 1000)) changed=\(out.changed)")
        }
    }
}
