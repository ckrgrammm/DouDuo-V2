// 本地视频缓存：
// - 正在播的这条：立刻开始缓存（长视频只缓存头部），划走就停
// - 后面 1–2 条：只预取头部，刷到时能本地起播
// - 完整缓存的条目下次刷到/重开 App 直接播本地
import Foundation
import UIKit
import AVFoundation

/// 浏览会话保存在 Application Support，不随视频缓存清理或系统回收而丢失。
struct DYFeedSession: Codable {
    var items: [DYAweme]
    var currentID: String
    var positions: [String: Double]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feed-session.json")
    }
    static func load() -> DYFeedSession? {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Self.self, from: data),
              session.items.contains(where: { $0.id == session.currentID }) else { return nil }
        return session
    }
    private static let queue = DispatchQueue(label: "douduo.feed-session", qos: .utility)
    private static let lock = NSLock()
    private static var pending: DYFeedSession?

    /// 整份列表的编码 + 原子写盘不能压在主线程上（每滑一条会触发好几次，正好卡在翻页动画里）。
    /// 默认交给后台串行队列，连续多次只写最后一份；切后台前用 `sync: true` 立即落盘。
    func save(sync: Bool = false) {
        guard items.contains(where: { $0.id == currentID }) else { return }
        if sync {
            Self.lock.lock(); Self.pending = nil; Self.lock.unlock()
            Self.queue.sync { write() }
            return
        }
        Self.lock.lock()
        let scheduled = Self.pending != nil
        Self.pending = self
        Self.lock.unlock()
        guard !scheduled else { return }
        Self.queue.async {
            Self.lock.lock(); let latest = Self.pending; Self.pending = nil; Self.lock.unlock()
            latest?.write()
        }
    }
    private func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        do { try data.write(to: Self.url, options: .atomic) }
        catch { DYLiveModel.log("DDSESSION 保存失败 \(error.localizedDescription)") }
    }
}

actor DYVideoCache {
    static let shared = DYVideoCache()
    static let countKey = "douyin_cache_count_v2"
    static let defaultCount = 5
    /// 超过这个时长不整条下载，只缓存头部
    static let maxDuration: Double = 600
    /// 头部缓存字节数：约 6–20 秒（抖音码率 0.5–3 Mbps），够起播
    static let headBytes = 4_000_000
    /// 后面几条做头部预取（刷过来不卡的关键）
    static let headPrefetch = 2
    /// 保守按 3.2 Mbps 折算，宁可早一点切在线流，也不要播到没数据的尾部
    static let assumeBitsPerSecond: Double = 2_500_000
    static let maxBytes = 2 * 1024 * 1024 * 1024

    struct Entry: Codable {
        var aweme: DYAweme
        var watched: Bool
        var added: Double
        var bytes: Int
    }
    /// 头部缓存索引
    struct Head: Codable {
        var id: String
        var bytes: Int
        var added: Double
    }

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static var indexURL: URL { dir.appendingPathComponent("index.json") }
    nonisolated static var headIndexURL: URL { dir.appendingPathComponent("heads.json") }
    nonisolated static func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).mp4") }
    nonisolated static func headURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).head") }

    nonisolated static var limit: Int {
        (UserDefaults.standard.object(forKey: countKey) as? Int) ?? defaultCount
    }

    /// 已经整条下完的本地文件
    nonisolated static func localURL(_ id: String) -> URL? {
        let f = fileURL(id)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// 头部缓存（够起播即可）
    nonisolated static func headFile(_ id: String) -> URL? {
        let f = headURL(id)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int, size > 120_000 else { return nil }
        return f
    }

    /// 头部缓存能安全播到的秒数（保守折算，留 1.5 秒余量）
    nonisolated static func headPlayableSeconds(_ id: String) -> Double? {
        guard let f = headFile(id),
              let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int else { return nil }
        let s = Double(size) * 8 / assumeBitsPerSecond - 2.0
        return s > 1 ? s : nil
    }

    /// 启动时用：缓存好、还没看过的，按加入顺序
    nonisolated static func pendingSnapshot() -> [DYAweme] {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return list.filter { !$0.watched && localURL($0.aweme.id) != nil }.map(\.aweme)
    }

    /// 调试日志用（不要求精确）
    nonisolated(unsafe) static var activeDownloads = 0

    private var entries: [Entry]
    private var heads: [Head]
    private var job: Task<Void, Never>?
    private var jobID: String?
    private var failed: Set<String> = []
    /// async 方法里不直接引用 DYAweme 作为参数类型（该编译器在此处解析失败），改用它中转
    private var pending: [String: DYAweme] = [:]
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        if let d = try? Data(contentsOf: Self.indexURL), let list = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = list.filter { Self.localURL($0.aweme.id) != nil }
        } else {
            entries = []
        }
        if let d = try? Data(contentsOf: Self.headIndexURL), let list = try? JSONDecoder().decode([Head].self, from: d) {
            heads = list.filter { Self.headFile($0.id) != nil }
        } else {
            heads = []
        }
    }

    /// 播放焦点变了：缓存在播的这条（划走上一条就停），并预取后面几条的头部
    func focus(current: DYAweme?, ahead: [DYAweme]) {
        guard Self.limit > 0 else { job?.cancel(); job = nil; jobID = nil; return }
        let target = current ?? ahead.first
        guard let target else { return }
        if jobID == target.id, job != nil { return }
        job?.cancel()
        job = nil
        jobID = target.id
        let follow = Array(ahead.dropFirst().prefix(Self.headPrefetch))
        pending[target.id] = target
        for a in follow { pending[a.id] = a }
        job = Task { [weak self] in
            guard let self else { return }
            await self.sweepSilent()
            await self.store(id: target.id)
            for a in follow {
                if Task.isCancelled { return }
                await self.store(id: a.id)
            }
        }
    }

    /// 划走 / 离开：立刻停止缓存
    func stopCaching() {
        job?.cancel(); job = nil; jobID = nil
    }

    /// 只缓存整条视频：不再存「头部」，也就没有「头部播完接在线流」那一下切换
    /// （切换必然有一瞬闪烁/缓冲，长痛不如短痛）
    private func store(id: String) async {
        guard let a = pending[id], a.images.isEmpty, a.play != nil else { return }
        if Self.localURL(a.id) != nil { return }
        if failed.contains(a.id) { return }
        // 超长的视频整条太大，干脆不缓存，直接走在线流（不会闪，只是首帧慢一点）
        guard a.duration <= Self.maxDuration else { return }
        if Task.isCancelled { return }
        await storeFull(id: id)
    }

    /// 头部缓存：Range 请求前 2.5MB（服务端忽略 Range 返回整条时截取前段）
    /// 抖音直连 CDN 的 play 地址对 App 自己的请求会 403（播放器能播）；
    /// 实测 `/aweme/v1/play/`（带 sign，302 跳 CDN）和 playFast 可以正常下载。
    private func downloadURLs(_ a: DYAweme) -> [URL] {
        [a.playAlt, a.playFast, a.play].compactMap { $0 }.compactMap { URL(string: $0) }
    }

    private func storeHead(id: String) async {
        guard let a = pending[id] else { return }
        let t0 = Date()
        Self.activeDownloads = 1
        defer { Self.activeDownloads = 0 }
        for u in downloadURLs(a) {
            if Task.isCancelled { return }
            var r = URLRequest(url: u)
            DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("bytes=0-\(Self.headBytes - 1)", forHTTPHeaderField: "Range")
            do {
                let (data, resp) = try await session.data(for: r)
                guard let h = resp as? HTTPURLResponse else { continue }
                guard h.statusCode == 200 || h.statusCode == 206 else {
                    DYLiveModel.log("DDHEAD status=\(h.statusCode) host=\(u.host ?? "-") id=\(a.id)")
                    continue
                }
                let slice = data.count > Self.headBytes ? data.prefix(Self.headBytes) : data
                guard slice.count > 120_000 else { continue }
                try slice.write(to: Self.headURL(a.id))
                heads.removeAll { $0.id == a.id }
                heads.append(Head(id: a.id, bytes: slice.count, added: Date().timeIntervalSince1970))
                let cap = max(Self.limit * 2, 40)
                if heads.count > cap { heads.removeFirst(heads.count - cap) }
                saveHeads()
                DYLiveModel.log("DDHEAD ok \(a.id) \(slice.count / 1024)KB host=\(u.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                return
            } catch {
                DYLiveModel.log("DDHEAD fail host=\(u.host ?? "-") \(error.localizedDescription)")
            }
        }
        if !Task.isCancelled { failed.insert(a.id) }
    }

    /// 整条缓存（≤300 秒的视频才做；划走会取消，头部缓存已留下）
    private func storeFull(id: String) async {
        guard let a = pending[id] else { return }
        let t0 = Date()
        for u in downloadURLs(a) {
            if Task.isCancelled { return }
            var r = URLRequest(url: u)
            DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            do {
                let (tmp, resp) = try await session.download(for: r)
                if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
                    DYLiveModel.log("DDCACHE status=\(h.statusCode) host=\(u.host ?? "-") id=\(a.id)")
                    continue
                }
                let dst = Self.fileURL(a.id)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
                let bytes = ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? Int) ?? 0
                guard bytes > 50_000 else { try? FileManager.default.removeItem(at: dst); continue }
                // 有些条目的下载地址给的是「只有画面」的分轨流（声音另一路）。这种文件缓存下来，
                // 刷到时走本地播放就是有画面没声音，要等它被淘汰、回到在线流才有声。
                // 没有音轨的文件不留，换下一个地址；都没有就不缓存，直接走在线流。
                guard await Self.hasAudio(dst) else {
                    try? FileManager.default.removeItem(at: dst)
                    DYLiveModel.log("DDCACHE drop no-audio \(a.id) \(bytes / 1024)KB host=\(u.host ?? "-")")
                    continue
                }
                entries.removeAll { $0.aweme.id == a.id }
                entries.append(Entry(aweme: a, watched: false, added: Date().timeIntervalSince1970, bytes: bytes))
                evict()
                save()
                DYLiveModel.log("DDCACHE ok \(a.id) \(bytes / 1024)KB host=\(u.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s total=\(entries.count)")
                return
            } catch {
                DYLiveModel.log("DDCACHE fail host=\(u.host ?? "-") \(error.localizedDescription)")
            }
        }
        if !Task.isCancelled { failed.insert(a.id) }
    }

    nonisolated static func hasAudio(_ file: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// 清掉修复前留下的无声缓存文件（每次启动查一遍，最多几条）
    private var sweptSilent = false
    private func sweepSilent() async {
        guard !sweptSilent else { return }
        sweptSilent = true
        for e in entries {
            let f = Self.fileURL(e.aweme.id)
            guard FileManager.default.fileExists(atPath: f.path), !(await Self.hasAudio(f)) else { continue }
            try? FileManager.default.removeItem(at: f)
            entries.removeAll { $0.aweme.id == e.aweme.id }
            DYLiveModel.log("DDCACHE sweep no-audio \(e.aweme.id)")
        }
        save()
    }

    func markWatched(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.aweme.id == id }), !entries[i].watched else { return }
        entries[i].watched = true
        save()
    }

    func usage() -> (count: Int, bytes: Int) {
        (entries.count + heads.count, entries.reduce(0) { $0 + $1.bytes } + heads.reduce(0) { $0 + $1.bytes })
    }

    func clear() -> Int {
        let bytes = entries.reduce(0) { $0 + $1.bytes } + heads.reduce(0) { $0 + $1.bytes }
        job?.cancel(); job = nil; jobID = nil
        entries = []; heads = []
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        return bytes
    }

    /// 超上限：先删看过的（最早的先删），还超就删最早加进来的
    private func evict() {
        let lim = max(Self.limit, 0)
        while entries.count > lim || (entries.count > 1 && entries.reduce(0, { $0 + $1.bytes }) > Self.maxBytes) {
            let idx = entries.firstIndex(where: \.watched) ?? 0
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.fileURL(e.aweme.id))
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.indexURL, options: .atomic) }
    }
    private func saveHeads() {
        if let d = try? JSONEncoder().encode(heads) { try? d.write(to: Self.headIndexURL, options: .atomic) }
    }
}
