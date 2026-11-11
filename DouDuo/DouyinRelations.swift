// 关注 / 粉丝列表：网页接口 following/list、follower/list（要 uid + sec_uid，uid 从 profile/self 的 user.uid 取）。
// 「我的」页头部的关注/粉丝数字点进来 → 本列表页（头像+昵称+签名，下滑翻页），点人 → 现有 DYAuthorScreen。
import SwiftUI

// MARK: - 数据

enum DYRelationKind: String {
    case following, followers
    var title: String { self == .following ? "关注" : "粉丝" }
}

struct DYRelationUser: Identifiable, Decodable, Equatable {
    let uid: String
    let secUid: String
    let name: String
    let avatar: String?
    let signature: String
    var id: String { uid.isEmpty ? secUid : uid }
}

private struct DYRelationPage: Decodable {
    let status: Int
    let items: [DYRelationUser]
    let hasMore: Bool
    let code: Int?
    let msg: String?
}

/// 「我的」页点关注/粉丝数字后打开的目标
struct DYRelationsTarget: Identifiable {
    let id = UUID()
    let kind: DYRelationKind
    let user: DYUser
}

// MARK: - 接口

extension DouyinBridge {
    /// 关注 / 粉丝列表（offset 翻页，每页 20）
    func relationList(_ kind: DYRelationKind, uid: String, secUid: String, offset: Int) async throws -> (items: [DYRelationUser], cursor: Int, hasMore: Bool) {
        let js = kind == .following ? Self.relationFollowingJS : Self.relationFollowerJS
        let d = try await cachedRead(js, args: ["uid": uid, "sec": secUid, "offset": String(offset)])
        let p = try JSONDecoder().decode(DYRelationPage.self, from: d)
        if p.code == 8 || (p.msg ?? "").contains("未登录") { throw DYError.bad("抖音未登录：右上「我的」→ 登录") }
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        return (p.items, offset + 20, p.hasMore)
    }

    // MARK: JS（requestJS 里有 req / base / parse / first / q）

    private static let relationMap = #"""
    const rmap = x => x ? ({ uid: String(x.uid || ''), secUid: x.sec_uid || '', name: x.nickname || '',
      avatar: first(x.avatar_larger) || first(x.avatar_thumb), signature: x.signature || '' }) : null;
    """#

    static let relationFollowingJS = relationMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/following/list/?' + q({ user_id: uid, sec_user_id: sec, offset: offset, min_time: '0', max_time: '0', count: '20', source_type: '2', gps_access: '0', address_book_access: '0', is_top: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)),
      items: (d.followings || []).map(rmap).filter(Boolean), hasMore: !!d.has_more });
    """#

    static let relationFollowerJS = relationMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/follower/list/?' + q({ user_id: uid, sec_user_id: sec, offset: offset, min_time: '0', max_time: '0', count: '20', source_type: '2', gps_access: '0', address_book_access: '0' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)),
      items: (d.followers || []).map(rmap).filter(Boolean), hasMore: !!d.has_more });
    """#
}

// MARK: - 分页模型（offset 翻页，和 DYPagedModel 的 cursor 版分开）

@MainActor
final class DYRelationModel: ObservableObject {
    @Published var items: [DYRelationUser] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    private var offset = 0
    private let fetch: (Int) async throws -> (items: [DYRelationUser], cursor: Int, hasMore: Bool)

    init(fetch: @escaping (Int) async throws -> (items: [DYRelationUser], cursor: Int, hasMore: Bool)) {
        self.fetch = fetch
    }

    func reset() { items = []; offset = 0; hasMore = true; error = nil }

    @discardableResult
    func loadMore() async -> [DYRelationUser] {
        guard !loading, hasMore else { return [] }
        loading = true
        defer { loading = false }
        do {
            let r = try await fetch(offset)
            let seen = Set(items.map(\.id))
            let fresh = r.items.filter { !seen.contains($0.id) }
            items.append(contentsOf: fresh)
            hasMore = r.hasMore && !r.items.isEmpty
            offset = r.cursor
            error = nil
            return fresh
        } catch {
            self.error = error.localizedDescription
            hasMore = false
            return []
        }
    }
}

// MARK: - 列表页

struct DYRelationsScreen: View {
    let bridge: DouyinBridge
    let kind: DYRelationKind
    let uid: String
    let secUid: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DYRelationModel
    @State private var open: DYRelationUser?

    init(bridge: DouyinBridge, kind: DYRelationKind, uid: String, secUid: String) {
        self.bridge = bridge; self.kind = kind; self.uid = uid; self.secUid = secUid
        _model = StateObject(wrappedValue: DYRelationModel { off in
            try await bridge.relationList(kind, uid: uid, secUid: secUid, offset: off)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                }
                .accessibilityIdentifier("douyin.relations.back")
                Text("\(kind.title)（\(model.items.count)）").font(.headline).foregroundStyle(.white).shadow(radius: 3)
                Spacer()
            }
            .padding(.leading, 22).padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { u in
                        Button { open = u } label: { row(u) }
                            .buttonStyle(.plain)
                            .onAppear {
                                // 滑到最后一行就拉下一页
                                if u.id == model.items.last?.id { Task { await model.loadMore() } }
                            }
                    }
                    if model.loading {
                        ProgressView().tint(.white).padding(.vertical, 20)
                    } else if let e = model.error {
                        Text(e).font(.footnote).foregroundStyle(.white.opacity(0.7)).padding(.vertical, 20)
                    } else if !model.hasMore, !model.items.isEmpty {
                        Text("到底了").font(.caption).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 20)
                    } else if model.items.isEmpty {
                        Text(kind == .following ? "还没有关注任何人" : "还没有粉丝").font(.footnote)
                            .foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task { await model.loadMore() }
        .fullScreenCover(item: $open) { u in
            DYAuthorScreen(bridge: bridge,
                           author: DYAweme.Author(name: u.name, avatar: u.avatar,
                                                  secUid: u.secUid.isEmpty ? nil : u.secUid,
                                                  uid: u.uid.isEmpty ? nil : u.uid),
                           onWeb: { _ in })
        }
    }

    private func row(_ u: DYRelationUser) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: u.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                placeholder: { Color.white.opacity(0.1) }
                .frame(width: 48, height: 48).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(u.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if !u.signature.isEmpty {
                    Text(u.signature).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityIdentifier("douyin.relations.row")
    }
}
