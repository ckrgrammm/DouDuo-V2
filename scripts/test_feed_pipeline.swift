// 推荐流管线（DouDuo/DouyinFeedPipeline.swift）逻辑测试：不依赖 App / 网络，假接口模拟并发、乱序、重复、超时。
// 运行：scripts/test_feed_pipeline.sh
import Foundation

struct V: DYFeedItem, Equatable {
    let id: String
    var feedIsPortrait: Bool = true
    var feedIsPlayable: Bool = true
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

var failures = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { print("  ✓ \(what)") } else { failures += 1; print("  ✗ \(what)  (line \(line))") }
}

/// 假推荐接口：每页 n 条，id 由 page 决定；delay(seq) 控制乱序
struct FakeAPI {
    let tickets = Box<[DYFeedTicket]>([])
    let inFlight = Box(0)
    let maxSeen = Box(0)
    var perPage = 5
    var delay: @Sendable (Int) -> Double = { _ in 0.02 }
    var ids: @Sendable (Int, Int) -> String = { seq, i in "v\(seq)-\(i)" }
    var fail: @Sendable (Int) -> Bool = { _ in false }

    func make() -> DYFeedCoordinator<V>.Fetch {
        let tickets = tickets, inFlight = inFlight, maxSeen = maxSeen
        let perPage = perPage, delay = delay, ids = ids, fail = fail
        return { t in
            tickets.with { $0.append(t) }
            let n = inFlight.with { $0 += 1; return $0 }
            maxSeen.with { $0 = max($0, n) }
            defer { inFlight.with { $0 -= 1 } }
            try await Task.sleep(nanoseconds: UInt64(delay(t.seq) * 1_000_000_000))
            if fail(t.seq) { throw NSError(domain: "fake", code: 1) }
            return DYFeedFetchedPage(items: (0..<perPage).map { V(id: ids(t.seq, $0)) }, hasMore: true)
        }
    }
}

func cfg(_ f: (inout DYFeedPipelineConfig) -> Void = { _ in }) -> DYFeedPipelineConfig {
    var c = DYFeedPipelineConfig()
    c.requestTimeout = 1; c.backoffBase = 0.05; c.backoffCap = 0.1; c.emptyPause = 0.2
    f(&c); return c
}

/// 让管线跑到停（没有在途、不再发）
func drain(_ c: DYFeedCoordinator<V>, ahead: Int = 0, urgent: Bool = true) async {
    await c.demand(ahead: ahead, urgent: urgent)
    var guardN = 0
    while await c.awaitNextMerge(), guardN < 200 { guardN += 1 }
}

func run() async {
    print("1. 序号唯一、refresh_index 由 coordinator 分配，并发不超过 2")
    do {
        let api = FakeAPI(delay: { _ in Double.random(in: 0.01...0.06) })
        let c = DYFeedCoordinator<V>(config: cfg())
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        let ts = api.tickets.with { $0 }
        check(Set(ts.map(\.seq)).count == ts.count, "请求序号唯一（\(ts.count) 个请求）")
        check(Set(ts.map(\.refreshIndex)).count == ts.count, "refresh_index 唯一")
        check(ts.first?.pull == "0" && ts.dropFirst().allSatisfy { $0.pull == "2" }, "只有第一个请求 pull_type=0")
        check(api.maxSeen.with { $0 } <= 2, "同时在途 ≤ 2（实际 \(api.maxSeen.with { $0 })）")
        let pool = await c.poolCount
        check(pool >= 20, "补到目标 20 条（池子 \(pool)）")
        check(ts.count <= 6, "没有超量请求（\(ts.count) 个）")
    }

    print("2. 乱序回来按序号合并、保留服务端顺序")
    do {
        // seq1 最慢、seq2 最快
        let api = FakeAPI(perPage: 3, delay: { seq in seq == 1 ? 0.15 : 0.01 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.target = 6; $0.lowWater = 6 })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        let ids = await c.peek(100).map(\.id)
        check(Array(ids.prefix(6)) == ["v1-0", "v1-1", "v1-2", "v2-0", "v2-1", "v2-2"], "先发的排在前面：\(ids.prefix(6))")
    }

    print("3. 跨页去重；全是重复时不会无限请求")
    do {
        let api = FakeAPI(perPage: 4, ids: { _, i in "same-\(i)" })
        let c = DYFeedCoordinator<V>(config: cfg())
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        let snap = await c.snapshot()
        check(await c.poolCount == 4, "只收 4 条唯一的")
        check(snap.requests <= 6, "重复内容触发暂停，请求数 \(snap.requests) 有上限")
        check(snap.duplicates == snap.returned - 4, "重复数统计正确（\(snap.duplicates)/\(snap.returned)）")
    }

    print("4. serialCursor 时严格串行")
    do {
        let api = FakeAPI(delay: { _ in 0.02 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.workers = 4; $0.maxConcurrent = 4; $0.serialCursor = true })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        check(api.maxSeen.with { $0 } == 1, "同时在途 = 1")
    }

    print("5. 4 Worker 并发 4 时不超过 4，且仍停在目标附近")
    do {
        let api = FakeAPI(delay: { _ in 0.03 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.workers = 4; $0.maxConcurrent = 4 })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        let n = api.maxSeen.with { $0 }
        check(n <= 4 && n >= 2, "同时在途 \(n)")
        check(await c.poolCount < 40, "没有过量囤积（\(await c.poolCount)）")
    }

    print("6. 高于低水位不补，低于 8 才补")
    do {
        let api = FakeAPI()
        let c = DYFeedCoordinator<V>(config: cfg())
        await c.attach(fetch: api.make(), onSupply: {})
        await c.demand(ahead: 10)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(api.tickets.with { $0.count } == 0, "剩 10 条不发请求")
        await c.demand(ahead: 7)
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(api.tickets.with { $0.count } > 0, "剩 7 条开始补充")
    }

    print("7. 刷新作废在途请求，迟到结果丢弃")
    do {
        let api = FakeAPI(delay: { seq in seq <= 2 ? 0.2 : 0.01 })
        let c = DYFeedCoordinator<V>(config: cfg())
        await c.attach(fetch: api.make(), onSupply: {})
        await c.demand(ahead: 0, urgent: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        _ = await c.beginRefresh()
        await drain(c)
        let ids = await c.peek(200).map(\.id)
        check(!ids.contains { $0.hasPrefix("v1-") || $0.hasPrefix("v2-") }, "旧请求的结果没进池子")
        check(api.tickets.with { $0.map(\.seq) }.first(where: { $0 > 2 }) == 3, "刷新后序号继续往上（不回退）")
        check(await c.snapshot().stale == 2, "记 2 个作废")
    }

    print("8. 超时不卡住后面的合并")
    do {
        let api = FakeAPI(delay: { seq in seq == 1 ? 5 : 0.01 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.requestTimeout = 0.2; $0.target = 8 })
        await c.attach(fetch: api.make(), onSupply: {})
        let t0 = Date()
        await drain(c)
        let ids = await c.peek(100).map(\.id)
        check(ids.first?.hasPrefix("v2-") == true && Date().timeIntervalSince(t0) < 2, "seq1 超时后 seq2 照常合并（\(String(format: "%.2f", Date().timeIntervalSince(t0)))s）")
        check(await c.snapshot().timedOut == 1, "记 1 次超时")
    }

    print("9. 接口一直失败：退避、不无限重试")
    do {
        let api = FakeAPI(fail: { _ in true })
        let c = DYFeedCoordinator<V>(config: cfg())
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        let n = api.tickets.with { $0.count }
        check(n <= 4, "失败后进入退避，请求 \(n) 次就停下等")
        check(await c.lastError != nil, "有错误信息给界面")
    }

    print("10. 比例混排：90% 竖屏时缺横屏用竖屏补位，严格模式缺货就停")
    do {
        var p = DYSharedVideoPool<V>(cap: 80)
        p.ratio = 0.3   // 横屏优先
        _ = p.admit((0..<5).map { V(id: "p\($0)", feedIsPortrait: true) })
        check(p.take(3, substitute: false).isEmpty, "横屏优先、池里只有竖屏：严格模式不取")
        check(p.take(3, substitute: true).count == 3, "补位模式照样取")
        _ = p.admit([V(id: "p0")])
        check(p.count == 2, "已经见过的 id 不再收")
        _ = p.admit([V(id: "x", feedIsPlayable: false)])
        check(p.count == 2, "不能播的不收")
    }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
