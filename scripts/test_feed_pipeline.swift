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
    /// 返回空页且 has_more=false（模拟风控 / 登录抖动）
    var empty: @Sendable (Int) -> Bool = { _ in false }

    func make() -> DYFeedCoordinator<V>.Fetch {
        let tickets = tickets, inFlight = inFlight, maxSeen = maxSeen
        let perPage = perPage, delay = delay, ids = ids, fail = fail, empty = empty
        return { t in
            tickets.with { $0.append(t) }
            let n = inFlight.with { $0 += 1; return $0 }
            maxSeen.with { $0 = max($0, n) }
            defer { inFlight.with { $0 -= 1 } }
            try await Task.sleep(nanoseconds: UInt64(delay(t.seq) * 1_000_000_000))
            if fail(t.seq) { throw NSError(domain: "fake", code: 1) }
            if empty(t.seq) { return DYFeedFetchedPage(items: [], hasMore: false) }
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

    print("2. 先到先合并：慢请求不卡住已经回来的结果，页内顺序不变")
    do {
        // seq1 最慢、seq2 最快
        let api = FakeAPI(perPage: 3, delay: { seq in seq == 1 ? 0.3 : 0.01 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.target = 6; $0.lowWater = 6 })
        await c.attach(fetch: api.make(), onSupply: {})
        await c.demand(ahead: 0, urgent: true)
        let t0 = Date()
        _ = await c.awaitNextMerge()
        let early = await c.peek(100).map(\.id)
        check(early == ["v2-0", "v2-1", "v2-2"] && Date().timeIntervalSince(t0) < 0.2, "seq2 先回来就先进池子，不等 seq1：\(early)")
        while await c.awaitNextMerge() {}
        let ids = await c.peek(100).map(\.id)
        check(Array(ids.prefix(6)) == ["v2-0", "v2-1", "v2-2", "v1-0", "v1-1", "v1-2"], "seq1 回来后接在后面：\(ids.prefix(6))")
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
        let c = DYFeedCoordinator<V>(config: cfg { $0.maxConcurrent = 4; $0.serialCursor = true })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        check(api.maxSeen.with { $0 } == 1, "同时在途 = 1")
    }

    print("5. 并发 4 时不超过 4，且仍停在目标附近")
    do {
        let api = FakeAPI(delay: { _ in 0.03 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.maxConcurrent = 4 })
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

    print("11. 超时后晚到的结果照收，并撤销那次超时")
    do {
        let api = FakeAPI(perPage: 3, delay: { seq in seq == 1 ? 0.5 : 0.01 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.requestTimeout = 0.2; $0.lateGrace = 2; $0.maxConcurrent = 1; $0.target = 3; $0.lowWater = 3 })
        await c.attach(fetch: api.make(), onSupply: {})
        await c.demand(ahead: 0, urgent: true)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let ids = await c.peek(100).map(\.id)
        let snap = await c.snapshot()
        check(ids.contains("v1-0"), "seq1 超时后 0.5s 回来仍进池子")
        check(snap.timedOut == 0 && snap.failed == 0, "晚到成功后不再算超时（timeout=\(snap.timedOut)）")
        check(await c.lastError == nil, "错误信息已清掉")
    }

    print("12. 宽限期过后才回来的结果丢弃")
    do {
        let api = FakeAPI(perPage: 3, delay: { seq in seq == 1 ? 0.6 : 0.01 }, fail: { $0 > 1 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.requestTimeout = 0.1; $0.lateGrace = 0.1; $0.maxConcurrent = 1 })
        await c.attach(fetch: api.make(), onSupply: {})
        await c.demand(ahead: 0, urgent: true)
        try? await Task.sleep(nanoseconds: 900_000_000)
        check(await c.peek(100).allSatisfy { !$0.id.hasPrefix("v1-") }, "seq1 的结果没进池子")
        check(await c.snapshot().timedOut == 1, "仍记 1 次超时")
    }

    print("13. 一次空页（has_more=false）不会永久停住")
    do {
        let api = FakeAPI(empty: { $0 == 1 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.maxConcurrent = 1 })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        check(await c.poolCount >= 20, "空页之后继续补到目标（池子 \(await c.poolCount)）")
    }

    print("14. 空页暂停期间：后台补充等着，用户在等（urgent）立刻发")
    do {
        let api = FakeAPI(perPage: 4, ids: { seq, i in seq <= 3 ? "same-\(i)" : "v\(seq)-\(i)" })
        let c = DYFeedCoordinator<V>(config: cfg { $0.maxConcurrent = 1; $0.emptyPause = 5; $0.maxEmptyStreak = 2 })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)   // seq1 新、seq2/3 全重复 → 暂停 5s
        let before = api.tickets.with { $0.count }
        await c.demand(ahead: 0)
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(api.tickets.with { $0.count } == before, "非紧急需求在暂停期内不发请求")
        await c.demand(ahead: 0, urgent: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(api.tickets.with { $0.count } > before, "urgent 跳过空页暂停")
    }

    print("15. 失败退避期间 urgent 也不发")
    do {
        let api = FakeAPI(fail: { _ in true })
        let c = DYFeedCoordinator<V>(config: cfg { $0.maxConcurrent = 1; $0.backoffBase = 5; $0.backoffCap = 5 })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)
        let before = api.tickets.with { $0.count }
        await c.demand(ahead: 0, urgent: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(api.tickets.with { $0.count } == before, "退避中不发请求（共 \(before) 次）")
    }

    print("16. 并发的两个请求一起失败只算一轮退避")
    do {
        // 第一轮 seq1/seq2 同时失败。按轮算退避 0.3s；按请求数算会翻到 0.6s。
        let api = FakeAPI(fail: { $0 <= 2 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.backoffBase = 0.3; $0.backoffCap = 10 })
        await c.attach(fetch: api.make(), onSupply: {})
        await c.demand(ahead: 0, urgent: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(api.tickets.with { $0.count } == 2, "退避中只发了第一轮 2 个")
        try? await Task.sleep(nanoseconds: 280_000_000)
        check(api.tickets.with { $0.count } > 2, "0.3s 后就重试（没有翻成 0.6s）")
    }

    print("17. 已约了晚的唤醒，出现更早的时间会改约")
    do {
        // 空页暂停 5s 约了一次唤醒；随后 urgent 请求失败，退避只有 0.1s —— 应该 0.1s 后就重试，而不是等 5s
        let api = FakeAPI(perPage: 4, ids: { seq, i in seq <= 3 ? "same-\(i)" : "v\(seq)-\(i)" }, fail: { $0 == 4 })
        let c = DYFeedCoordinator<V>(config: cfg { $0.maxConcurrent = 1; $0.emptyPause = 5; $0.maxEmptyStreak = 2; $0.backoffBase = 0.1 })
        await c.attach(fetch: api.make(), onSupply: {})
        await drain(c)                      // seq1 新，seq2/3 重复 → 暂停 5s
        await c.demand(ahead: 0)            // 非紧急：约 5s 后的唤醒
        await c.demand(ahead: 0, urgent: true)   // seq4 失败 → 退避 0.1s
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(api.tickets.with { $0.count } >= 5, "失败退避结束后立刻重试（共 \(api.tickets.with { $0.count }) 个请求）")
    }

    print("18. 指标样本数组有上限")
    do {
        var m = DYFeedMetricsSnapshot()
        for i in 0..<(DYFeedMetricsSnapshot.sampleCap + 50) { m.addLatency(i); m.addFirstFrame(i) }
        check(m.latenciesMs.count == DYFeedMetricsSnapshot.sampleCap && m.latenciesMs.last == DYFeedMetricsSnapshot.sampleCap + 49, "只留最近 \(DYFeedMetricsSnapshot.sampleCap) 个")
    }

    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
