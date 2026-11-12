// DouDuo 扩展功能：搜索 / 我的（喜欢·收藏·历史·稍后再看）/ 关注 / 作者主页 / 弹幕 / 楼中楼 / 保存到相册
// 全部接口都走隐藏签名页（DouyinBridge.call），和推荐流同一套签名，不逆向。
import SwiftUI
import Combine
import AVFoundation
import Photos

// MARK: - 数据

extension DYAweme.Author: Identifiable { public var id: String { secUid ?? name } }

struct DYDanmaku: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let offset: Double      // 秒
}

struct DYUser: Decodable, Equatable {
    let name: String
    let avatar: String?
    let signature: String
    let secUid: String
    let uid: String
    let followers: Int
    let following: Int
    let likes: Int
    let works: Int
    let ip: String?
}

/// 评论表情（抖音官方表情包）
struct DYEmoji: Codable, Identifiable, Hashable {
    var id: String { displayName }
    let displayName: String      // 形如 [微笑]，发送时就发这个文本
    let url: String?             // CDN 图片（签名长期有效）
}
private struct DYEmojiResp: Decodable { let status: Int; let items: [DYEmoji] }

/// @ 面板里的人（关注的人）
struct DYFriend: Codable, Identifiable, Hashable {
    var id: String { secUid.isEmpty ? name : secUid }
    let name: String
    let avatar: String?
    let secUid: String
}
private struct DYFriendPage: Decodable { let status: Int; let items: [DYFriend]; let cursor: String; let hasMore: Bool }

/// 抖音热搜一条：pos 为空 = 置顶条
struct DYHot: Decodable, Equatable {
    let word: String
    let hot: Int
    let pos: Int?
}

struct DYSug: Identifiable, Decodable, Equatable {
    var id: String { word }
    let word: String
}

enum DYListKind: String, CaseIterable, Identifiable {
    case post, like, collect, history, later
    var id: String { rawValue }
    var title: String {
        switch self {
        case .post: "作品"
        case .like: "喜欢"
        case .collect: "收藏"
        case .history: "历史"
        case .later: "稍后再看"
        }
    }
}

private struct DYListPage: Decodable { let status: Int; let items: [DYAweme]; let cursor: String; let hasMore: Bool; let code: Int?; let msg: String? }
private struct DYDanmakuPage: Decodable { let status: Int; let items: [DYDanmaku] }
private struct DYReplyPage: Decodable { let status: Int; let items: [DYComment]; let cursor: Int; let hasMore: Bool; let msg: String? }
private struct DYPublishResp: Decodable { let status: Int; let code: Int?; let msg: String?; let comment: DYComment?; let danmakuID: String?; let diagnostic: String? }
private struct DYUserResp: Decodable { let status: Int; let user: DYUser?; let msg: String? }
private struct DYSugResp: Decodable { let status: Int; let items: [DYSug] }

// MARK: - 接口

extension DouyinBridge {
    /// 列表通用：喜欢 / 收藏 / 历史 / 稍后再看 / 关注 / 搜索，统一回 (items, cursor, hasMore)
    private func list(_ js: String, _ args: [String: Any]) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        let d = try await cachedRead(js, args: args)
        let p = try JSONDecoder().decode(DYListPage.self, from: d)
        if p.code == 8 || (p.msg ?? "").contains("未登录") { throw DYError.bad("抖音未登录：右上「我的」→ 登录") }
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    func selfSecUid() async throws -> String {
        if let s = selfSecCache { return s }
        let u = try await selfProfile()
        selfSecCache = u.secUid
        return u.secUid
    }

    func selfProfile() async throws -> DYUser {
        let d = try await cachedRead(Self.selfJS, args: [:])
        let r = try JSONDecoder().decode(DYUserResp.self, from: d)
        guard let u = r.user, !u.secUid.isEmpty else { throw DYError.bad(r.msg ?? "抖音未登录") }
        selfSecCache = u.secUid   // 顶栏头像一读到自己就记下，推荐流「关注 +」靠它认出自己的作品
        return u
    }

    func userProfile(_ sec: String) async throws -> DYUser {
        let d = try await cachedRead(Self.otherJS, args: ["sec": sec], maxAge: 180)
        let r = try JSONDecoder().decode(DYUserResp.self, from: d)
        guard let u = r.user else { throw DYError.bad(r.msg ?? "读取作者信息失败") }
        return u
    }

    func myList(_ kind: DYListKind, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        switch kind {
        case .post:
            let sec = try await selfSecUid()
            return try await list(Self.postJS, ["sec": sec, "cursor": cursor])
        case .like:
            let sec = try await selfSecUid()
            return try await list(Self.likeJS, ["sec": sec, "cursor": cursor])
        case .collect: return try await list(Self.collectJS, ["cursor": cursor])
        case .history: return try await list(Self.historyJS, ["cursor": cursor])
        case .later: return try await list(Self.laterJS, ["cursor": cursor])
        }
    }

    func followFeed(cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        // 未登录时抖音的关注流接口不报错，会塞推荐内容（游客兜底）。
        // 必须先确认登录态，否则「关注」页会显示一堆不是关注的人。
        // 登录校验和关注流并发发出（省一个往返）；校验不过照样抛错，不会把游客兜底内容交出去。
        let r: (items: [DYAweme], cursor: String, hasMore: Bool)
        if cursor == "0", selfSecCache == nil {
            async let me = selfProfile()
            async let page = list(Self.followJS, ["cursor": cursor])
            selfSecCache = try await me.secUid
            r = try await page
        } else {
            r = try await list(Self.followJS, ["cursor": cursor])
        }
        #if DEBUG
        if cursor == "0" {
            let me = try? await selfProfile()
            let who = me.map { "\($0.name)(关注\($0.following)/粉丝\($0.followers))" } ?? "未登录"
            let names = r.items.prefix(6).map { "\($0.author.name)[f\($0.author.follow ?? -1)]" }.joined(separator: " | ")
            DYLiveModel.log("DDFOLLOW me=\(who) n=\(r.items.count) more=\(r.hasMore) cur=\(r.cursor) first=\(names)")
        }
        #endif
        return r
    }

    /// 评论表情列表（抖音官方表情包，214 个；displayName 形如 [微笑]，发送时就发这个文本）
    func emojiList() async -> [DYEmoji] {
        guard let d = try? await cachedRead(Self.emojiJS, args: [:], attempts: 2),
              let r = try? JSONDecoder().decode(DYEmojiResp.self, from: d) else { return [] }
        let items = r.items.filter { !$0.displayName.isEmpty }
        #if DEBUG
        DYLiveModel.log("DDEMOJI status=\(r.status) n=\(items.count) hasUrl=\(items.filter { $0.url != nil }.count)")
        #endif
        return items
    }

    /// @ 面板的人：抖音评论 @ 的专用接口 familiar/atlist（返回「朋友」：互关/最近互动）
    func followingUsers(cursor: String = "0") async throws -> (items: [DYFriend], cursor: String, hasMore: Bool) {
        let d = try await call(Self.atListJS, args: ["cursor": cursor], attempts: 2)
        let p = try JSONDecoder().decode(DYFriendPage.self, from: d)
        #if DEBUG
        DYLiveModel.log("DDFOLLOWING status=\(p.status) n=\(p.items.count) more=\(p.hasMore) first=\(p.items.prefix(3).map(\.name).joined(separator: ","))")
        #endif
        if p.status != 200 { throw DYError.blocked("HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 搜索：网页接口只给第一页（翻第二页安全 SDK 直接压住不返回，换参数 / search_id 都一样）
    /// → 只拉一次、hasMore 置 false，免得底部一直转圈或报「拦截」
    func search(_ kw: String, offset: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        guard offset == "0" else { return ([], offset, false) }
        let r = try await list(Self.searchJS, ["kw": kw, "cursor": "0"])
        return (r.items, r.cursor, false)
    }

    /// 抖音热搜
    func hotSearch() async -> [DYHot] {
        guard let d = try? await cachedRead(Self.hotJS, args: [:], attempts: 1) else { return [] }
        return (try? JSONDecoder().decode([DYHot].self, from: d)) ?? []
    }

    func suggest(_ kw: String) async -> [DYSug] {
        guard let d = try? await cachedRead(Self.sugJS, args: ["kw": kw], attempts: 1),
              let r = try? JSONDecoder().decode(DYSugResp.self, from: d) else { return [] }
        return r.items
    }

    func danmaku(_ id: String, durationMs: Int) async throws -> [DYDanmaku] {
        let d = try await cachedRead(Self.danmakuJS, args: ["id": id, "dur": String(max(durationMs, 15000))], attempts: 1)
        let r = try JSONDecoder().decode(DYDanmakuPage.self, from: d)
        return r.items.sorted { $0.offset < $1.offset }
    }

    func fetchReplies(_ id: String, commentID: String, cursor: Int) async throws -> (items: [DYComment], cursor: Int, hasMore: Bool) {
        let d = try await cachedRead(Self.replyJS, args: ["id": id, "cid": commentID, "cursor": String(cursor)], attempts: 1)
        let p = try JSONDecoder().decode(DYReplyPage.self, from: d)
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 发评论 / 回复评论（replyID 非空 = 回复那条）
    func publishComment(_ awemeID: String, text: String, replyID: String? = nil) async throws -> DYComment {
        invalidateReadCache()
        defer { invalidateReadCache() }
        let d = try await call(Self.publishJS, args: ["id": awemeID, "text": text, "reply": replyID ?? "0"], attempts: 1)
        let r = try JSONDecoder().decode(DYPublishResp.self, from: d)
        DYLiveModel.log("DDSEND comment status=\(r.status) code=\(r.code ?? -1) msg=\(r.msg ?? "-") diag=\(r.diagnostic ?? "-")")
        if r.status == Self.guardRefusedStatus { throw DYError.bad(Self.guardRefusedMessage) }
        if r.code == 8 { throw DYError.bad("抖音未登录") }
        guard r.status == 200, (r.code ?? 0) == 0, let c = r.comment else {
            throw DYError.bad(r.msg?.isEmpty == false ? r.msg! : "发送失败（HTTP \(r.status) / \(r.code ?? -1)）")
        }
        return c
    }

    func deleteComment(_ cid: String) async -> Bool {
        invalidateReadCache()
        defer { invalidateReadCache() }
        guard let d = try? await call(Self.deleteCommentJS, args: ["cid": cid], attempts: 1),
              let r = try? JSONDecoder().decode(DYPublishResp.self, from: d) else { return false }
        return r.status == 200 && (r.code ?? 0) == 0
    }

    /// 发视频弹幕（offset 秒 = 出现在视频的哪个时间点）
    func postDanmaku(_ awemeID: String, text: String, offset: Double) async throws -> String {
        invalidateReadCache()
        defer { invalidateReadCache() }
        let d = try await call(Self.danmakuPostJS, args: ["id": awemeID, "text": text, "offset": String(Int(max(0, offset) * 1000))], attempts: 1)
        let r = try JSONDecoder().decode(DYPublishResp.self, from: d)
        DYLiveModel.log("DDSEND danmaku status=\(r.status) code=\(r.code ?? -1) msg=\(r.msg ?? "-") id=\(r.danmakuID ?? "-")")
        if r.status == Self.guardRefusedStatus { throw DYError.bad(Self.guardRefusedMessage) }
        if r.code == 8 { throw DYError.bad("抖音未登录") }
        guard r.status == 200, (r.code ?? 0) == 0 else {
            throw DYError.bad(r.msg?.isEmpty == false ? r.msg! : "发送失败（HTTP \(r.status) / \(r.code ?? -1)）")
        }
        return r.danmakuID ?? UUID().uuidString
    }

    func deleteDanmaku(_ id: String) async -> Bool {
        invalidateReadCache()
        defer { invalidateReadCache() }
        guard let d = try? await call(Self.danmakuDeleteJS, args: ["did": id], attempts: 1),
              let r = try? JSONDecoder().decode(DYPublishResp.self, from: d) else { return false }
        return r.status == 200 && (r.code ?? 0) == 0
    }

    private static let cmap = #"""
    const cmap = c => c ? ({ id: String(c.cid), text: c.text || '', name: (c.user && c.user.nickname) || '', avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || Math.floor(Date.now() / 1000), replies: 0, ip: c.ip_label || null }) : null;
    """#

    // 网页版同款：params 放 app_name/enter_from，body 放 aweme_id/text（安全 SDK 会自动补签名头）
    static let publishJS = cmap + #"""
    const P = q({ app_name: 'aweme', enter_from: 'video_detail', previous_page: 'video_detail' });
    const body = new URLSearchParams({ aweme_id: id, text: text, text_extra: '[]', comment_send_celltime: '0', comment_video_celltime: '0' });
    if (reply && reply !== '0') { body.set('reply_id', reply); body.set('reply_to_reply_id', '0'); }
    const r = await req('POST', '/aweme/v1/web/comment/publish?' + P, body.toString());
    const raw = r.t || '', parsed = parse(raw), d = parsed || {};
    const kind = !raw.trim() ? 'empty' : parsed !== null ? 'json' : /^\s*</.test(raw) ? 'html' : 'other';
    // 只记录形状，不记录响应正文、评论内容、cookie 或 token；写操作不自动重试。
    const keys = Object.keys(d).filter(k => /^[a-zA-Z_]+$/.test(k)).slice(0, 12).join(',');
    const diagnostic = 'kind=' + kind + ' chars=' + raw.length + ' keys=' + keys;
    const fallback = kind === 'empty' ? '抖音返回空响应，未能确认评论是否发送，请勿连续重发'
      : kind === 'html' ? '抖音返回了网页而非评论结果，请在网页版查看是否有验证提示'
      : '未收到有效的评论确认结果，请勿连续重发';
    const msg = d.status_msg || ((!d.comment || d.status_code !== 0 || r.s !== 200) ? fallback : null);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg, comment: cmap(d.comment), danmakuID: null, diagnostic });
    """#

    static let deleteCommentJS = #"""
    const r = await req('POST', '/aweme/v1/web/comment/delete?' + q({ cid: cid, channel_id: '0', app_name: 'aweme' }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, comment: null, danmakuID: null });
    """#

    static let danmakuPostJS = #"""
    const r = await req('POST', '/aweme/v1/web/danmaku/post_v2/?' + q({ item_id: id, offset_time: offset, text: text, user_id: '', enter_from: 'video_detail', previous_page: 'video_detail' }), '');
    const d = parse(r.t) || {};
    const dm = d.danmaku || d.data || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)), comment: null,
      danmakuID: dm.danmaku_id ? String(dm.danmaku_id) : (d.danmaku_id ? String(d.danmaku_id) : null) });
    """#

    static let danmakuDeleteJS = #"""
    const r = await req('POST', '/aweme/v1/web/danmaku/delete_v2/?' + q({ app_name: 'aweme', format: 'json', user_type: '1', danmaku_id: did }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, comment: null, danmakuID: null });
    """#

    // MARK: JS（requestJS 里有 req / base / parse / first / q / mapA）

    private static let listTail = #"""
    const pack = (r, d, arr, cur, more) => JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)),
      items: (arr || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA), cursor: String(cur ?? 0), hasMore: !!more });
    """#

    private static let userMap = #"""
    const umap = u => u ? ({ name: u.nickname || '', avatar: first(u.avatar_larger) || first(u.avatar_thumb), signature: u.signature || '',
      secUid: u.sec_uid || '', uid: u.uid ? String(u.uid) : '', followers: u.follower_count || u.mplatform_followers_count || 0, following: u.following_count || 0,
      likes: u.total_favorited || 0, works: u.aweme_count || 0, ip: u.ip_location || null }) : null;
    """#

    static let selfJS = userMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/self/?' + q({ publish_video_strategy_type: '2', source: 'channel_pc_web', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, user: umap(d.user), msg: d.status_msg || null });
    """#

    static let otherJS = userMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/other/?' + q({ sec_user_id: sec, publish_video_strategy_type: '2', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, user: umap(d.user), msg: d.status_msg || null });
    """#

    static let postJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/aweme/post/?' + q({ sec_user_id: sec, max_cursor: cursor, locate_query: 'false', show_live_replay_strategy: '1', need_time_list: '1', time_list_query: '0', whale_cut_token: '', cut_version: '1', count: '18' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let likeJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/aweme/favorite/?' + q({ sec_user_id: sec, max_cursor: cursor, min_cursor: '0', count: '18', cut_version: '1' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let collectJS = listTail + #"""
    const r = await req('POST', '/aweme/v1/web/aweme/listcollection/?' + q({ cursor: cursor, count: '18' }), 'count=18&cursor=' + cursor);
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.cursor, d.has_more);
    """#

    static let historyJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/history/read/?' + q({ max_cursor: cursor, count: '20' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let laterJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/watchlater/list/?' + q({ cursor: cursor, count: '20', offset: cursor }));
    const d = parse(r.t) || {};
    const arr = (d.items || []).map(x => x && (x.aweme || x.aweme_info || x)).filter(Boolean);
    return pack(r, d, arr, (d.offset ?? 0), d.has_more);
    """#

    static let followJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/follow/feed/?' + q({ cursor: cursor, level: '1', count: '20', pull_type: cursor === '0' ? '0' : '2' }));
    const d = parse(r.t) || {};
    const arr = (d.data || []).map(x => x && (x.aweme || x.aweme_info)).filter(Boolean);
    return pack(r, d, arr, d.cursor, d.has_more);
    """#

    static let emojiJS = #"""
    const r = await req('GET', '/aweme/v1/web/emoji/list/?' + q({}));
    const d = parse(r.t) || {};
    const arr = (d.emoji_list || []).filter(e => e && e.display_name && !e.hide)
      .map(e => ({ displayName: e.display_name, url: ((e.emoji_url || {}).url_list || [])[0] || null }));
    return JSON.stringify({ status: r.s, items: arr });
    """#

    static let atListJS = #"""
    const r = await req('GET', '/aweme/v1/web/familiar/atlist/?' + q({ count: '20', cursor: cursor, scene: 'comment' }));
    const d = parse(r.t) || {};
    const arr = (d.user_list || []).filter(u => u).map(u => ({
      name: u.nickname || '',
      avatar: first(u.avatar_thumb) || first(u.avatar_168x168) || first(u.avatar_300x300),
      secUid: u.sec_uid || ''
    }));
    return JSON.stringify({ status: r.s, items: arr, cursor: String(d.cursor || 0), hasMore: !!d.has_more });
    """#

    static let followingJS = #"""
    const r = await req('GET', '/aweme/v1/web/user/following/list/?' + q({ sec_user_id: sec, count: '30', cursor: cursor, offset: cursor, source_type: '1' }));
    const d = parse(r.t) || {};
    const arr = (d.followings || []).filter(u => u).map(u => ({ name: u.nickname || '', avatar: first(u.avatar_thumb) || first(u.avatar_medium), secUid: u.sec_uid || '' }));
    return JSON.stringify({ status: r.s, items: arr, cursor: String(d.cursor || 0), hasMore: !!d.has_more });
    """#

    static let searchJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/search/item/?' + q({ search_channel: 'aweme_video_web', keyword: kw, search_source: 'normal_search',
      query_correct_type: '1', is_filter_search: '0', from_group_id: '', offset: cursor, count: '24', need_filter_settings: cursor === '0' ? '1' : '0', list_type: 'single' }));
    const d = parse(r.t) || {};
    const arr = (d.data || []).map(x => x && (x.aweme_info || x.aweme)).filter(Boolean);
    return pack(r, d, arr, d.cursor, d.has_more);
    """#

    static let hotJS = #"""
    const r = await req('GET', '/aweme/v1/web/hot/search/list/?' + q({ detail_list: '1', source: '6', board_type: '0', board_sub_type: '' }));
    const d = parse(r.t) || {};
    const wl = ((d.data || {}).word_list) || [];
    return JSON.stringify(wl.filter(w => w && w.word).map(w => ({ word: w.word, hot: w.hot_value || 0, pos: w.position ?? null })));
    """#

    static let sugJS = #"""
    const r = await req('GET', '/aweme/v1/web/search/sug/?' + q({ keyword: kw, source: 'aweme_video_web', from_group_id: '' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.sug_list || []).map(s => ({ word: s.content || '' })).filter(s => s.word) });
    """#

    static let danmakuJS = #"""
    const r = await req('GET', '/aweme/v1/web/danmaku/get_v2/?' + q({ app_name: 'aweme', format: 'json', group_id: id, item_id: id, start_time: '0', end_time: dur, duration: dur }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.danmaku_list || []).filter(x => x && x.text).map(x => ({ id: String(x.danmaku_id), text: x.text, offset: (x.offset_time || 0) / 1000 })) });
    """#

    static let replyJS = #"""
    let r = await req('GET', '/aweme/v2/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cut_version: '1', cursor: cursor, count: '10', item_type: '0' }));
    let d = parse(r.t);
    if (!d || !Array.isArray(d.comments)) {
      r = await req('GET', '/aweme/v1/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cut_version: '1', cursor: cursor, count: '10', item_type: '0' }));
      d = parse(r.t);
    }
    if (!d) {
      r = await req('GET', '/aweme/v1/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cursor: cursor, count: '10', item_type: '0', whale_cut_token: '', cut_version: '1', rcFT: '' }));
      d = parse(r.t);
    }
    if (!d) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [], cursor: 0, hasMore: false, msg: '抖音没返回回复（网页接口受限）' });
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
      digg: c.digg_count || 0, time: c.create_time || 0, replies: 0, ip: c.ip_label || null,
      images: ddImages(c), sticker: ddSticker(c) }));
    return JSON.stringify({ status: r.s, items, cursor: d.cursor || 0, hasMore: !!d.has_more, msg: null });
    """#
}

/// 当前在播视频的进度（PlayerPage 周期性写入；发弹幕时取）
@MainActor enum DDNowPlaying {
    static var id = ""
    static var time: Double = 0
}

// MARK: - 弹幕调度策略

/// 仅影响视频滚动弹幕：上方三分之一、密度限流与短时间相同内容去重。
fileprivate enum DYDanmakuPolicy {
    static let laneHeight: CGFloat = 28
    static let gap: CGFloat = 28
    static let densityKey = "douyin_video_danmaku_density_v1"
    static let deduplicateKey = "douyin_video_danmaku_deduplicate_v1"

    enum Density: Int, CaseIterable, Identifiable {
        case sparse = 0, standard = 1, dense = 2
        var id: Int { rawValue }
        var title: String {
            switch self { case .sparse: "稀疏"; case .standard: "标准"; case .dense: "密集" }
        }
        var maxLanes: Int {
            switch self { case .sparse: 2; case .standard: 4; case .dense: 6 }
        }
        var maxPerSecond: Int {
            switch self { case .sparse: 1; case .standard: 2; case .dense: 4 }
        }
    }
    struct Region { let top: CGFloat; let bottom: CGFloat; let lanes: Int }
    struct Placed { let d: DYDanmaku; let lane: Int; let width: CGFloat; let dur: Double }

    static func region(height: CGFloat, topInset: CGFloat, density: Density) -> Region {
        guard height.isFinite, height >= 0, topInset.isFinite else { return Region(top: 0, bottom: 0, lanes: 0) }
        let bottom = height / 3
        let top = max(0, topInset) + 64
        let available = max(0, ((bottom - top) / laneHeight).rounded(.down))
        return Region(top: top, bottom: bottom, lanes: Int(min(CGFloat(density.maxLanes), available)))
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .split(whereSeparator: { $0.isWhitespace }).joined()
    }

    static func layout(_ items: [DYDanmaku], w: CGFloat, lanes: Int, speed: CGFloat,
                       density: Density, deduplicate: Bool) -> [Placed] {
        guard w.isFinite, w > 0, speed.isFinite, speed > 0, lanes > 0 else { return [] }
        var free = Array(repeating: -Double.infinity, count: min(lanes, density.maxLanes))
        var out: [Placed] = []
        var seenIDs = Set<String>(), lastShown: [String: Double] = [:]
        var second = -Double.infinity, inSecond = 0
        let sorted = items.enumerated().filter { $0.element.offset.isFinite && $0.element.offset >= 0 }
            .sorted { $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset }
        for entry in sorted {
            let d = entry.element
            let text = normalized(d.text)
            guard !d.id.isEmpty, !text.isEmpty, !seenIDs.contains(d.id) else { continue }
            if deduplicate, let last = lastShown[text], d.offset - last < 10 { continue }
            let bucket = floor(d.offset)
            if bucket != second { second = bucket; inSecond = 0 }
            guard inSecond < density.maxPerSecond,
                  let lane = free.indices.first(where: { free[$0] <= d.offset }) else { continue }
            let width = d.text.unicodeScalars.reduce(CGFloat(6)) { $0 + ($1.value < 0x2E80 ? 9 : 16) }
            free[lane] = d.offset + Double((width + gap) / speed)
            out.append(Placed(d: d, lane: lane, width: width, dur: Double((w + width) / speed)))
            seenIDs.insert(d.id); lastShown[text] = d.offset; inSecond += 1
        }
        return out
    }
}

/// 共用在推荐、关注、搜索等视频的更多菜单，不给巨型视频页新增状态。
struct DYDanmakuOptions: View {
    var onSend: (() -> Void)? = nil
    @AppStorage("douyin_danmaku_v1") private var enabled = true
    @AppStorage(DYDanmakuPolicy.densityKey) private var density = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true

    var body: some View {
        Menu {
            if let onSend {
                Button("发弹幕", systemImage: "text.bubble", action: onSend)
                    .accessibilityIdentifier("douyin.danmaku.open")
            }
            Toggle("显示弹幕", isOn: $enabled)
                .accessibilityIdentifier("douyin.danmaku.enabled")
            Picker("弹幕密度", selection: $density) {
                ForEach(DYDanmakuPolicy.Density.allCases) { option in Text(option.title).tag(option.rawValue) }
            }
            .accessibilityIdentifier("douyin.danmaku.density")
            Toggle("10秒内重复去重", isOn: $deduplicate)
                .accessibilityIdentifier("douyin.danmaku.deduplicate")
            Text("显示区域：屏幕上方 1/3")
        } label: {
            Label("弹幕 · \((DYDanmakuPolicy.Density(rawValue: density) ?? .standard).title)", systemImage: "text.bubble")
        }
        .accessibilityIdentifier("douyin.danmaku.settings")
        .accessibilityValue("\((DYDanmakuPolicy.Density(rawValue: density) ?? .standard).title)，去重\(deduplicate ? "开启" : "关闭")")
    }
}

// MARK: - 弹幕层（视频）

/// 弹幕时钟：播放器每 0.25 秒报一次进度，弹幕按帧插值出「现在」的视频时间，否则位置一跳一跳。
/// 播放器报一次就校准一次（锚点 = 报的时间 + 报的时刻），中间按播放速率往前推。
struct DYDanmakuClock {
    var anchorTime: Double = 0
    var anchorDate = Date()
    var rate: Double = 1
    var playing = false

    func now(_ d: Date) -> Double {
        playing ? anchorTime + d.timeIntervalSince(anchorDate) * rate : anchorTime
    }

    mutating func sync(_ t: Double, playing p: Bool, rate r: Double) {
        let predicted = now(Date())
        // 进度跳了（拖动 / 循环回开头 / 卡顿）或状态变了：直接对齐；否则差不多就别动，避免往回抖
        if !p || !playing || r != rate || abs(predicted - t) > 0.35 {
            anchorTime = t
        } else {
            anchorTime = predicted + (t - predicted) * 0.2   // 小误差慢慢拉回
        }
        anchorDate = Date()
        playing = p
        rate = r
    }
}

/// 抖音同款滚动弹幕：所有弹幕同一速度从右往左飘（同速 → 同一轨道里后面的永远追不上前面的）。
/// 轨道按「前一条尾巴已经完全进屏 + 间距」分配，整条视频一次排好（布局只在弹幕列表 / 屏幕宽变化时重算）；
/// 某个时刻所有轨道都满就丢掉这一条（抖音也是这样）。
/// 机身温度状态。只给纯渲染节奏用（弹幕重绘帧率），不参与任何播放 / 数据逻辑。
final class DDThermal: ObservableObject {
    static let shared = DDThermal()
    @Published private(set) var state = ProcessInfo.processInfo.thermalState
    private init() {
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.state = ProcessInfo.processInfo.thermalState
        }
    }
    /// 弹幕重绘的最小帧间隔：常温跟屏幕刷新率（120Hz），发热后降到 60 / 30，
    /// 把 GPU / 主线程让给视频解码。弹幕位置按时间算，降帧不影响时间轴。
    var danmakuFrameInterval: Double? {
        switch state {
        case .nominal: return nil
        case .fair: return 1.0 / 60
        default: return 1.0 / 30
        }
    }
}

/// 位置用 TimelineView(.animation) 逐帧算（跟屏幕刷新率走，ProMotion 上 120Hz），不靠 SwiftUI 补间动画。
struct DYDanmakuLayer: View {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    let topInset: CGFloat
    @ObservedObject private var thermal = DDThermal.shared
    @AppStorage(DYDanmakuPolicy.densityKey) private var densityRaw = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true

    private var renderItems: [DYDanmaku] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_DM_STRESS"] == "1" {
            return (0..<600).map { DYDanmaku(id: "stress-\($0)", text: "弹幕流畅度测试 \($0)", offset: Double($0) * 0.15) }
        }
        #endif
        return items
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let density = DYDanmakuPolicy.Density(rawValue: densityRaw) ?? .standard
            let region = DYDanmakuPolicy.region(height: g.size.height, topInset: topInset, density: density)
            let speed = (w + 200) / 7
            let placed = DYDanmakuLayout.shared.get(renderItems, w: w, lanes: region.lanes, speed: speed,
                                                  density: density, deduplicate: deduplicate)
            TimelineView(.animation(minimumInterval: thermal.danmakuFrameInterval, paused: !clock.playing)) { ctx in
                let t = clock.now(ctx.date)
                // 只把此刻在屏幕上的那几条交给 Canvas：整条视频的弹幕可能有几百条，
                // 以前每一帧都要把全部条目当作 symbol 过一遍 diff。
                let visible = placed.filter { t >= $0.d.offset && t <= $0.d.offset + $0.dur }
                Canvas(rendersAsynchronously: false) { gc, _ in
                    var regionContext = gc
                    regionContext.clip(to: Path(CGRect(x: 0, y: region.top, width: w, height: max(0, region.bottom - region.top))))
                    for p in visible {
                        let x = w - CGFloat(t - p.d.offset) * speed
                        let y = region.top + CGFloat(p.lane) * DYDanmakuPolicy.laneHeight
                        guard let sym = regionContext.resolveSymbol(id: p.d.id) else { continue }
                        regionContext.draw(sym, at: CGPoint(x: x, y: y), anchor: .topLeading)
                    }
                } symbols: {
                    // 只排版一次，逐帧移动贴图；区域外再裁剪，避免遮挡下方内容。
                    ForEach(visible, id: \.d.id) { p in
                        Text(p.d.text)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
                            .lineLimit(1)
                            .fixedSize()
                            .tag(p.d.id)
                    }
                }
            }
            .frame(width: w, height: g.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// 精确缓存输入和设置：中间一条内容变化、密度/去重切换均立即重排。
@MainActor private final class DYDanmakuLayout {
    static let shared = DYDanmakuLayout()
    private struct Key: Equatable {
        let items: [DYDanmaku]
        let w: CGFloat
        let lanes: Int
        let speed: CGFloat
        let density: DYDanmakuPolicy.Density
        let deduplicate: Bool
    }
    private var key: Key?
    private var cache: [DYDanmakuPolicy.Placed] = []
    func get(_ items: [DYDanmaku], w: CGFloat, lanes: Int, speed: CGFloat,
             density: DYDanmakuPolicy.Density, deduplicate: Bool) -> [DYDanmakuPolicy.Placed] {
        let next = Key(items: items, w: w, lanes: lanes, speed: speed, density: density, deduplicate: deduplicate)
        if key != next {
            cache = DYDanmakuPolicy.layout(items, w: w, lanes: lanes, speed: speed, density: density, deduplicate: deduplicate)
            key = next
        }
        return cache
    }
}

// MARK: - 保存到相册

enum DYSaver {
    enum SaveError: LocalizedError {
        case denied, noURL
        var errorDescription: String? {
            switch self {
            case .denied: "没有相册权限：设置 → DouDuo → 照片 → 允许添加"
            case .noURL: "这条没有可下载的地址"
            }
        }
    }

    static func save(_ a: DYAweme) async throws {
        let st = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard st == .authorized || st == .limited else { throw SaveError.denied }
        if !a.images.isEmpty {
            var datas: [Data] = []
            for s in a.images { if let u = URL(string: s) { datas.append(try await download(u)) } }
            try await PHPhotoLibrary.shared().performChanges {
                for d in datas { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil) }
            }
            return
        }
        guard let s = a.play, let u = URL(string: s) else { throw SaveError.noURL }
        let data = try await download(u)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dd-\(a.id).mp4")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
        }
    }

    private static func download(_ u: URL) async throws -> Data {
        var r = URLRequest(url: u)
        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw DYError.bad("下载失败 HTTP \(h.statusCode)") }
        return d
    }
}

// MARK: - 封面网格（搜索 / 我的 / 作者）

struct DYGrid: View {
    let items: [DYAweme]
    let hasMore: Bool
    let loading: Bool
    let error: String?
    let onLoadMore: () -> Void
    let onOpen: (Int) -> Void
    var showsPlayCount = false
    private let cols = [GridItem(.adaptive(minimum: 140), spacing: 2)]

    var body: some View {
        // 底部哨兵只在真正滚进可视区时才翻页：ScrollView 的非惰性子视图会立刻 onAppear，
        // 直接 onAppear 会一页接一页把作者作品全拉下来（2026-11-07 实测）。
        GeometryReader { outer in
            ScrollView {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                        Button { onOpen(i) } label: { cell(a) }
                            .buttonStyle(.plain)
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center).padding(24)
                } else if loading {
                    ProgressView().tint(.white).padding(24)
                } else if items.isEmpty {
                    Text("这里还没有内容").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(40)
                } else if hasMore {
                    Color.clear
                        .frame(height: 40)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: DYBottomYKey.self, value: g.frame(in: .named("ddgrid")).minY)
                            }
                        )
                }
            }
            .coordinateSpace(name: "ddgrid")
            .onPreferenceChange(DYBottomYKey.self) { y in
                if y < outer.size.height - 16 { onLoadMore() }
            }
        }
    }

    private func cell(_ a: DYAweme) -> some View {
        Color.black.opacity(0.4)
            .aspectRatio(3/4, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: a.cover.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.white.opacity(0.06) }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if !a.images.isEmpty {
                    Image(systemName: "photo.on.rectangle").font(.caption).foregroundStyle(.white).padding(6)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    if !a.desc.isEmpty {
                        Text(a.desc).font(.caption2).lineLimit(2)
                    }
                    Label(showsPlayCount ? a.stats.play.map(DYFormat.count) ?? "—" : DYFormat.count(a.stats.digg),
                          systemImage: showsPlayCount ? "play" : "heart")
                        .font(.caption2.weight(.semibold))
                        .accessibilityLabel(showsPlayCount ? "播放量 \(a.stats.play.map(String.init) ?? "未提供")" : "点赞量 \(a.stats.digg)")
                        .accessibilityIdentifier(showsPlayCount ? "douyin.grid.playCount" : "douyin.grid.likeCount")
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .contentShape(Rectangle())
    }
}

private struct DYBottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

// MARK: - 列表播放器（从网格点进来，上下滑接着看）

struct DYListPlayer: View {
    let bridge: DouyinBridge
    let title: String
    @State var items: [DYAweme]
    @State private var currentID: String?
    let loadMore: (() async -> [DYAweme])?
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var liked: Set<String> = []
    @State private var collected: Set<String> = []
    @State private var showComments = false
    @State private var toast: String?
    @State private var loadingMore = false

    init(bridge: DouyinBridge, title: String, items: [DYAweme], start: Int,
         loadMore: (() async -> [DYAweme])? = nil, onAuthor: @escaping (DYAweme) -> Void) {
        self.bridge = bridge; self.title = title
        _items = State(initialValue: items)
        _currentID = State(initialValue: items.indices.contains(start) ? items[start].id : items.first?.id)
        self.loadMore = loadMore; self.onAuthor = onAuthor
        var l = Set<String>(), c = Set<String>()
        for a in items { if a.userDigged == 1 { l.insert(a.id) }; if a.isCollect == 1 { c.insert(a.id) } }
        _liked = State(initialValue: l); _collected = State(initialValue: c)
    }

    private var current: DYAweme? { items.first { $0.id == currentID } }

    var body: some View {
        GeometryReader { geo in
            let layout = DYCommentLayout(size: geo.size, fold: DYDuoMetrics.foldIsActive(geo),
                                         showComments: showComments)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                // 外屏：评论面板从底部升起，视频缩到上方继续播
                DYCommentDock(panelID: currentID, enabled: layout.docked, isOpen: $showComments) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            DYVideoPage(item: item, isCurrent: item.id == currentID, insets: geo.safeAreaInsets,
                                        resume: resume[item.id], liked: liked.contains(item.id), collected: collected.contains(item.id),
                                        onLike: { toggleLike(item.id, force: nil) }, onCollect: { toggleCollect(item.id) },
                                        onDoubleTap: { toggleLike(item.id, force: true) },
                                        onComments: { withAnimation(.snappy) { showComments.toggle() } },
                                        onSearch: {},
                                        onAuthor: { onAuthor(item) },
                                        onSavePosition: { resume[item.id] = $0 }, preloader: preloader,
                                        bridge: bridge, onToast: { show($0) }, onBack: { dismiss() },
                                        onSwipeLeftOverride: { dismiss() },
                                        onSwipeRightOverride: showComments ? { withAnimation(.snappy) { showComments = false } } : nil)
                                .frame(width: layout.videoWidth, height: layout.videoHeight)
                                .clipped()
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID, anchor: .top)
                .defaultScrollAnchor(.top)
                .scrollIndicators(.hidden)
                .frame(width: layout.videoWidth, height: layout.videoHeight, alignment: .topLeading)
                .clipped()
                } panel: {
                    if let cur = current {
                        DYCommentPanel(bridge: bridge, aweme: cur, onClose: { withAnimation(.snappy) { showComments = false } })
                            .id(cur.id)
                    }
                }
                .frame(width: layout.videoWidth, height: layout.videoHeight, alignment: .topLeading)

                if layout.showPanel, let cur = current {
                    DYCommentPanel(bridge: bridge, aweme: cur,
                                   onClose: layout.fold ? nil : { withAnimation(.snappy) { showComments = false } })
                        .frame(width: layout.sideBySide ? layout.panelWidth : geo.size.width,
                               height: layout.tableFold ? layout.panelHeight : geo.size.height)
                        .offset(x: layout.sideBySide ? layout.videoWidth : 0,
                                y: layout.tableFold ? layout.videoHeight : 0)
                        .id(cur.id)
                }

                if let t = toast {
                    Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.62)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(layout.docked ? nil : .snappy, value: showComments)
            .animation(.snappy, value: layout.fold)
        }
        .ignoresSafeArea()
        .onChange(of: currentID) { old, new in
            if new == nil, let old { currentID = old; return }
            guard let i = items.firstIndex(where: { $0.id == new }) else { return }
            preloader.update(items, current: i)
            if i >= items.count - 4, let loadMore, !loadingMore {
                loadingMore = true
                Task {
                    let more = await loadMore()
                    let seen = Set(items.map(\.id))
                    items.append(contentsOf: more.filter { !seen.contains($0.id) })
                    loadingMore = false
                }
            }
        }
        .onAppear { if let i = items.firstIndex(where: { $0.id == currentID }) { preloader.update(items, current: i) } }
        .onDisappear { preloader.clear() }
    }

    private func show(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if toast == s { toast = nil } }
    }

    private func toggleLike(_ id: String, force: Bool?) {
        let has = liked.contains(id), want = force ?? !has
        guard want != has else { return }
        if want { liked.insert(id) } else { liked.remove(id) }
        Task {
            let r = try? await bridge.digg(id, like: want)
            if case .ok = r { return }
            if want { liked.remove(id) } else { liked.insert(id) }
            show(r.map { if case .notLoggedIn = $0 { return "抖音未登录" } else { return "点赞失败" } } ?? "点赞失败")
        }
    }

    private func toggleCollect(_ id: String) {
        let want = !collected.contains(id)
        if want { collected.insert(id) } else { collected.remove(id) }
        Task {
            let r = try? await bridge.favorite(id, add: want)
            if case .ok = r { show(want ? "已收藏" : "已取消收藏"); return }
            if want { collected.remove(id) } else { collected.insert(id) }
            show("收藏失败")
        }
    }
}

// MARK: - 通用分页列表模型

@MainActor
final class DYPagedModel: ObservableObject {
    @Published var items: [DYAweme] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    private var cursor = "0"
    private var generation = UUID()
    /// items 目前是上次保存的快照（秒开用），还没被网络首页校正
    private(set) var isStale = false
    /// 网络首页拿到后回调（空数组 = 确认未登录，快照该作废）
    var onFirstPage: (([DYAweme]) -> Void)?
    private let fetch: (String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool)

    init(fetch: @escaping (String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool)) {
        self.fetch = fetch
    }

    func reset() { generation = UUID(); loading = false; items = []; cursor = "0"; hasMore = true; error = nil; isStale = false }

    /// 先放上次的首页快照，界面立刻有内容；随后的 loadMore 仍从第一页拉，回来后合并校正
    func seed(_ cached: [DYAweme]) {
        guard items.isEmpty, cursor == "0", !cached.isEmpty else { return }
        items = cached
        isStale = true
    }

    @discardableResult
    func loadMore() async -> [DYAweme] {
        guard !loading, hasMore else { return [] }
        let request = generation
        let from = cursor
        loading = true
        defer { if request == generation { loading = false } }
        do {
            let r = try await fetch(from)
            guard request == generation, !Task.isCancelled else { return [] }
            let playable = r.items.filter { $0.play != nil || !$0.images.isEmpty }
            let fresh: [DYAweme]
            if isStale {
                // 新首页排前面；快照里正在看/看过的条目保留在后面，不删 → 当前播放位置不跳
                isStale = false
                let ids = Set(playable.map(\.id))
                items = playable + items.filter { !ids.contains($0.id) }
                fresh = playable
            } else {
                let seen = Set(items.map(\.id))
                fresh = playable.filter { !seen.contains($0.id) }
                items.append(contentsOf: fresh)
            }
            if from == "0" { onFirstPage?(playable); DDPerf.mark("pagedList.firstNetworkPage") }
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != from
            cursor = r.cursor
            error = nil
            return fresh
        } catch is CancellationError {
            return []
        } catch {
            guard request == generation, !Task.isCancelled else { return [] }
            self.error = error.localizedDescription
            if isStale {
                // 确认未登录：快照是别人的/过期的，必须清掉；网络抖动则继续放快照，下次再校正
                if error.localizedDescription.contains("未登录") {
                    isStale = false
                    items = []
                    onFirstPage?([])
                    hasMore = false
                }
                return []
            }
            hasMore = false
            return []
        }
    }
}

struct DYListTarget: Identifiable {
    let id = UUID()
    let title: String
    let items: [DYAweme]
    let start: Int
    let model: DYPagedModel?
}

// MARK: - 搜索

struct DYSearchScreen: View {
    let bridge: DouyinBridge
    let onAuthor: (DYAweme) -> Void
    var initialQuery: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var kw = ""
    @State private var sugs: [DYSug] = []
    @State private var hot: [DYHot] = []
    @State private var model: DYPagedModel?
    @State private var open: DYListTarget?
    @State private var sugTask: Task<Void, Never>?
    @State private var lastRun = ""
    @FocusState private var focused: Bool
    @AppStorage("douyin_search_history_v1") private var historyRaw = ""

    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white)
                }
                .accessibilityIdentifier("douyin.search.back")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("", text: $kw, prompt: Text("搜索视频").foregroundStyle(.white.opacity(0.45)))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { run(kw) }
                        .accessibilityIdentifier("douyin.search.field")
                    if !kw.isEmpty {
                        Button { kw = ""; model = nil; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Capsule().fill(.white.opacity(0.12)))
                Button("搜索") { run(kw) }.foregroundStyle(.white).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if let model {
                DYSearchResults(model: model, onOpen: { i in
                    open = DYListTarget(title: "搜索：\(kw)", items: model.items, start: i, model: model)
                })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !sugs.isEmpty && !kw.isEmpty {
                            ForEach(sugs) { s in
                                Button { kw = s.word; run(s.word) } label: {
                                    HStack {
                                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                                        Text(s.word).foregroundStyle(.white)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } else if !history.isEmpty {
                            HStack {
                                Text("搜索历史").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Spacer()
                                Button("清空") { historyRaw = "" }.font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(16)
                            FlowTags(tags: history) { w in kw = w; run(w) }
                                .padding(.horizontal, 16)
                        }
                        if !hot.isEmpty && (sugs.isEmpty || kw.isEmpty) {
                            hotSection
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background(DYSwipeDismiss(enabled: open == nil) {
            focused = false
            dismiss()
        })
        .task { if hot.isEmpty { hot = await bridge.hotSearch() } }
        .onAppear {
            if !initialQuery.isEmpty {
                if lastRun.isEmpty { run(initialQuery) }
            } else { focused = true }
            #if DEBUG
            if let w = ProcessInfo.processInfo.environment["DOUDUO_SEARCHKW"] { run(w) }
            else if ProcessInfo.processInfo.environment["DOUDUO_SEARCHCAT"] == "1" { run("猫") }
            #endif
        }
        .onChange(of: kw) { _, v in
            sugTask?.cancel()
            guard !v.trimmingCharacters(in: .whitespaces).isEmpty else { sugs = []; return }
            if v == lastRun { return }
            if model != nil { model = nil }
            sugTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let r = await bridge.suggest(v)
                if !Task.isCancelled { sugs = r }
            }
        }
        .fullScreenCover(item: $open) { t in
            DYListPlayer(bridge: bridge, title: t.title, items: t.items, start: t.start,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: onAuthor)
        }
    }

    /// 抖音热搜：宽屏自动两列
    private var hotSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("抖音热搜").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.top, 20)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 24, alignment: .leading)],
                      alignment: .leading, spacing: 0) {
                ForEach(Array(hot.enumerated()), id: \.offset) { _, h in
                    Button { kw = h.word; run(h.word) } label: { hotRow(h) }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func hotRow(_ h: DYHot) -> some View {
        let accent = Color(red: 1, green: 0.42, blue: 0.32)
        return HStack(spacing: 10) {
            Group {
                if let p = h.pos { Text("\(p)").foregroundStyle(p <= 3 ? accent : .white.opacity(0.45)) }
                else { Image(systemName: "pin.fill").foregroundStyle(accent) }
            }
            .font(.subheadline.weight(.bold).monospacedDigit())
            .frame(width: 26)
            Text(h.word).font(.subheadline).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 6)
            if h.hot > 0 { Text(DYFormat.count(h.hot)).font(.caption).foregroundStyle(.white.opacity(0.4)) }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func run(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        focused = false
        sugs = []
        lastRun = w
        kw = w
        var h = history.filter { $0 != w }
        h.insert(w, at: 0)
        historyRaw = h.prefix(15).joined(separator: "\n")
        let m = DYPagedModel { [bridge] cur in try await bridge.search(w, offset: cur) }
        model = m
        Task { await m.loadMore() }
    }
}

private struct DYSearchResults: View {
    @ObservedObject var model: DYPagedModel
    let onOpen: (Int) -> Void
    var body: some View {
        DYGrid(items: model.items, hasMore: model.hasMore, loading: model.loading, error: model.error,
               onLoadMore: { Task { await model.loadMore() } }, onOpen: onOpen)
    }
}

/// 标签流式排版（搜索历史）
struct FlowTags: View {
    let tags: [String]
    let onTap: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { t in
                Button { onTap(t) } label: {
                    Text(t).font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}

// MARK: - 我的

struct DYMineScreen: View {
    let bridge: DouyinBridge
    let onLogin: () -> Void
    let onAuthor: (DYAweme) -> Void
    var onMessages: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var user: DYUser?
    @State private var userErr: String?
    @State private var kind: DYListKind = .post
    @State private var models: [DYListKind: DYPagedModel] = [:]
    @State private var open: DYListTarget?
    @State private var relations: DYRelationsTarget?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(user?.name ?? "我的")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Duo：返回 + 操作走系统 toolbar，系统放进右侧竖向侧栏（每项都有标题+符号）
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回", systemImage: "chevron.backward") { dismiss() }
                            .accessibilityIdentifier("douyin.mine.back")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("网页版 / 登录", systemImage: "safari") { onLogin() }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .modifier(DYEdgeSwipeBack(action: { dismiss() }))
    }

    private var content: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.bottom, 12)

            HStack(spacing: 22) {
                ForEach(DYListKind.allCases) { k in
                    Button { kind = k } label: {
                        VStack(spacing: 5) {
                            Text(k.title).font(.subheadline.weight(kind == k ? .bold : .medium))
                                .foregroundStyle(.white.opacity(kind == k ? 1 : 0.6))
                            Capsule().fill(.white).frame(width: 18, height: 2.5).opacity(kind == k ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.mine.\(k.rawValue)")
                }
            }
            .padding(.bottom, 6)

            if let m = models[kind] {
                DYMineList(model: m, showsPlayCount: kind == .post) { i in
                    open = DYListTarget(title: kind.title, items: m.items, start: i, model: m)
                }
                .id(kind)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            do { user = try await bridge.selfProfile() } catch { userErr = error.localizedDescription }
        }
        .onAppear { ensure(kind) }
        .onChange(of: kind) { _, k in ensure(k) }
        .fullScreenCover(item: $open) { t in
            DYListPlayer(bridge: bridge, title: t.title, items: t.items, start: t.start,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: onAuthor)
        }
        .fullScreenCover(item: $relations) { t in
            DYRelationsScreen(bridge: bridge, kind: t.kind, uid: t.user.uid, secUid: t.user.secUid)
        }
    }

    private func ensure(_ k: DYListKind) {
        guard models[k] == nil else { return }
        let m = DYPagedModel { [bridge] cur in try await bridge.myList(k, cursor: cur) }
        models[k] = m
        Task { await m.loadMore() }
    }

    @ViewBuilder
    private var header: some View {
        if let u = user {
            DYUserHeader(user: u,
                         onFollowing: { relations = DYRelationsTarget(kind: .following, user: u) },
                         onFollowers: { relations = DYRelationsTarget(kind: .followers, user: u) })
        } else if let e = userErr {
            VStack(spacing: 10) {
                Text(e.contains("未登录") ? "还没登录抖音" : e).foregroundStyle(.white.opacity(0.8)).font(.subheadline)
                Button("去登录") { onLogin() }.buttonStyle(.borderedProminent).tint(.pink)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        } else {
            ProgressView().tint(.white).frame(height: 80)
        }
    }
}

private struct DYMineList: View {
    @ObservedObject var model: DYPagedModel
    var showsPlayCount = false
    let onOpen: (Int) -> Void
    var body: some View {
        DYGrid(items: model.items, hasMore: model.hasMore, loading: model.loading, error: model.error,
               onLoadMore: { Task { await model.loadMore() } }, onOpen: onOpen, showsPlayCount: showsPlayCount)
    }
}

struct DYUserHeader: View {
    let user: DYUser
    /// 「关注 / 粉丝」数字可点（传了回调才显示为按钮）；不传保持纯展示，作者页不受影响
    var onFollowing: (() -> Void)? = nil
    var onFollowers: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                CachedAsyncImage(url: user.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.white.opacity(0.1) }
                    .frame(width: 72, height: 72).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.name).font(.title3.weight(.bold)).foregroundStyle(.white)
                    if let ip = user.ip, !ip.isEmpty {
                        Text(ip).font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            HStack(spacing: 20) {
                stat(user.likes, "获赞")
                statTap(user.following, "关注", onFollowing, "douyin.header.following")
                statTap(user.followers, "粉丝", onFollowers, "douyin.header.followers")
                stat(user.works, "作品")
            }
            if !user.signature.isEmpty {
                Text(user.signature).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stat(_ n: Int, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(DYFormat.count(n)).font(.subheadline.weight(.bold)).foregroundStyle(.white)
            Text(t).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
    private func statTap(_ n: Int, _ t: String, _ act: (() -> Void)?, _ id: String) -> some View {
        Button { act?() } label: {
            HStack(spacing: 4) {
                Text(DYFormat.count(n)).font(.subheadline.weight(.bold)).foregroundStyle(.white)
                Text(t).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(act == nil)
        .accessibilityIdentifier(id)
    }
}

// MARK: - 作者主页（资料卡 + 原生作品网格；网页版只作兜底）

struct DYAuthorScreen: View {
    let bridge: DouyinBridge
    let author: DYAweme.Author
    let onWeb: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var user: DYUser?
    @State private var err: String?
    @State private var posts: [DYAweme] = []
    @State private var cursor = "0"
    @State private var hasMore = true
    @State private var loading = false
    @State private var postErr: String?
    @State private var followed = false
    @State private var followUID: String?
    @State private var followBusy = false
    @State private var followMsg: String?
    @State private var player: DYAuthorPlay?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                .accessibilityIdentifier("douyin.author.back")
                Spacer()
                followButton
            }
            if let u = user {
                DYUserHeader(user: u)
            } else if let err {
                Text(err).foregroundStyle(.white.opacity(0.7)).font(.footnote)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 72)
            }
            if let s = author.secUid, let u = URL(string: "https://www.douyin.com/user/\(s)") {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onWeb(u) }
                } label: {
                    Text("网页版")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.author.web")
            }
            if let followMsg {
                Text(followMsg).font(.caption2).foregroundStyle(.orange)
            }
            DYGrid(items: posts, hasMore: hasMore, loading: loading, error: postErr, onLoadMore: { requestMore() }, onOpen: { i in
                player = DYAuthorPlay(index: i)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("douyin.author.works")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(Color.black.ignoresSafeArea())
        .fullScreenCover(item: $player) { p in
            DYListPlayer(bridge: bridge, title: author.name.isEmpty ? "作品" : author.name, items: posts, start: p.index,
                         loadMore: { await loadPosts() }, onAuthor: { _ in })
        }
        .task {
            guard let s = author.secUid else { err = "没有作者信息"; hasMore = false; return }
            async let profile: Void = loadProfile(s)
            async let state: Void = loadFollow(s)
            async let videos = loadPosts()
            _ = await (profile, state, videos)
        }
    }

    @ViewBuilder
    private var followButton: some View {
        let uid = followUID ?? author.uid
        Button { Task { await toggleFollow() } } label: {
            Text(followBusy ? "…" : (followed ? "已关注" : "关注"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(followed ? .white : .black)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(followed ? Color.white.opacity(0.16) : Color.white))
        }
        .buttonStyle(.plain)
        .disabled(followBusy || uid == nil || uid?.isEmpty == true)
        .accessibilityIdentifier("douyin.author.follow")
    }

    private func loadProfile(_ sec: String) async {
        do { user = try await bridge.userProfile(sec) } catch { err = error.localizedDescription }
    }

    private func loadFollow(_ sec: String) async {
        if let s = try? await bridge.followState(sec: sec) {
            followed = s.followed
            if let uid = s.uid, !uid.isEmpty { followUID = uid }
            DYFollowStore.shared.set(s.followed, uid: s.uid ?? author.uid, sec: sec)
        }
    }

    private func requestMore() {
        guard !loading, hasMore, author.secUid != nil else { return }
        loading = true
        Task { _ = await loadPosts(alreadyLocked: true) }
    }

    private func loadPosts(alreadyLocked: Bool = false) async -> [DYAweme] {
        guard hasMore, let sec = author.secUid else { return [] }
        if !alreadyLocked {
            guard !loading else { return [] }
            loading = true
        }
        defer { loading = false }
        do {
            let r = try await bridge.userPosts(sec, cursor: cursor)
            let seen = Set(posts.map(\.id))
            let fresh = r.items.filter { !seen.contains($0.id) }
            posts.append(contentsOf: fresh)
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != cursor
            cursor = r.cursor
            postErr = nil
            DYLiveModel.log("DDPOST sec=\(sec.prefix(8)) n=\(fresh.count) more=\(hasMore)")
            return fresh
        } catch {
            postErr = error.localizedDescription
            hasMore = false
            DYLiveModel.log("DDPOST error \(error.localizedDescription)")
            return []
        }
    }

    /// 只在按钮点击时发关注。不要在测试里点。
    private func toggleFollow() async {
        guard let uid = followUID ?? author.uid, !uid.isEmpty, !followBusy else { return }
        followBusy = true
        defer { followBusy = false }
        let want = !followed
        do {
            switch try await bridge.followUser(uid, follow: want) {
            case .ok:
                followed = want
                followMsg = nil
                // 推荐流头像上的「+」跟着变（同一份关注状态）
                DYFollowStore.shared.set(want, uid: uid, sec: author.secUid)
            case .notLoggedIn:
                followMsg = "抖音未登录"
            case .failed(let why):
                followMsg = why
            }
        } catch {
            followMsg = error.localizedDescription
        }
    }
}

private struct DYAuthorPlay: Identifiable {
    let id = UUID()
    let index: Int
}

// MARK: - 直播页推荐条策略

/// 直播页顶部「直播中」头像排的展开/收起规则。
/// 官方行为：进入直播页展开提醒，用户上滑换直播间时收成「N 个直播」胶囊，点胶囊再展开。
enum DYFollowLiveStripPolicy {
    /// 首屏落位（old == nil）或仍在同一条时都不收起；只有真正从一条换到另一条才算上滑。
    static func shouldCollapse(old: String?, new: String?, expanded: Bool) -> Bool {
        guard expanded, let old, let new else { return false }
        return old != new
    }

    /// 展开态的胶囊文案。
    static func pillTitle(count: Int) -> String { "\(count) 个直播" }
}

/// 直播页顶部的「关注主播正在直播」：进入展开一排头像，上滑换直播间后收成「N 个直播」胶囊。
/// 数据来自 bridge.fetchFollowLive（直播页 model.followLive 同一来源），点头像直接进房。
struct DYFollowLiveStrip: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let rooms: [DYLiveRoom]
    let expanded: Bool
    let onOpen: (DYLiveRoom) -> Void
    let onExpand: () -> Void

    private var foreground: Color { theme.media.onMedia.color(for: scheme) }

    var body: some View {
        if expanded { row } else { pill }
    }

    private var row: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(rooms) { r in
                    Button { onOpen(r) } label: {
                        VStack(spacing: 4) {
                            CachedAsyncImage(url: r.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                                placeholder: { theme.media.chromeFill.color(for: scheme) }
                                .frame(width: 54, height: 54).clipShape(Circle())
                                .padding(2)
                                .overlay(Circle().stroke(theme.status.danger.color(for: scheme), lineWidth: 2.5))
                                .overlay(alignment: .bottom) {
                                    Text("直播中").font(.caption2.weight(.bold)).foregroundStyle(foreground)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                                        .offset(y: 6)
                                }
                            Text(r.owner).font(.caption2).foregroundStyle(foreground).lineLimit(1).frame(width: 68)
                                .padding(.top, 4)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("live.strip.\(r.id)")
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .themeShadow(.mediaLabel)
        .accessibilityIdentifier("live.follow.strip")
    }

    private var pill: some View {
        Button {
            withAnimation(.easeOut(duration: 0.24)) { onExpand() }
        } label: {
            HStack(spacing: 4) {
                Text(DYFollowLiveStripPolicy.pillTitle(count: rooms.count)).font(.caption.weight(.bold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(theme.media.chromeFill.color(for: scheme)))
            .overlay(Capsule().stroke(foreground.opacity(0.22), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("live.follow.pill")
        .themeShadow(.mediaLabel)
    }
}

// MARK: - 关注流

struct DYFollowFeed: View {
    let bridge: DouyinBridge
    let insets: EdgeInsets
    @ObservedObject var model: DYPagedModelHolder
    let active: Bool
    @Binding var showComments: Bool
    let onAuthor: (DYAweme) -> Void
    let onLogin: () -> Void
    let onToast: (String) -> Void
    var onLive: (DYLiveRoom) -> Void = { _ in }
    /// 关注流手指往左滑回推荐（推荐在关注右边）
    var onSwipeToRecommend: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var currentID: String?
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var liked: Set<String> = []
    @State private var collected: Set<String> = []

    var body: some View {
        let m = model.model(bridge)
        GeometryReader { geo in
            let layout = DYCommentLayout(size: geo.size, fold: DYDuoMetrics.foldIsActive(geo), showComments: showComments)
            ZStack(alignment: .topLeading) {
            // 外屏：评论面板从底部升起，视频缩到上方继续播
            DYCommentDock(panelID: currentID, enabled: layout.docked && !m.items.isEmpty, isOpen: $showComments) {
            Group {
            if m.items.isEmpty {
                VStack(spacing: 12) {
                    if let e = m.error {
                        Text(e).font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                        HStack {
                            Button("重试") { m.reset(); Task { await m.loadMore(); currentID = m.items.first?.id } }
                                .buttonStyle(.borderedProminent)
                            Button("登录") { onLogin() }.buttonStyle(.bordered)
                        }
                    } else if m.loading || m.hasMore {
                        ProgressView().tint(.white)
                        Text("加载关注…").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text("关注的人还没有新作品").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(m.items) { item in
                            DYVideoPage(item: item, isCurrent: active && item.id == currentID, insets: insets,
                                        resume: resume[item.id], liked: liked.contains(item.id) || item.userDigged == 1,
                                        collected: collected.contains(item.id) || item.isCollect == 1,
                                        onLike: { like(item.id, force: nil) }, onCollect: { collect(item.id) },
                                        onDoubleTap: { like(item.id, force: true) }, onComments: { withAnimation(.snappy) { showComments.toggle() } },
                                        onSearch: {},
                                        onAuthor: { onAuthor(item) }, onSavePosition: { resume[item.id] = $0 },
                                        preloader: preloader, bridge: bridge, onToast: onToast,
                                        onSwipeLeftOverride: onSwipeToRecommend,
                                        onSwipeRightOverride: showComments ? { withAnimation(.snappy) { showComments = false } } : nil)
                                .frame(width: layout.videoWidth, height: layout.videoHeight)
                                .clipped()
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID, anchor: .top)
                .scrollIndicators(.hidden)
            }
            }
            .frame(width: layout.videoWidth, height: layout.videoHeight)
            .clipped()
            } panel: {
                if let cur = m.items.first(where: { $0.id == currentID }) {
                    DYCommentPanel(bridge: bridge, aweme: cur, onClose: { withAnimation(.snappy) { showComments = false } })
                        .id(cur.id)
                }
            }
            .frame(width: layout.videoWidth, height: layout.videoHeight, alignment: .topLeading)
            if layout.showPanel, let cur = m.items.first(where: { $0.id == currentID }) {
                DYCommentPanel(bridge: bridge, aweme: cur,
                               onClose: layout.fold ? nil : { withAnimation(.snappy) { showComments = false } })
                    .frame(width: layout.sideBySide ? layout.panelWidth : geo.size.width,
                           height: layout.tableFold ? layout.panelHeight : geo.size.height)
                    .offset(x: layout.sideBySide ? layout.videoWidth : 0,
                            y: layout.tableFold ? layout.videoHeight : 0)
                    .id(cur.id)
            }
            }
            .animation(layout.docked ? nil : .snappy, value: showComments)
            .animation(.snappy, value: layout.fold)
        }
        .task {
            if currentID == nil { currentID = m.items.first?.id }
            if m.items.isEmpty || m.isStale { await m.loadMore() }
            if currentID == nil { currentID = m.items.first?.id }
        }
        .onChange(of: m.items.first?.id) { _, first in
            if currentID == nil { currentID = first }
        }
        .onChange(of: currentID) { old, new in
            if new == nil, let old, m.items.contains(where: { $0.id == old }) { currentID = old; return }
            guard let i = m.items.firstIndex(where: { $0.id == new }) else { return }
            preloader.update(m.items, current: i)
            if i >= m.items.count - 4 { Task { await m.loadMore() } }
        }
        .onChange(of: active) { _, a in if !a { preloader.clear() } }
        .onDisappear { preloader.clear() }
    }

    private func like(_ id: String, force: Bool?) {
        let has = liked.contains(id), want = force ?? !has
        guard want != has else { return }
        if want { liked.insert(id) } else { liked.remove(id) }
        Task {
            let r = try? await bridge.digg(id, like: want)
            if case .ok = r { return }
            if want { liked.remove(id) } else { liked.insert(id) }
            onToast("点赞失败")
        }
    }

    private func collect(_ id: String) {
        let want = !collected.contains(id)
        if want { collected.insert(id) } else { collected.remove(id) }
        Task {
            let r = try? await bridge.favorite(id, add: want)
            if case .ok = r { onToast(want ? "已收藏" : "已取消收藏"); return }
            if want { collected.remove(id) } else { collected.insert(id) }
            onToast("收藏失败")
        }
    }
}

/// 关注流首页快照：下次打开先显示它（0 等待），网络首页回来再合并校正。和推荐流会话一样存 Application Support。
enum DYFollowSnapshot {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("follow-snapshot.json")
    }
    static func load() -> [DYAweme] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DYAweme].self, from: d)) ?? []
    }
    static func save(_ items: [DYAweme]) {
        guard !items.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        let page = Array(items.prefix(20))
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(page) { try? d.write(to: url, options: .atomic) }
        }
    }
}

/// DYPagedModel 需要 bridge 才能建，StateObject 包一层延迟创建
@MainActor
final class DYPagedModelHolder: ObservableObject {
    private var m: DYPagedModel?
    private var sub: Any?
    func model(_ b: DouyinBridge) -> DYPagedModel {
        if let m { return m }
        let n = DYPagedModel { cur in try await b.followFeed(cursor: cur) }
        n.seed(DYFollowSnapshot.load())
        if !n.items.isEmpty { DDPerf.mark("follow.visible(snapshot)") }
        n.onFirstPage = { DYFollowSnapshot.save($0) }
        sub = n.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        m = n
        return n
    }
}


#if DEBUG
/// 真机自检：用 App 里真实的接口函数逐个跑一遍（登录态），结果写 ddlog，不用点界面
@MainActor enum DDSelfTest {
    static func run(_ b: DouyinBridge) async {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        func log(_ s: String) { DYLiveModel.log("DDSELF " + s) }
        await b.debugExportCookies()
        do { let u = try await b.selfProfile(); log("self ok name=\(u.name) likes=\(u.likes) works=\(u.works) sec=\(u.secUid.prefix(10))") }
        catch { log("self FAIL \(error.localizedDescription)") }
        for k in DYListKind.allCases {
            do {
                let r = try await b.myList(k, cursor: "0")
                let playable = r.items.filter { $0.play != nil || !$0.images.isEmpty }.count
                log("\(k.title) ok n=\(r.items.count) playable=\(playable) more=\(r.hasMore) cur=\(r.cursor) first=\(r.items.first?.desc.prefix(16) ?? "-")")
                if r.hasMore {
                    let r2 = try await b.myList(k, cursor: r.cursor)
                    log("\(k.title) page2 n=\(r2.items.count) dup=\(Set(r.items.map(\.id)).intersection(r2.items.map(\.id)).count)")
                }
            } catch { log("\(k.title) FAIL \(error.localizedDescription)") }
        }
        do { let r = try await b.followFeed(cursor: "0"); log("关注 ok n=\(r.items.count) more=\(r.hasMore) first=\(r.items.first?.author.name ?? "-")") }
        catch { log("关注 FAIL \(error.localizedDescription)") }
        do {
            let r = try await b.search("猫", offset: "0")
            log("搜索 ok n=\(r.items.count) more=\(r.hasMore) cur=\(r.cursor) first=\(r.items.first?.desc.prefix(16) ?? "-")")
            if r.hasMore { let r2 = try await b.search("猫", offset: r.cursor); log("搜索 page2 n=\(r2.items.count)") }
        } catch { log("搜索 FAIL \(error.localizedDescription)") }
        let sug = await b.suggest("猫"); log("联想 n=\(sug.count) first=\(sug.first?.word ?? "-")")
        log("done")
    }
}
#endif
