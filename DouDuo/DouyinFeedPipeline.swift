// 推荐流供应管线：Feed Pipeline + Shared Video Pool。
//
// - 一个 actor（DYFeedCoordinator）独占全部共享状态：请求序号 / refresh_index、在途请求、
//   候选池（DYSharedVideoPool）、退避与限速。请求方只负责「拿着票去请求」，不碰 refresh_index，
//   也不碰 UI 播放列表；结果交回 coordinator，先到先合并进候选池，再由 UI 那边统一从池子里取。
//   （接口不是游标分页，页与页之间的先后没有意义；按序号排队只会让慢请求卡住已经回来的结果。）
// - 推荐接口 /aweme/v1/web/tab/feed/ 不是游标分页：refresh_index 是客户端自增计数、响应里没有游标
//   （网页版同口径，2026-11 实测并发 2 页安全）。所以允许有限并发；若哪天接口改成依赖串行游标，
//   把 config.serialCursor 打开，并发就锁死成 1。
// - 本文件只依赖 Foundation（不引用 App 里的类型），方便单独编译做逻辑测试（scripts/test_feed_pipeline.sh）。
import Foundation

/// 候选条目需要的最小信息
protocol DYFeedItem: Sendable {
    var id: String { get }
    /// 竖屏（图文也算竖屏）：混排比例用
    var feedIsPortrait: Bool { get }
    /// 有可播放地址或是图文；没有的不进池
    var feedIsPlayable: Bool { get }
}

struct DYFeedPipelineConfig: Sendable, Equatable {
    /// 同时最多几个推荐 API 请求（1…4）。先定 2：实测 4 并发开始出现跨页重复、供应却没增加
    var maxConcurrent = 2
    /// 接口依赖串行游标时必须为 true（并发锁成 1）
    var serialCursor = false
    /// 待播队列（播放列表里当前条之后 + 候选池）目标条数
    var target = 20
    /// 少于这个数自动开始补充
    var lowWater = 8
    /// 起播时至少拿到几条就可以先交出去
    var firstBatch = 3
    /// 估算每页能拿到几条新内容（决定在途请求够不够，避免超量请求）。
    /// 这是还没有样本时的初值，之后按最近几页实际拿到的新内容数滚动估算。
    var expectedPerPage = 4
    /// 单个请求超时（秒）：超时视为失败并让出并发名额
    var requestTimeout: Double = 12
    /// 超时后再等这么久（秒）：期间结果晚到仍然收进池子，并撤销那次超时的退避
    var lateGrace: Double = 20
    /// 每分钟最多发几个推荐请求（硬上限，防止异常时狂刷接口）
    var maxRequestsPerMinute = 24
    /// 一轮补充（从低水位补到目标）最多发几个请求；不为凑数无限请求
    var episodeBudget = 8
    /// 连续几页没有新内容就暂停一会儿
    var maxEmptyStreak = 3
    var emptyPause: Double = 20
    /// 失败退避：base * 2^(n-1)，封顶
    var backoffBase: Double = 1.5
    var backoffCap: Double = 30
    /// 候选池内存上限（只存元数据）
    var poolCap = 80

    var effectiveConcurrency: Int { serialCursor ? 1 : max(1, min(maxConcurrent, 4)) }

    /// 默认并发 2。DEBUG 下可用环境变量做并发 1 / 2 / 4 对比：
    /// DOUDUO_FEED_CONCURRENCY=1…4；DOUDUO_FEED_WORKERS=1|2|4 是旧名字，含义相同（feed_bench.sh 还在用）。
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        var c = Self()
        #if DEBUG
        if let w = env["DOUDUO_FEED_WORKERS"].flatMap(Int.init), [1, 2, 4].contains(w) { c.maxConcurrent = w }
        if let n = env["DOUDUO_FEED_CONCURRENCY"].flatMap(Int.init), (1...4).contains(n) { c.maxConcurrent = n }
        if env["DOUDUO_FEED_SERIAL"] == "1" { c.serialCursor = true }
        #endif
        return c
    }
}

/// 一次推荐请求的「票」：序号、refresh_index、pull_type 都由 coordinator 统一分配
struct DYFeedTicket: Sendable, Equatable {
    let seq: Int
    let refreshIndex: Int
    let pull: String
    let generation: Int
}

struct DYFeedFetchedPage<Item: DYFeedItem>: Sendable {
    let items: [Item]
    let hasMore: Bool
}

// MARK: - Shared Video Pool

/// 内存候选池：只存元数据，保持服务端推荐顺序；所有来源统一去重。
/// 值类型、自身不做同步 —— 只由 DYFeedCoordinator（actor）持有和修改。
struct DYSharedVideoPool<Item: DYFeedItem>: Sendable {
    private(set) var candidates: [Item] = []
    /// 见过的全部 id（候选池 + 已交给播放列表的 + 会话恢复的），去重用
    private var known: Set<String> = []
    /// 误差扩散累计量：每排一条 +ratio，排了竖屏 -1；≥0.5 就该排竖屏。长期比例严格等于 ratio。
    private var mixCredit: Double = 0
    var ratio: Double?
    let cap: Int

    init(cap: Int) { self.cap = cap }

    var count: Int { candidates.count }
    func contains(_ id: String) -> Bool { known.contains(id) }

    mutating func register<S: Sequence>(_ ids: S) where S.Element == String { known.formUnion(ids) }

    /// 按顺序收进池子；返回新收的、重复的、没法播被丢掉的
    mutating func admit(_ items: [Item]) -> (fresh: [Item], duplicates: Int, unplayable: Int) {
        var fresh: [Item] = [], dup = 0, bad = 0
        for a in items {
            guard a.feedIsPlayable else { bad += 1; continue }
            guard known.insert(a.id).inserted else { dup += 1; continue }
            fresh.append(a)
        }
        candidates.append(contentsOf: fresh)
        trim()
        return (fresh, dup, bad)
    }

    /// 本地已缓存、没看过的放最前（秒开）
    mutating func seedFront(_ items: [Item]) {
        var front: [Item] = []
        for a in items where a.feedIsPlayable && known.insert(a.id).inserted { front.append(a) }
        candidates.insert(contentsOf: front, at: 0)
        trim()
    }

    /// 重排：把播放列表里还没播的退回池子最前（它们早已 known，不重复计数）
    mutating func putBack(_ items: [Item]) {
        let have = Set(candidates.map(\.id))
        candidates.insert(contentsOf: items.filter { !have.contains($0.id) }, at: 0)
        known.formUnion(items.map(\.id))
        mixCredit = 0
        trim()
    }

    /// 按目标比例取（同方向内保持推荐原顺序）。
    /// substitute=false：想要的方向没有就停，等下一页；true：用另一方向补位，保证不卡住。
    mutating func take(_ maxN: Int, substitute: Bool) -> [Item] {
        var out: [Item] = []
        while out.count < maxN, !candidates.isEmpty {
            guard let ratio else { out.append(candidates.removeFirst()); continue }
            let wantPortrait = mixCredit + ratio >= 0.5
            let index: Int
            if let i = candidates.firstIndex(where: { $0.feedIsPortrait == wantPortrait }) { index = i }
            // 少数方向缺货直接用多数方向顶上（90% 竖屏时缺横屏 = 多放一条竖屏，没必要多拉一页）
            else if substitute || wantPortrait != (ratio >= 0.5) { index = candidates.startIndex }
            else { break }
            let item = candidates.remove(at: index)
            out.append(item)
            // 补位造成的欠账最多记一条，避免候选恢复后连续猛补同一方向
            mixCredit = min(1, max(-1, mixCredit + ratio - (item.feedIsPortrait ? 1 : 0)))
        }
        return out
    }

    func peek(_ n: Int) -> ArraySlice<Item> { candidates.prefix(n) }

    /// 刷新：清掉候选（known 保留，新一批不会和刚看过的重复），返回旧候选以便失败时还原
    mutating func clearCandidates() -> [Item] {
        defer { candidates = []; mixCredit = 0 }
        return candidates
    }
    mutating func restore(_ backup: [Item]) {
        let have = Set(candidates.map(\.id))
        candidates = backup.filter { !have.contains($0.id) } + candidates
        trim()
    }

    mutating func reset() { candidates = []; known = []; mixCredit = 0 }

    /// 内存上限。有目标比例时先丢「过剩方向」里最靠后的（混排用不上的那批），
    /// 不然池子被横屏塞满后，删掉的恰恰是要用的竖屏新候选。
    private mutating func trim() {
        guard candidates.count > cap else { return }
        if let ratio {
            let surplusPortrait = ratio < 0.5
            while candidates.count > cap, let i = candidates.lastIndex(where: { $0.feedIsPortrait == surplusPortrait }) {
                candidates.remove(at: i)
            }
        }
        if candidates.count > cap { candidates.removeLast(candidates.count - cap) }
    }
}

// MARK: - 指标

/// 并发 1 / 2 / 4 对比用的指标
struct DYFeedMetricsSnapshot: Sendable, Codable, Equatable {
    /// 旧字段，现在恒等于 concurrency（压测结果文件名和旧 JSON 还在用）
    var workers = 0
    var concurrency = 0
    var requests = 0
    var succeeded = 0
    var failed = 0
    var timedOut = 0
    var stale = 0
    var returned = 0
    var fresh = 0
    var duplicates = 0
    var unplayable = 0
    var latenciesMs: [Int] = []
    var firstFramesMs: [Int] = []
    /// 滑到 / 播到当前条时后面已经没有可播的（得等供应）
    var swipeWaits = 0
    var swipes = 0
    var maxInFlight = 0
    /// 第一个请求发出 → 最近一次合并，单位秒
    var activeSeconds: Double = 0

    var errorRate: Double { requests == 0 ? 0 : Double(failed + timedOut) / Double(requests) }
    var duplicateRate: Double { returned == 0 ? 0 : Double(duplicates) / Double(returned) }
    var uniquePerSecond: Double { activeSeconds <= 0 ? 0 : Double(fresh) / activeSeconds }

    /// 样本数组只留最近这么多个，长会话不无限增长
    static let sampleCap = 500
    mutating func addLatency(_ ms: Int) { Self.push(ms, to: &latenciesMs) }
    mutating func addFirstFrame(_ ms: Int) { Self.push(ms, to: &firstFramesMs) }
    private static func push(_ v: Int, to xs: inout [Int]) {
        xs.append(v)
        if xs.count > sampleCap { xs.removeFirst(xs.count - sampleCap) }
    }

    static func percentile(_ xs: [Int], _ p: Double) -> Int? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    var summary: String {
        func ms(_ v: Int?) -> String { v.map { "\($0)ms" } ?? "-" }
        return "workers=\(workers) conc=\(concurrency) maxInFlight=\(maxInFlight) req=\(requests) ok=\(succeeded) err=\(failed) timeout=\(timedOut) stale=\(stale) "
            + "latency p50=\(ms(Self.percentile(latenciesMs, 0.5))) p90=\(ms(Self.percentile(latenciesMs, 0.9))) "
            + "unique=\(fresh) uniq/s=\(String(format: "%.2f", uniquePerSecond)) dup=\(String(format: "%.1f%%", duplicateRate * 100)) "
            + "errRate=\(String(format: "%.1f%%", errorRate * 100)) "
            + "firstFrame p50=\(ms(Self.percentile(firstFramesMs, 0.5))) p90=\(ms(Self.percentile(firstFramesMs, 0.9))) n=\(firstFramesMs.count) "
            + "swipeWaits=\(swipeWaits)/\(swipes)"
    }
}

// MARK: - Feed Coordinator

actor DYFeedCoordinator<Item: DYFeedItem> {
    typealias Fetch = @Sendable (DYFeedTicket) async throws -> DYFeedFetchedPage<Item>
    typealias Notify = @Sendable () async -> Void
    typealias Clock = @Sendable () -> Double
    typealias Log = @Sendable (String) -> Void

    private enum Outcome { case page(DYFeedFetchedPage<Item>), failure(String), timeout }

    let config: DYFeedPipelineConfig
    private(set) var pool: DYSharedVideoPool<Item>
    private var fetch: Fetch?
    private var onSupply: Notify?
    private let now: Clock
    private let log: Log

    // 序号：唯一、单调递增，跨刷新不回退（refresh_index 跟网页版一样一直往上数）
    private var nextSeq = 1
    private var generation = 0
    private var inFlight: [Int: (ticket: DYFeedTicket, started: Double)] = [:]
    /// 已判超时、但还在宽限期内等晚到结果的请求（不占并发名额）：seq → 发出时间
    private var late: [Int: Double] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]

    /// 最近一页接口自己报的 has_more，仅供界面参考。推荐流没有「到底」，不拿它停管线：
    /// 风控 / 登录抖动回一次空页就永久断粮不划算，空页交给 emptyStreak 暂停处理。
    private(set) var hasMore = true
    private(set) var lastError: String?
    /// 播放列表里当前条之后还有几条（UI 报上来）
    private var playlistAhead = 0
    private var urgent = false
    private var filling = false
    private var episodeRequests = 0
    private var emptyStreak = 0
    private var failStreak = 0
    /// 失败退避：接口在出错，用户在等也得尊重
    private var backoffUntil: Double = 0
    /// 省请求的暂停（连续空页 / 单轮预算用完）：用户在等（urgent）时跳过，仍受每分钟上限约束
    private var idleUntil: Double = 0
    private var pausedUntil: Double { urgent ? backoffUntil : max(backoffUntil, idleUntil) }
    private var recentStarts: [Double] = []
    /// 已约的唤醒时间（0 = 没约）；token 用来让被改约掉的旧唤醒失效
    private var wakeAt: Double = 0
    private var wakeToken = 0
    /// 上一次计入 failStreak 的时刻：在它之前发出的请求再失败属于同一轮，不重复翻倍退避
    private var lastFailAt: Double = -.infinity
    /// 最近几页各拿到几条新内容（滚动估算 expectedPerPage）
    private var recentFresh: [Int] = []
    /// 每合并一次（不管有没有新内容 / 失败）+1，等待方据此知道「有新结果了」
    private var mergeEpoch = 0
    private var waiters: [(epoch: Int, cont: CheckedContinuation<Bool, Never>)] = []

    private var metrics = DYFeedMetricsSnapshot()
    private var firstRequestAt: Double?
    private var lastBenchLog = 0

    init(config: DYFeedPipelineConfig = .fromEnvironment(),
         now: @escaping Clock = { Date().timeIntervalSince1970 },
         log: @escaping Log = { _ in }) {
        self.config = config
        self.pool = DYSharedVideoPool(cap: config.poolCap)
        self.now = now
        self.log = log
        metrics.workers = config.effectiveConcurrency
        metrics.concurrency = config.effectiveConcurrency
    }

    func attach(fetch: @escaping Fetch, onSupply: @escaping Notify) {
        self.fetch = fetch
        self.onSupply = onSupply
    }

    // MARK: 池子操作（UI 只通过这些方法动候选）

    var poolCount: Int { pool.count }
    var pending: Int { playlistAhead + pool.count }
    var inFlightCount: Int { inFlight.count }

    func setRatio(_ r: Double?) { pool.ratio = r }
    func register(_ ids: [String]) { pool.register(ids) }
    func seed(_ items: [Item]) { pool.seedFront(items) }
    func putBack(_ items: [Item]) { pool.putBack(items) }
    func peek(_ n: Int) -> [Item] { Array(pool.peek(n)) }

    /// 从池子按比例取给播放列表。这是候选进入 UI 播放列表的唯一出口。
    func take(_ n: Int, substitute: Bool, ahead: Int) -> [Item] {
        let out = pool.take(n, substitute: substitute)
        playlistAhead = ahead + out.count
        pump()
        return out
    }

    // MARK: 调度

    /// UI 报告当前待播情况；urgent = 用户正在等（没得播 / 起播 / 刷新）
    func demand(ahead: Int, urgent: Bool = false) {
        playlistAhead = max(0, ahead)
        if urgent { self.urgent = true }
        pump()
    }

    /// 等下一次合并（有新结果或失败），或管线已停（没在途请求也不会再发）。
    /// 返回 false = 管线停了，别再等。
    func awaitNextMerge() async -> Bool {
        let epoch = mergeEpoch
        if isIdle { return false }
        return await withCheckedContinuation { cont in waiters.append((epoch, cont)) }
    }

    /// 刷新推荐：作废在途请求，清空候选（失败时可还原），然后紧急拉新一批
    func beginRefresh() -> [Item] {
        invalidateInFlight()
        hasMore = true; lastError = nil; failStreak = 0; emptyStreak = 0; backoffUntil = 0; idleUntil = 0
        playlistAhead = 0
        return pool.clearCandidates()
    }
    func restore(_ backup: [Item]) { pool.restore(backup) }

    /// 账号变了 / 签名页重载：全部清掉（序号仍然继续往上数）
    func reset() {
        invalidateInFlight()
        pool.reset()
        hasMore = true; lastError = nil; failStreak = 0; emptyStreak = 0; backoffUntil = 0; idleUntil = 0
        playlistAhead = 0; urgent = false; filling = false; episodeRequests = 0
        lastFailAt = -.infinity; recentFresh = []
    }

    func snapshot() -> DYFeedMetricsSnapshot { metrics }
    func noteSwipe(waited: Bool) { metrics.swipes += 1; if waited { metrics.swipeWaits += 1 } }
    func noteFirstFrame(ms: Int) { metrics.addFirstFrame(ms) }

    // MARK: 内部

    private var isIdle: Bool {
        inFlight.isEmpty && (!filling || now() < pausedUntil || !canStart)
    }

    private var canStart: Bool { fetch != nil }

    private func invalidateInFlight() {
        generation += 1
        if !inFlight.isEmpty { metrics.stale += inFlight.count }
        inFlight.removeAll()
        late.removeAll()
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        resumeWaiters(force: true)
    }

    private func pump() {
        let pending = self.pending
        if pending >= config.target && !urgent {
            if filling { log("DDPIPE filled pending=\(pending) req=\(episodeRequests)") }
            filling = false; episodeRequests = 0
        } else if (pending < config.lowWater || urgent) && !filling {
            filling = true; episodeRequests = 0
        }
        guard filling, fetch != nil else { resumeWaiters(); return }
        let t = now()
        guard t >= pausedUntil else { scheduleWake(at: pausedUntil); resumeWaiters(); return }
        recentStarts.removeAll { t - $0 > 60 }
        while inFlight.count < config.effectiveConcurrency {
            // 在途请求预计能补够目标就不再多发
            if !urgent, pending + inFlight.count * expectedPerPage >= config.target { break }
            if episodeRequests >= config.episodeBudget {
                log("DDPIPE budget reached req=\(episodeRequests) pending=\(pending)，暂停补充")
                filling = false; urgent = false; episodeRequests = 0
                idleUntil = t + config.emptyPause
                break
            }
            if recentStarts.count >= config.maxRequestsPerMinute {
                scheduleWake(at: (recentStarts.first ?? t) + 60)
                break
            }
            start(at: t)
        }
        resumeWaiters()
    }

    /// 每页预计拿到几条新内容：最近 5 页的平均（至少 1），没有样本时用配置的初值
    private var expectedPerPage: Int {
        guard !recentFresh.isEmpty else { return max(1, config.expectedPerPage) }
        return max(1, Int((Double(recentFresh.reduce(0, +)) / Double(recentFresh.count)).rounded()))
    }

    private func start(at t: Double) {
        guard let fetch else { return }
        let seq = nextSeq
        nextSeq += 1
        // 跟原来一致：refresh_index 从 2 开始，第一个请求 pull_type=0，之后 2
        let ticket = DYFeedTicket(seq: seq, refreshIndex: seq + 1, pull: seq == 1 ? "0" : "2",
                                  generation: generation)
        inFlight[seq] = (ticket, t)
        episodeRequests += 1
        recentStarts.append(t)
        metrics.requests += 1
        metrics.maxInFlight = max(metrics.maxInFlight, inFlight.count)
        if firstRequestAt == nil { firstRequestAt = t }
        log("DDPIPE start seq=\(seq) refresh=\(ticket.refreshIndex) inFlight=\(inFlight.count) pending=\(pending) urgent=\(urgent)")
        tasks[seq] = Task {
            let outcome: Outcome
            do { outcome = .page(try await fetch(ticket)) } catch { outcome = .failure(error.localizedDescription) }
            self.complete(ticket, outcome)
        }
        let timeout = config.requestTimeout, grace = config.lateGrace
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.complete(ticket, .timeout)
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            self.expireLate(ticket)
        }
    }

    private func complete(_ ticket: DYFeedTicket, _ outcome: Outcome) {
        // 已作废（刷新 / 重置）：丢掉（作废时 invalidateInFlight 已经记过 stale，这里不重复计）
        guard ticket.generation == generation else { return }
        let seq = ticket.seq
        if let entry = inFlight.removeValue(forKey: seq) {
            let latency = Int((now() - entry.started) * 1000)
            switch outcome {
            case .page: metrics.succeeded += 1; metrics.addLatency(latency); tasks[seq] = nil
            case .failure: metrics.failed += 1; tasks[seq] = nil
            // 让出并发名额，但请求不取消：宽限期内回来的结果照收
            case .timeout: metrics.timedOut += 1; late[seq] = entry.started
            }
            merge(seq, outcome, started: entry.started)
        } else if let started = late.removeValue(forKey: seq) {
            tasks[seq] = nil
            // 超时后才失败：已经按超时罚过，不重复计
            guard case .page = outcome else { return }
            // 超时后晚到的成功结果：改记成功，撤销那次超时的退避（接口其实是通的，只是慢）
            metrics.timedOut -= 1; metrics.succeeded += 1
            metrics.addLatency(Int((now() - started) * 1000))
            backoffUntil = 0; lastFailAt = -.infinity
            log("DDPIPE late seq=\(seq) 超时后回来，照常合并")
            merge(seq, outcome, started: started)
        } else {
            return
        }
        pump()
    }

    /// 宽限期也过了：真正放弃这个请求
    private func expireLate(_ ticket: DYFeedTicket) {
        guard ticket.generation == generation, late.removeValue(forKey: ticket.seq) != nil else { return }
        tasks.removeValue(forKey: ticket.seq)?.cancel()
    }

    /// 失败退避按「轮」翻倍：并发的几个请求一起失败只算一次，
    /// 否则并发 2 时一次接口抖动就连翻两档。
    private func penalize(started: Double) {
        guard started >= lastFailAt else { return }
        let t = now()
        failStreak += 1; lastFailAt = t
        backoffUntil = max(backoffUntil, t + min(config.backoffCap, config.backoffBase * pow(2, Double(failStreak - 1))))
    }

    /// 先到先合并：结果一回来就进池子，不等前面序号的慢请求
    private func merge(_ seq: Int, _ outcome: Outcome, started: Double) {
        var merged = 0
        switch outcome {
        case .page(let p):
            let r = pool.admit(p.items)
            metrics.returned += p.items.count
            metrics.fresh += r.fresh.count
            metrics.duplicates += r.duplicates
            metrics.unplayable += r.unplayable
            hasMore = p.hasMore || !p.items.isEmpty
            failStreak = 0; lastError = nil; lastFailAt = -.infinity
            emptyStreak = r.fresh.isEmpty ? emptyStreak + 1 : 0
            merged = r.fresh.count
            recentFresh.append(merged)
            if recentFresh.count > 5 { recentFresh.removeFirst() }
            log("DDPIPE merge seq=\(seq) n=\(p.items.count) fresh=\(r.fresh.count) dup=\(r.duplicates) pool=\(pool.count)")
        case .failure(let msg):
            lastError = msg
            penalize(started: started)
            log("DDPIPE fail seq=\(seq) streak=\(failStreak) \(msg.prefix(80))")
        case .timeout:
            lastError = "推荐请求超时"
            penalize(started: started)
            log("DDPIPE timeout seq=\(seq) streak=\(failStreak)")
        }
        mergeEpoch += 1
        if let first = firstRequestAt { metrics.activeSeconds = now() - first }
        if emptyStreak >= config.maxEmptyStreak {
            log("DDPIPE \(emptyStreak) 页没有新内容，暂停 \(Int(config.emptyPause))s")
            emptyStreak = 0; filling = false; urgent = false
            idleUntil = now() + config.emptyPause
        }
        if merged > 0 { urgent = false }
        if merged > 0, let onSupply { Task { await onSupply() } }
        if metrics.requests - lastBenchLog >= 10 { lastBenchLog = metrics.requests; log("DDFEEDBENCH " + metrics.summary) }
    }

    private func resumeWaiters(force: Bool = false) {
        guard !waiters.isEmpty else { return }
        let idle = isIdle
        var keep: [(epoch: Int, cont: CheckedContinuation<Bool, Never>)] = []
        for w in waiters {
            if force || w.epoch < mergeEpoch { w.cont.resume(returning: true) }
            else if idle { w.cont.resume(returning: false) }
            else { keep.append(w) }
        }
        waiters = keep
    }

    /// 约一次唤醒。已经约了更早（或一样早）的就不动；新时间更早则改约，旧的那次作废。
    private func scheduleWake(at t: Double) {
        if wakeAt > 0, wakeAt <= t { return }
        wakeAt = t
        wakeToken += 1
        let token = wakeToken
        let delay = max(0.05, t - now())
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.wake(token)
        }
    }
    private func wake(_ token: Int) {
        guard token == wakeToken else { return }
        wakeAt = 0
        pump()
    }
}
