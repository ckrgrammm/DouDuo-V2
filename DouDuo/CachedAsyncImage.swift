import SwiftUI
import CryptoKit
import ImageIO

/// 进程级同步图片缓存。
/// NSCache 本身线程安全 → 同步读，不用 actor。
/// 关键：SwiftUI body 是同步计算的，view 重建时（滚动回收 cell）必须能在当前帧
/// 同步拿到已缓存的图，否则会先显示 placeholder（图片消失）再异步复原（延迟出现）。
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    // 正在下载中的任务，避免同一 URL 并发重复下载
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    // 正在取原始字节 / 正在解码缩略图的任务：预加载和页面同时要同一张时只做一次
    private var dataInflight: [URL: Task<Data?, Never>] = [:]
    fileprivate var thumbInflight: [URL: Task<UIImage?, Never>] = [:]
    fileprivate func withInflightLock<T>(_ body: () -> T) -> T { lock.withLock(body) }
    private let lock = NSLock()
    // 磁盘缓存目录（持久化，跨启动不丢；内存缓存清空/重启后从这里秒读）
    private let diskDir: URL
    private let io = DispatchQueue(label: "imagecache.disk", qos: .utility)

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 200 * 1024 * 1024 // 200MB
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        trimDiskCache()
    }

    /// URL → 磁盘文件名（哈希，避免非法字符）
    /// ⚠️ 绝不能用 String.hashValue：Swift 的 hashValue 每次进程启动都换随机种子，
    /// 同一个 URL 每次启动算出的文件名都不一样 → 磁盘缓存跨启动 100% 不命中
    /// （上面注释吹的「跨启动不丢」是假的，实际每次启动把所有图重下一遍），
    /// 而且旧文件永远没人认领也没人删，缓存目录只增不减（2026-08-09 修复）。
    /// SHA256 是确定性的，同一 URL 永远同一文件名。
    private func diskPath(_ url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(name)
    }

    /// 磁盘缓存清理：超上限就按修改时间从旧到新删到上限的 80%。
    /// 启动时后台跑一次。（在这之前没有任何清理逻辑，加上上面的 hashValue bug，
    /// 老用户盘上会积一堆永远命中不了的孤儿文件，这个清理也顺带把它们收掉。）
    private func trimDiskCache(limit: Int = 500 * 1024 * 1024) {
        let dir = diskDir
        io.async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
            ) else { return }
            var rows: [(url: URL, size: Int, date: Date)] = []
            var total = 0
            for f in files {
                guard let v = try? f.resourceValues(forKeys: Set(keys)),
                      let size = v.fileSize else { continue }
                rows.append((f, size, v.contentModificationDate ?? .distantPast))
                total += size
            }
            guard total > limit else { return }
            let target = limit * 4 / 5
            for row in rows.sorted(by: { $0.date < $1.date }) {
                if total <= target { break }
                try? fm.removeItem(at: row.url)
                total -= row.size
            }
        }
    }

    /// 同步命中（首帧用）：只查内存，绝不碰磁盘。
    /// ⚠️ 磁盘同步读会卡主线程（Data(contentsOf:) 在主线程跑），
    /// 图片多时滑动画廊每页都同步读盘 → 卡顿（2026-08-07 老板反馈）。
    /// 磁盘命中改走 diskCachedAsync（后台线程读，不回主线程）。
    func memoryCached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 异步磁盘命中（后台线程读，命中回填内存，下次走内存）
    func diskCachedAsync(_ url: URL) async -> UIImage? {
        let path = diskPath(url)
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let img = Self.decoded(data) else {
            // 盘上不是图片（以前把错误页也存了下来）：删掉，下次重新下载
            try? FileManager.default.removeItem(at: path)
            return nil
        }
        let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(img, forKey: url as NSURL, cost: cost)
        return img
    }

    /// 在当前（后台）线程把图解码好。UIImage(data:) 是懒解码，不处理的话第一次上屏会在主线程解码，
    /// 正好卡在滑动 / 翻页动画里。
    nonisolated static func decoded(_ data: Data) -> UIImage? {
        guard let img = UIImage(data: data) else { return nil }
        return img.preparingForDisplay() ?? img
    }

    /// 原始字节：磁盘 → 网络（成功后写盘）。不建 UIImage、不占内存缓存；同一 URL 并发只取一次。
    /// 网络失败重试一次，单次 15 秒超时——默认 60 秒会让一张坏图转很久。
    func data(for url: URL) async -> Data? {
        var created = false
        let task: Task<Data?, Never> = lock.withLock {
            if let running = dataInflight[url] { return running }
            created = true
            let fresh = Task<Data?, Never>(priority: .userInitiated) { await self.fetchData(url) }
            dataInflight[url] = fresh
            return fresh
        }
        let result = await task.value
        if created { lock.withLock { dataInflight[url] = nil } }
        return result
    }

    private func fetchData(_ url: URL) async -> Data? {
        if let disk = diskData(url) { return disk }
        for attempt in 0..<2 {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.cachePolicy = .returnCacheDataElseLoad
            if let (data, resp) = try? await URLSession.shared.data(for: req), !data.isEmpty,
               (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                let path = diskPath(url)
                io.async { try? data.write(to: path, options: .atomic) }
                return data
            }
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        return nil
    }

    /// 读原图磁盘缓存的原始字节（后台线程调用）
    func diskData(_ url: URL) -> Data? {
        try? Data(contentsOf: diskPath(url))
    }

    func storeMemory(_ img: UIImage, for key: URL, cost: Int) {
        cache.setObject(img, forKey: key as NSURL, cost: cost)
    }

    /// 兼容旧调用：等价 memoryCached（只内存，不碰磁盘）
    func cached(_ url: URL) -> UIImage? { memoryCached(url) }

    /// 异步加载（缓存未命中时调用）：内存 → 磁盘(后台) → 网络。已在下载中的复用同一个任务。
    func load(_ url: URL) async -> UIImage? {
        if let hit = memoryCached(url) { return hit }

        // NSLock 只能在同步区间里用（async 上下文直接 lock/unlock 在 Swift 6 是错误），
        // 所以查表 + 登记放进 withLock，await 在锁外。
        var created = false
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inflight[url] { return running }
            created = true
            let fresh = makeLoadTask(url)
            inflight[url] = fresh
            return fresh
        }
        let result = await task.value
        guard created else { return result }
        lock.withLock { inflight[url] = nil }

        if let img = result {
            let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            cache.setObject(img, forKey: url as NSURL, cost: cost)
        }
        return result
    }

    private func makeLoadTask(_ url: URL) -> Task<UIImage?, Never> {
        Task<UIImage?, Never> {
            // 磁盘命中（后台线程读，不卡 UI）
            if let disk = await self.diskCachedAsync(url) { return disk }
            guard let data = await self.data(for: url) else { return nil }
            return Self.decoded(data)
        }
    }
}

// MARK: - 缩略图（2026-10-14 角色/收藏面板卡顿优化）
// 库卡片只有 ~180pt 宽，封面原图中位 830×830、最大 1536px：原来整张解码进内存，
// 且 UIImage(data:) 是懒解码——第一次上屏时在主线程解码，面板一打开十几张同时解 = 卡一下。
// 缩略图在后台用 ImageIO 直接按目标尺寸解码，内存缓存单独一份（key = url#thumbN），原图缓存不受影响。
extension ImageCache {
    func thumbKey(_ url: URL, _ maxPixel: Int) -> URL {
        URL(string: url.absoluteString + "#thumb\(maxPixel)") ?? url
    }

    func memoryThumb(_ url: URL, maxPixel: Int) -> UIImage? {
        memoryCached(thumbKey(url, maxPixel))
    }

    /// 后台下采样：直接从原始字节按目标尺寸解码。
    /// 以前是「下载 → 建整张 UIImage 进内存缓存 → 转成 JPEG → 再下采样」：一张 2160×2880 的图要整张解码、
    /// 重新编码再解码一次，而且整张图按 25MB 计入内存缓存，十几张图的图文会把已经解好的缩略图挤出去
    /// （翻到后面几张又变黑、重新加载）。现在只解一次缩略图，原图不进内存。
    func loadThumb(_ url: URL, maxPixel: Int) async -> UIImage? {
        let key = thumbKey(url, maxPixel)
        if let hit = memoryCached(key) { return hit }
        var created = false
        let task: Task<UIImage?, Never> = withInflightLock {
            if let running = thumbInflight[key] { return running }
            created = true
            let fresh = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
                guard let data = await self.data(for: url) else { return nil }
                return Self.downsample(data, maxPixel: maxPixel)
            }
            thumbInflight[key] = fresh
            return fresh
        }
        let thumb = await task.value
        guard created else { return thumb }
        withInflightLock { thumbInflight[key] = nil }
        if let thumb {
            let cost = thumb.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            storeMemory(thumb, for: key, cost: cost)
        }
        return thumb
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,   // 在这里（后台）就解码完
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 与 `AsyncImagePhase` 对应的加载阶段（走 ImageCache，替代系统 `AsyncImage`）。
enum CachedImagePhase {
    case empty
    case success(Image)
    case failure
}

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    /// phase 形式的渲染闭包；非 nil 时优先于 content/placeholder。
    private var phaseContent: ((CachedImagePhase) -> Content)?
    /// 非 nil = 只要缩略图（后台按此像素上限下采样解码），库卡片这类小框用
    private var thumbnailMaxPixel: Int?

    // 初始值直接用同步缓存命中：view 重建时缓存里有图就当帧显示，不闪。
    @State private var uiImage: UIImage?
    /// 下载失败（缓存与网络都拿不到）→ phase 形式回 `.failure`
    @State private var failed = false

    init(
        url: URL?,
        thumbnailMaxPixel: Int? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        self.thumbnailMaxPixel = thumbnailMaxPixel
        // 关键：初始化时同步命中缓存，作为 @State 的初始值。
        // 这样 view 一构建（含滚动回收后的重建）就有图，body 首帧不会走 placeholder。
        _uiImage = State(initialValue: url.flatMap { Self.memoryHit($0, thumbnailMaxPixel) })
    }

    private static func memoryHit(_ url: URL, _ maxPixel: Int?) -> UIImage? {
        if let maxPixel { return ImageCache.shared.memoryThumb(url, maxPixel: maxPixel) }
        return ImageCache.shared.memoryCached(url)
    }

    /// 按加载阶段渲染（对齐 `AsyncImage(url:) { phase in }` 的写法）。
    init(
        url: URL?,
        @ViewBuilder content: @escaping (CachedImagePhase) -> Content
    ) where Placeholder == EmptyView {
        self.url = url
        self.content = { content(.success($0)) }
        self.placeholder = { EmptyView() }
        self.phaseContent = content
        _uiImage = State(initialValue: url.flatMap { ImageCache.shared.memoryCached($0) })
    }

    var body: some View {
        // 关键：body 同步读缓存作为兜底。即使 @State 因 view 重建被重置，
        // 只要缓存里有图，当前帧也能立刻显示，不会闪回 placeholder。
        // 只读内存缓存——磁盘读改异步（diskCachedAsync），主线程不碰盘（2026-08-07 卡顿修复）。
        let display = uiImage ?? url.flatMap { Self.memoryHit($0, thumbnailMaxPixel) }
        return Group {
            if let phaseContent {
                if let img = display {
                    phaseContent(.success(Image(uiImage: img)))
                } else if failed {
                    phaseContent(.failure)
                } else {
                    phaseContent(.empty)
                }
            } else if let img = display {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            failed = false
            guard let url else { failed = true; return }
            // 始终按当前 url 取图：
            //  - 命中当前 url 的缓存（内存/磁盘）→ 显示（幂等，无网络）
            //  - 未命中（= cacheBust 换了 URL 或首次）→ 后台下载，完成后替换
            // ⚠️ 别用 "uiImage != nil 就 return" —— 重新生成打 cacheBust 后 URL 变了，
            //    但旧图还在 uiImage 里，直接 return 会让新图永远不加载（2026-08-06 bug）。
            //    下载期间保留旧图（不闪 placeholder），新图就绪后无缝替换。
            if let hit = Self.memoryHit(url, thumbnailMaxPixel) {
                uiImage = hit
                return
            }
            // 失败后隔一会儿再试一次（弱网抖一下不该让这张图一直空着）
            for attempt in 0..<2 {
                let img: UIImage?
                if let maxPixel = thumbnailMaxPixel {
                    img = await ImageCache.shared.loadThumb(url, maxPixel: maxPixel)
                } else {
                    img = await ImageCache.shared.load(url)
                }
                if let img { uiImage = img; return }
                guard attempt == 0 else { break }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
            failed = true
        }
    }
}

/// 渐进式图片：先显示小图（thumb，快），后台拉大图（full），加载完无缝替换成清晰大图。
struct ProgressiveImage<Content: View, Placeholder: View>: View {
    let thumbURL: URL?
    let fullURL: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var isFull = false

    init(
        thumbURL: URL?,
        fullURL: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.thumbURL = thumbURL
        self.fullURL = fullURL
        self.content = content
        self.placeholder = placeholder
        // 同步命中：优先大图，否则小图（只内存，磁盘走 .task 异步，2026-08-07 卡顿修复）
        let initial = fullURL.flatMap { ImageCache.shared.memoryCached($0) }
            ?? thumbURL.flatMap { ImageCache.shared.memoryCached($0) }
        _uiImage = State(initialValue: initial)
        _isFull = State(initialValue: fullURL.flatMap { ImageCache.shared.memoryCached($0) } != nil)
    }

    var body: some View {
        // 与 CachedAsyncImage 保持一致：body 里同步兜底读一次内存缓存。
        // @State 会随 view 重建（滚动回收 cell）被重置，只要缓存里有图，
        // 当前帧就该立刻显示，不该闪回 placeholder（2026-08-09 补齐，
        // 之前只有 CachedAsyncImage 有这个兜底，ProgressiveImage 漏了）。
        let display = uiImage
            ?? fullURL.flatMap { ImageCache.shared.memoryCached($0) }
            ?? thumbURL.flatMap { ImageCache.shared.memoryCached($0) }
        return Group {
            if let img = display {
                content(Image(uiImage: img))
            } else {
                placeholder()
            }
        }
        .task(id: fullURL) {
            // 1) 先上小图（如果还没有大图）
            if !isFull, uiImage == nil, let t = thumbURL {
                if let small = await ImageCache.shared.load(t) {
                    if !isFull { uiImage = small }
                }
            }
            // 2) 后台拉大图，好了替换
            guard let f = fullURL else { return }
            if let big = await ImageCache.shared.load(f) {
                uiImage = big
                isFull = true
            }
        }
    }
}
