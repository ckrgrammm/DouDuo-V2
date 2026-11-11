// 消息 / 作者作品 / 关注 / 评论点赞。全部走签名页 requestJS 的 req()/base/q()。
// 登录看 status_code（8 = 未登录），不读 cookie。写接口只在用户点按钮时发出，日志打 DDSEND。
import Foundation

struct DYNotice: Identifiable, Codable, Equatable {
    let id: String
    let type: Int
    let time: Double
    let name: String
    let avatar: String?
    let action: String
    let detail: String
    let cover: String?
    let awemeID: String?
    let author: DYAweme.Author?
    var hasRead: Bool
}

struct DYNoticePage: Decodable {
    let status: Int
    let code: Int?
    let items: [DYNotice]
    let maxTime: Int
    let hasMore: Bool
    let msg: String?
}

struct DYNoticeCount: Decodable {
    let group: Int
    let count: Int
}

private struct DYNoticeCountPage: Decodable {
    let status: Int
    let code: Int?
    let groups: [DYNoticeCount]
    let msg: String?
}

private struct DYMoreList: Decodable {
    let status: Int
    let code: Int?
    let msg: String?
    let items: [DYAweme]
    let cursor: String
    let hasMore: Bool
}

private struct DYFollowRead: Decodable {
    let status: Int
    let code: Int?
    let follow: Int
    let uid: String?
    let msg: String?
}

private struct DYFollowWrite: Decodable {
    let status: Int
    let statusCode: Int?
    let followStatus: Int?
    let msg: String?
}

private struct DYDetailPage: Decodable {
    let status: Int
    let code: Int?
    let item: DYAweme?
    let msg: String?
}

extension DouyinBridge {
    func noticeCounts() async throws -> [DYNoticeCount] {
        let d = try await call(Self.noticeCountJS, args: [:], attempts: 1)
        let p = try JSONDecoder().decode(DYNoticeCountPage.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return p.groups
    }

    func notices(group: Int, maxTime: Int, markRead: Bool = false, minTime: Int = 0) async throws -> (items: [DYNotice], maxTime: Int, hasMore: Bool) {
        let d = try await call(Self.noticeListJS, args: ["group": String(group), "maxTime": String(maxTime), "markRead": markRead ? "1" : "0", "minTime": String(minTime)], attempts: 1)
        let p = try JSONDecoder().decode(DYNoticePage.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        DYLiveModel.log("DDNOTICE_FETCH group=\(group) markRead=\(markRead) min=\(minTime) n=\(p.items.count)")
        return (p.items, p.maxTime, p.hasMore)
    }

    /// 点消息进视频。GET，可测。
    func awemeDetail(_ id: String) async throws -> DYAweme {
        let d = try await call(Self.detailJS, args: ["id": id], attempts: 1)
        let p = try JSONDecoder().decode(DYDetailPage.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200, let item = p.item, item.play != nil || !item.images.isEmpty else {
            throw DYError.bad(p.msg?.isEmpty == false ? p.msg! : "打不开这条视频")
        }
        return item
    }

    func userPosts(_ sec: String, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        let d = try await cachedRead(Self.authorPostJS, args: ["sec": sec, "cursor": cursor], maxAge: cursor == "0" ? 180 : 30, attempts: 1)
        let p = try JSONDecoder().decode(DYMoreList.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 只读关注状态，给按钮初值。不发关注。
    func followState(sec: String) async throws -> (followed: Bool, uid: String?) {
        let d = try await cachedRead(Self.followReadJS, args: ["sec": sec], attempts: 1)
        let p = try JSONDecoder().decode(DYFollowRead.self, from: d)
        if p.code == 8 { throw DYError.bad("抖音未登录") }
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return (p.follow > 0, p.uid)
    }

    /// 关注 / 取消关注。只在按钮点击时调用，测试不要打这条。
    func followUser(_ uid: String, follow: Bool) async throws -> DYActionResult {
        invalidateReadCache()
        defer { invalidateReadCache() }
        let d = try await call(Self.followWriteJS, args: ["uid": uid, "type": follow ? "1" : "0"], attempts: 1)
        let r = try JSONDecoder().decode(DYFollowWrite.self, from: d)
        DYLiveModel.log("DDSEND follow uid=\(uid) type=\(follow ? 1 : 0) status=\(r.status) code=\(r.statusCode ?? -1) follow=\(r.followStatus ?? -1) msg=\(r.msg ?? "-")")
        return Self.actionResult(status: r.status, code: r.statusCode, msg: r.msg)
    }

    /// 评论赞 / 取消赞。只在按钮点击时调用，测试不要打这条。
    func diggComment(_ cid: String, awemeID: String, like: Bool) async throws -> DYActionResult {
        invalidateReadCache()
        defer { invalidateReadCache() }
        let d = try await call(Self.commentDiggJS, args: ["cid": cid, "id": awemeID, "type": like ? "1" : "0"], attempts: 1)
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        DYLiveModel.log("DDSEND comment-digg cid=\(cid) aweme=\(awemeID) digg_type=\(like ? 1 : 0) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        return Self.actionResult(status: r.status, code: r.statusCode, msg: r.msg)
    }

    private static let noticeCountJS = #"""
    const r = await req('GET', '/aweme/v1/web/notice/count/?' + q({ is_new_notice: '1', need_social_count: '1' }));
    const d = parse(r.t) || {};
    const raw = d.notice_count || d.notice_count_list || [];
    const groups = raw.map(x => ({ group: Number(x.group ?? x.notice_group ?? 0), count: Number(x.count || 0) }));
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, groups, msg: d.status_msg || null });
    """#

    private static let noticeListJS = #"""
    const authorOf = u => {
      if (!u || (!u.nickname && !u.sec_uid)) return null;
      return { name: u.nickname || '', avatar: first(u.avatar_thumb) || first(u.avatar_larger), secUid: u.sec_uid || null, uid: u.uid ? String(u.uid) : null };
    };
    const coverOf = a => {
      if (!a) return null;
      const v = a.video || {};
      return first(v.cover) || first(v.origin_cover) || (a.images && a.images[0] && first(a.images[0])) || null;
    };
    const urlOf = o => first(o) || (o && o.url_list && o.url_list[0]) || null;
    const row = n => {
      const t = Number(n.type || 0);
      const gn = n.general_notice || {};
      const inn = n.interactive_notice || {};
      let name = '', avatar = null, action = gn.title || '通知', detail = gn.content || '', cover = null, awemeID = n.aweme_id ? String(n.aweme_id) : null, author = null;
      if (t === 31 && n.comment) {
        const c = n.comment.comment || {};
        const u = c.user || {};
        name = u.nickname || '';
        avatar = first(u.avatar_thumb);
        action = '评论了你';
        detail = c.text || gn.content || '';
        cover = coverOf(n.comment.aweme);
        awemeID = (c.aweme_id && String(c.aweme_id)) || (n.comment.aweme && n.comment.aweme.aweme_id && String(n.comment.aweme.aweme_id)) || awemeID;
        author = authorOf(u);
      } else if (t === 41 && n.digg) {
        const users = n.digg.from_user || [];
        const u = users[0] || {};
        const extra = (n.digg.merge_count || users.length) > 1 ? ' 等' + (n.digg.merge_count || users.length) + '人' : '';
        name = (u.nickname || '') + extra;
        avatar = first(u.avatar_thumb);
        action = '赞了你的作品';
        detail = n.digg.content || '';
        cover = coverOf(n.digg.aweme);
        awemeID = (n.digg.aweme && n.digg.aweme.aweme_id && String(n.digg.aweme.aweme_id)) || awemeID;
        author = authorOf(u);
      } else if (t === 33 && n.follow) {
        const u = n.follow.from_user || {};
        name = u.nickname || '';
        avatar = first(u.avatar_thumb);
        action = '关注了你';
        detail = n.follow.content || '';
        author = authorOf(u);
      } else if (t === 9009) {
        const u = (inn.from_user && inn.from_user[0]) || {};
        name = u.nickname || inn.author || '';
        avatar = first(u.avatar_thumb) || urlOf(inn.avatar_url);
        action = '推荐了你的视频';
        detail = inn.content || inn.desc || gn.content || '';
        cover = urlOf(inn.image_url) || coverOf(inn.aweme);
        awemeID = (inn.aweme && inn.aweme.aweme_id && String(inn.aweme.aweme_id)) || awemeID;
        author = authorOf(u);
      } else {
        name = gn.sender_name || '';
        detail = gn.content || '';
        action = gn.title || '通知';
      }
      if (!cover) cover = urlOf(inn.image_url);
      return {
        id: String(n.nid_str || n.nid || (t + '-' + (n.create_time || 0))),
        type: t, time: n.create_time || 0, name, avatar, action, detail, cover, awemeID, author,
        hasRead: !!(n.has_read || n.read_time)
      };
    };
    const r = await req('GET', '/aweme/v1/web/notice/?' + q({
      is_new_notice: '1', is_mark_read: String(markRead || '0'), count: '10', notice_group: String(group), min_time: String(minTime || 0), max_time: String(maxTime || 0)
    }));
    const d = parse(r.t) || {};
    const items = (d.notice_list_v2 || d.notice_list || []).map(row);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, items, maxTime: d.max_time || 0, hasMore: !!d.has_more, msg: d.status_msg || null });
    """#

    private static let detailJS = #"""
    const r = await req('GET', '/aweme/v1/web/aweme/detail/?' + q({ aweme_id: id }));
    const d = parse(r.t) || {};
    const a = d.aweme_detail || d.aweme || null;
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, item: (a && (a.video || a.images)) ? mapA(a) : null, msg: d.status_msg || null });
    """#

    private static let authorPostJS = #"""
    const r = await req('GET', '/aweme/v1/web/aweme/post/?' + q({
      sec_user_id: sec, max_cursor: cursor, locate_query: 'false', show_live_replay_strategy: '1',
      need_time_list: '1', time_list_query: '0', whale_cut_token: '', cut_version: '1', count: '18'
    }));
    const d = parse(r.t) || {};
    const items = (d.aweme_list || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, items, cursor: String(d.max_cursor ?? 0), hasMore: !!d.has_more });
    """#

    private static let followReadJS = #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/other/?' + q({ sec_user_id: sec, publish_video_strategy_type: '2', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    const u = d.user || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, follow: u.follow_status || 0, uid: u.uid ? String(u.uid) : null, msg: d.status_msg || null });
    """#

    private static let followWriteJS = #"""
    const body = new URLSearchParams({ user_id: uid, type: type }).toString();
    const r = await req('POST', '/aweme/v1/web/commit/follow/user/?' + q({}), body);
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, followStatus: d.follow_status ?? null, msg: d.status_msg || null });
    """#

    private static let commentDiggJS = #"""
    const P = { cid: cid, aweme_id: id, digg_type: type, channel_id: '0', app_name: 'aweme', item_type: '0' };
    const r = await req('POST', '/aweme/v1/web/comment/digg?' + q(P), new URLSearchParams(P).toString());
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)) });
    """#
}
