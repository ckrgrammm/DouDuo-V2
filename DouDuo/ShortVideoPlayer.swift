// 短视频播放页：从 無為 影库播放器（PlayerPage）精简而来，只留抖音需要的部分——
// AVPlayer 直连、横滑快进（预览缩略图 + 目标时间 HUD）、双击、长按 2 倍速、单击暂停、竖滑切视频、底部可拖进度条。
import SwiftUI
import AVFoundation
import MediaPlayer
import CoreImage

/// 全局播放登记表：App 进后台/失焦时由 App 层直接命令所有播放器停声，
/// 比依赖视图的 onReceive 稳（视图可能还没渲染、或被 LazyVStack 回收）。
/// 当前绑着锁屏控件的播放页 id（空 = 没绑）
@MainActor enum DDRemoteOwner { static var id = "" }

final class DDPlayback {
    static let shared = DDPlayback()
    private var stoppers: [UUID: () -> Void] = [:]
    private var starters: [UUID: () -> Void] = [:]
    private var lock = NSLock()
    /// App 当前是否在前台：注册晚于切后台时（视频刚起播），要立刻停，不能接着响
    private(set) var appIsActive = true

    func register(_ id: UUID, stop: @escaping () -> Void, start: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        stoppers[id] = stop; starters[id] = start
        let shouldStop = !appIsActive
        #if DEBUG
        ddWrite("DDBG register \(id.uuidString.prefix(4)) total=\(stoppers.count) appActive=\(appIsActive)")
        #endif
        if shouldStop { stop() }
    }
    func unregister(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        stoppers[id] = nil; starters[id] = nil
        #if DEBUG
        ddWrite("DDBG unregister \(id.uuidString.prefix(4)) total=\(stoppers.count)")
        #endif
    }
    /// 「更多」菜单里的「后台播放」：开了就不因切后台/锁屏停声（听书用）
    static var bgPlay: Bool { UserDefaults.standard.bool(forKey: "douyin_bg_play_v1") }
    func pauseAll() {
        if Self.bgPlay { return }
        appIsActive = false
        lock.lock(); let s = Array(stoppers.values); lock.unlock()
        #if DEBUG
        ddWrite("DDBG pauseAll count=\(s.count)")
        #endif
        s.forEach { $0() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func resumeAll() {
        appIsActive = true
        lock.lock(); let s = Array(starters.values); lock.unlock()
        #if DEBUG
        ddWrite("DDBG resumeAll count=\(s.count)")
        #endif
        s.forEach { $0() }
    }
}

/// 无声排查 + 兜底：App 里还有隐藏的网页（签名页、转发预加载）共用同一个音频会话，
/// 网页一旦碰媒体，WebKit 可能把会话类别从 .playback 改掉 —— 原生视频照常播但没声，
/// 滑走再滑回来（重新 setCategory + setActive）就好了。这里在当前条播放期间发现类别被改就立刻改回，
/// 并把每次会话变化记进 ddlog.txt（DDAUDIO），用来确认是不是这个原因。
enum DDAudioGuard {
    static var sessionState: String {
        let s = AVAudioSession.sharedInstance()
        return "cat=\(s.category.rawValue) mode=\(s.mode.rawValue) opts=\(s.categoryOptions.rawValue)"
    }

    private static var healLogs = 0
    /// 当前条正在播时调用（每 0.25s 一次，只读一个属性，类别没变就什么都不做）
    static func reassert(_ id: String) {
        let s = AVAudioSession.sharedInstance()
        guard s.category != .playback else { return }
        let before = sessionState
        try? s.setCategory(.playback, mode: .moviePlayback)
        try? s.setActive(true)
        if healLogs < 200 {
            healLogs += 1
            DYLiveModel.log("DDAUDIO heal \(id) 会话类别被改，已改回：\(before) → \(sessionState)")
        }
    }

    static func install() { _ = installed }
    private static let installed: Bool = {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            // reason 3 = categoryChange：有人改了会话类别
            DYLiveModel.log("DDAUDIO routeChange reason=\(reason) \(sessionState)")
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99
            // type 1 = 被打断开始，0 = 结束
            DYLiveModel.log("DDAUDIO interruption type=\(type) \(sessionState)")
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            DYLiveModel.log("DDAUDIO mediaServicesWereReset \(sessionState)")
        }
        return true
    }()
}

/// 抖音视频 CDN（douyinvod.com）要浏览器 UA + Referer，否则 403（真机实测：plain/CoreMedia UA 403，Safari UA+Referer 206）
enum DYMedia {
    static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "Referer": "https://www.douyin.com/",
    ]
    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
    /// 直播（VLC 用）：Referer 要 live.douyin.com
    static var liveHeaders: [String: String] {
        var h = headers
        h["Referer"] = "https://live.douyin.com/"
        return h
    }
    /// 直播 HLS：CDN 认 live.douyin.com 的 Referer，不带会 403（表现为一直转圈/黑屏）
    static func liveAsset(_ url: URL) -> AVURLAsset {
        var h = headers
        h["Referer"] = "https://live.douyin.com/"
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": h])
    }
}

extension PlayerPage {
    /// 与 無為 同名同参的构造入口，DouyinFeedView 原样复用
    static func external(id: String, title: String, url: URL, durationSec: Double, isActive: Bool,
                         topInset: CGFloat, bottomInset: CGFloat, resumePosition: Double?,
                         compactChrome: Bool,
                         preparedPlayer: (() -> AVPlayer?)? = nil,
                         onEnded: (() -> Void)?, onDoubleTap: (() -> Void)?,
                         onSavePosition: @escaping (Double) -> Void, onClose: @escaping () -> Void,
                         fillWidth: Bool = true, danmaku: [DYDanmaku] = [], altURL: URL? = nil,
                         quality: String? = nil, fastURL: URL? = nil, posterURL: URL? = nil,
                         videoAspect: Double = 0,
                         headEndSeconds: Double? = nil, continuationURL: URL? = nil,
                         onSwipeLeft: (() -> Void)? = nil, onSwipeRight: (() -> Void)? = nil,
                         fillCropLimit: Double = 0.18, dragSeek: Bool = true) -> PlayerPage {
        var page = PlayerPage(id: id, url: url, knownDuration: durationSec, isActive: isActive, bottomInset: bottomInset,
                   resumePosition: resumePosition, preparedPlayer: preparedPlayer, onEnded: onEnded,
                   onDoubleTap: onDoubleTap, onSavePosition: onSavePosition, fillWidth: fillWidth,
                   topInset: topInset, danmaku: danmaku, altURL: altURL, quality: quality, fastURL: fastURL,
                   posterURL: posterURL, headEndSeconds: headEndSeconds,
                   continuationURL: continuationURL, videoAspect: videoAspect, title: title, onSwipeLeft: onSwipeLeft, onSwipeRight: onSwipeRight)
        page.fillCropLimit = fillCropLimit
        page.dragSeek = dragSeek
        return page
    }
}

/// 横滑切页的跟手状态。只有挂了 DYSwipeSlide 的视图观察它，拖动时不会让整页 body 重算。
final class DYSwipeTracker: ObservableObject {
    /// 当前跟手位移（负 = 往左）
    @Published var dragX: CGFloat = 0
    @Published var width: CGFloat = 400
    /// 起手时问宿主：这个方向有没有可以滑出来的相邻页（有则宿主把它挂上）
    var accepts: ((CGFloat) -> Bool)?
    var onCancel: (() -> Void)?
    private var active: Bool?

    func drag(_ dx: CGFloat, direction: CGFloat) {
        if active == nil { active = accepts?(direction) ?? false }
        if active == true { dragX = dx }
    }
    func end() { active = nil }
    func cancel() {
        let was = active
        active = nil
        if was == true { onCancel?() }
    }
}

private struct DYSwipeTrackerKey: EnvironmentKey {
    static let defaultValue: DYSwipeTracker? = nil
}

extension EnvironmentValues {
    var dySwipeTracker: DYSwipeTracker? {
        get { self[DYSwipeTrackerKey.self] }
        set { self[DYSwipeTrackerKey.self] = newValue }
    }
}

/// base：静止时停在第几屏（-1 左一屏 / 0 当前 / +1 右一屏），再叠加跟手位移。
struct DYSwipeSlide: ViewModifier {
    @ObservedObject var tracker: DYSwipeTracker
    let base: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: base * tracker.width + tracker.dragX)
    }
}

// Low-resolution, cached still blur: no live-video filters or second player.
final class DYVideoBackdropCache: @unchecked Sendable {
    static let shared = DYVideoBackdropCache()
    private let images = NSCache<NSURL, UIImage>()
    private let worker = DispatchQueue(label: "douduo.backdrop", qos: .utility)
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    init() { images.countLimit = 48; images.totalCostLimit = 4 * 1024 * 1024 }
    func cached(_ url: URL) -> UIImage? { images.object(forKey: url as NSURL) }
    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        guard let source = await ImageCache.shared.load(url) else { return nil }
        return await withCheckedContinuation { continuation in
            worker.async { [self] in
                if let hit = cached(url) { continuation.resume(returning: hit); return }
                let aspect = source.size.width / max(source.size.height, 1)
                let size = aspect >= 1 ? CGSize(width: 128, height: 128 / max(aspect, 0.01))
                    : CGSize(width: 128 * max(aspect, 0.01), height: 128)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    source.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let input = CIImage(image: small),
                      let output = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: 12])?.outputImage,
                      let cg = context.createCGImage(output, from: input.extent) else {
                    continuation.resume(returning: small); return
                }
                let image = UIImage(cgImage: cg)
                images.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
                continuation.resume(returning: image)
            }
        }
    }
}

struct DYBlurredVideoBackdrop: View {
    let url: URL?
    @State private var image: UIImage?
    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap { DYVideoBackdropCache.shared.cached($0) })
    }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.08)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                Color.black.opacity(0.28)
                LinearGradient(colors: [.black.opacity(0.36), .clear, .black.opacity(0.52)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.16), .clear, .black.opacity(0.16)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false).accessibilityHidden(true)
        .task(id: url) {
            guard let url, let loaded = await DYVideoBackdropCache.shared.load(url), !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { image = loaded }
        }
    }
}

struct DYMediaViewport: ViewModifier {
    let aspect: Double
    let fillPortrait: Bool
    /// 竖视频铺满时最多允许裁掉的宽/高比例；超过就完整显示（居中）。外屏放宽到 0.3，9:16 也能铺满
    var maxCrop: Double = 0.18
    static func mediaSize(aspect: Double, container: CGSize, fillPortrait: Bool, maxCrop: Double = 0.18) -> CGSize {
        guard aspect.isFinite, aspect > 0, container.width > 0, container.height > 0 else { return container }
        let screen = container.width / container.height
        let crop = 1 - min(aspect, screen) / max(aspect, screen)
        if fillPortrait && aspect < 1 && screen < 1 && crop <= maxCrop { return container }
        return aspect > screen ? CGSize(width: container.width, height: container.width / aspect)
            : CGSize(width: container.height * aspect, height: container.height)
    }
    func body(content: Content) -> some View {
        GeometryReader { geo in
            let size = Self.mediaSize(aspect: aspect, container: geo.size, fillPortrait: fillPortrait, maxCrop: maxCrop)
            content.frame(width: size.width, height: size.height).clipped()
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

struct PlayerPage: View {
    let id: String
    let url: URL
    let knownDuration: Double
    let isActive: Bool
    let bottomInset: CGFloat
    let resumePosition: Double?
    let preparedPlayer: (() -> AVPlayer?)?
    let onEnded: (() -> Void)?
    let onDoubleTap: (() -> Void)?
    let onSavePosition: (Double) -> Void
    /// 竖屏时视频比屏幕窄（左右黑边）→ 放大铺满宽度；关掉则保持完整画面（上下留边）
    var fillWidth: Bool = true
    var topInset: CGFloat = 0
    /// 视频弹幕（空 = 不显示）
    var danmaku: [DYDanmaku] = []
    /// 高清流起不来时的备用地址（抖音默认清晰度那条）；看门狗第一次重建就换它
    var altURL: URL? = nil
    /// 选中的清晰度描述（只进调试日志）
    var quality: String? = nil
    /// 秒开：低码率地址。滑到一条还没缓冲好的视频时先放它，高清在上层缓冲好后无缝盖上去
    var fastURL: URL? = nil
    /// 封面：首帧出来前先显示（网格里已经缓存过，点进来立刻有画面，不是黑屏转圈）
    var posterURL: URL? = nil
    /// 本地「头部缓存」能安全播到的秒数：播到这里就用 continuationURL 接上在线流，
    /// 不能让 AVPlayer 冲到没数据的尾部（那样会卡住而不是 ended）
    var headEndSeconds: Double? = nil
    /// 头部缓存播完后继续播的在线地址（一次性）
    var continuationURL: URL? = nil
    @State private var continued = false
    @State private var firstFrame = false
    /// 视频画面宽高比（海报占位用同一套铺满规则，避免「先小后跳」）
    var videoAspect: Double = 0
    /// 锁屏 / 控制中心「正在播放」上显示的标题
    var title: String = ""
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil
    var dragSeek = true
    /// 竖视频铺满的裁切上限（见 DYMediaViewport.maxCrop）
    var fillCropLimit: Double = 0.18
    /// 上一次刷新「正在播放」信息的位置（约每秒一次）
    @State private var lastNowPlaying = -10.0
    /// 静音（右下角按钮，全局记住）
    @AppStorage("douyin_muted_v1") private var muted = false
    @Environment(\.ddScale) private var ui
    @Environment(\.dySwipeTracker) private var swipeTracker

    private var dmStress: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["DOUDUO_DM_STRESS"] == "1"
        #else
        false
        #endif
    }

    @State private var player: AVPlayer?
    @State private var imgGen: AVAssetImageGenerator?
    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var isPlaying = false
    @State private var seeking = false
    @State private var seekPreview: Double = 0
    @State private var seekDelta: Double = 0
    @State private var previewImage: UIImage?
    @State private var lastPreviewAt: Double = 0
    @State private var holdAnchor: Double = 0
    @State private var rateBoost = false
    /// 锁定倍速（「更多」菜单里选的）：长按 2 倍速松手、换视频、重新起播都回到它
    @AppStorage("douyin_rate_v1") private var lockedRate = 1.0
    @State private var dmClock = DYDanmakuClock()
    @State private var timeToken: Any?
    @State private var endObserver: NSObjectProtocol?
    /// 播放项直接失败（地址 403 / 解不开）就立刻换备用地址，不等 6 秒看门狗
    @State private var failObserver: NSKeyValueObservation?
    @State private var barWidth: CGFloat = 1
    @State private var vlc: VLCPlayerController?        // AVPlayer 起播失败 → VLC 软解兜底
    @State private var avRetried = false
    /// 秒开期间：高清播放器（静音、几乎透明地叠在低清上面缓冲），就绪后淡入接管
    @State private var hdPlayer: AVPlayer?
    @State private var hdVisible = false
    /// 头部缓存播完要接在线流：提前预热好，到点直接换图层里的 player（不重建、不重新缓冲）
    @State private var nextPlayer: AVPlayer?
    @State private var nextPrimedAt: Double = 0
    @State private var nextOpacity: Double = 0
    @State private var stalledTicks = 0
    @State private var fastT0 = Date()
    private let playbackID = UUID()

    var body: some View {
        ZStack {
            DYBlurredVideoBackdrop(url: posterURL)
            ZStack {
                if let vlc {
                    // 画面铺到屏幕边缘（状态栏/底部安全区也盖住）：跟抖音原生一样，不留上下黑边
                    VLCPlayerSurface(controller: vlc, fillWidth: fillWidth)
                } else if let player {
                    // 画面层真正有帧可显示（isReadyForDisplay）就撤掉封面：预加载 / 本地缓存的视频滑过来就是真画面，
                    // 不再「先闪一下封面再播」
                    ZStack {
                        VideoSurface(player: player, fillWidth: fillWidth, onReady: { if !firstFrame { firstFrame = true } })
                            
                        // 头部缓存接在线流：新播放器先叠在上面亮相（已缓冲、时间点对齐），再撤掉旧的，
                        // 避免换 AVPlayerLayer 的 player 时断帧
                        if let np = nextPlayer {
                            VideoSurface(player: np, fillWidth: fillWidth)
                                
                                .opacity(nextOpacity)
                                .allowsHitTesting(false)
                        }
                    }
                } else {
                    ProgressView().tint(.white)
                }
                if vlc == nil, let hd = hdPlayer {
                    // 0.001 而不是 0：完全透明的层可能不出画面，换上来时会黑一下
                    VideoSurface(player: hd, fillWidth: fillWidth)
                        .opacity(hdVisible ? 1 : 0.001).allowsHitTesting(false)
                }
                // 封面只给「还没缓存、还没出帧」的在线视频兜底；本地已缓存的直接等首帧（几十毫秒），不铺封面
                if !firstFrame, let posterURL {
                    GeometryReader { g in
                        let screen = g.size.width / max(g.size.height, 1)
                        let video = videoAspect > 0 ? videoAspect : screen
                        let same = (video < 1) == (screen < 1)
                        CachedAsyncImage(url: posterURL) { img in
                            img.resizable().aspectRatio(contentMode: fillWidth && same ? .fill : .fit)
                        } placeholder: { Color.clear }
                        .frame(width: g.size.width, height: g.size.height)
                    }
                        
                        .allowsHitTesting(false)
                }
            }
            .modifier(DYMediaViewport(aspect: videoAspect, fillPortrait: fillWidth, maxCrop: fillCropLimit))
            if isActive && (!danmaku.isEmpty || dmStress) {
                DYDanmakuLayer(items: danmaku, clock: dmClock, topInset: topInset)
            }
            // 手势层铺满整页（含视频上下黑边）：横滑快进 / 单击 / 双击 / 长按，竖滑漏给分页
            if player != nil || vlc != nil { gestures }
            if seeking { seekHUD }
            if isActive && !isPlaying && (player != nil || vlc != nil) && !seeking {
                Image(systemName: "play.fill").font(.system(size: 52 * ui)).foregroundStyle(.white.opacity(0.75))
                    .allowsHitTesting(false)
            }
            // 只在长按时出现：没锁定 → 下滑锁定；已锁定 → 上滑恢复 1 倍
            if rateBoost {
                Label(lockedRate == 2 ? "2 倍速 · 上滑恢复" : "2 倍速播放中 · 下滑锁定", systemImage: "forward.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70 * ui)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if isActive { progressBar.padding(.bottom, max(bottomInset, 8)) }
        }
        .onAppear {
            if player == nil { setup() }
            if isActive { bindRemote() }
            DDPlayback.shared.register(playbackID, stop: { pauseForBackground() }, start: { resumeAfterBackground() })
        }
        .onDisappear {
            DDPlayback.shared.unregister(playbackID)
            teardown()
        }
        // 切后台 / 来电 / 下拉控制中心立刻停声（否则退出 App 声音还在响）
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            pauseForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            pauseForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            resumeAfterBackground()
        }
        .onChange(of: muted) { _, m in
            guard isActive else { return }
            player?.isMuted = m
            vlc?.mediaPlayer.audio?.isMuted = m
        }
        // 推荐流指标：当前条首帧耗时（不是推荐页当前条的，DYFeedBench 自己忽略）
        .onChange(of: firstFrame) { _, ready in if ready && isActive { DYFeedBench.firstFrame(id) } }
        .onChange(of: isActive) { _, active in
            if active { bindRemote() }
            if active && firstFrame { DYFeedBench.firstFrame(id) }   // 预加载好的：一滑到就有画面
            if let v = vlc {
                if active { v.mediaPlayer.audio?.isMuted = muted; v.mediaPlayer.play(); isPlaying = true }
                else { v.mediaPlayer.pause(); isPlaying = false; onSavePosition(v.current) }
                return
            }
            if !active && hdPlayer != nil { revertToHD() }   // 秒开中途滑走：留下高清那个，回来接着用
            guard let p = player else { if active { setup() }; return }
            if active, p.currentItem == nil || p.currentItem?.status == .failed { rebuild(); return }
            if active, shouldFastStart(p) {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                startFast(hd: p)
                return
            }
            if active {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                #if DEBUG
                logSwipeStart(p)
                #endif
                p.isMuted = muted; p.play(); isPlaying = true
                watchdog(p)
            } else {
                p.isMuted = true; p.pause(); isPlaying = false
                onSavePosition(p.currentTime().seconds)
            }
        }
    }

    // MARK: 手势（UIKit 宿主：起手定方向，竖向优先让给分页）

    private var gestures: some View {
        PlayerGestureView(
            onSingleTap: { togglePlay() },
            onDoubleTap: { _, _ in onDoubleTap?() },
            onLongPress: { pressing in
                if let v = vlc {
                    if pressing { v.setRate(2); rateBoost = true } else if rateBoost { v.setRate(Float(lockedRate)); rateBoost = false }
                    return
                }
                guard let p = player else { return }
                if pressing { p.rate = 2; rateBoost = true }
                else if rateBoost { p.rate = isPlaying ? Float(lockedRate) : 0; rateBoost = false }
            },
            onLongPressLock: { lockedRate = 2 },
            onLongPressUnlock: {
                lockedRate = 1; rateBoost = false
                if let v = vlc { v.setRate(1) } else { player?.rate = isPlaying ? 1 : 0 }
            },
            onSeekBegan: {
                guard duration > 0 else { return }
                if let v = vlc { current = v.current }
                else if let p = player { current = p.currentTime().seconds } else { return }
                holdAnchor = current
                seekPreview = current
                seeking = true
            },
            onSeekChanged: { dx, w in
                guard duration > 0, seeking else { return }
                seekPreview = max(0, min(duration, holdAnchor + dx / max(w, 1) * duration * 0.9))
                seekDelta = seekPreview - current
                requestPreview(seekPreview)
            },
            onSeekEnded: {
                #if DEBUG
                    #endif
                if seeking { seekTo(seekPreview); seeking = false; previewImage = nil }
            },
            verticalFirst: true,
            onSwipeLeft: onSwipeLeft.map { act in { swipeTracker?.end(); act() } },
            onSwipeRight: onSwipeRight.map { act in { swipeTracker?.end(); act() } },
            dragSeek: dragSeek,
            onSwipeDrag: { dx, dir in swipeTracker?.drag(dx, direction: dir) },
            onSwipeCancel: { swipeTracker?.cancel() }
        )
    }

    private var seekHUD: some View {
        VStack(spacing: 10) {
            Group {
                if let img = previewImage {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4).overlay(ProgressView().tint(.white))
                }
            }
            .frame(width: 196 * ui, height: 110 * ui)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Text(fmt(seekPreview)).font(.subheadline.weight(.bold).monospacedDigit())
                Text("/ " + fmt(duration)).font(.caption.monospacedDigit()).opacity(0.6)
                Text((seekDelta >= 0 ? "+" : "") + String(format: "%.0fs", seekDelta))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(seekDelta >= 0 ? Color.green : Color.orange)
            }
            .foregroundStyle(.white)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    private var progressBar: some View {
        let pos = seeking ? seekPreview : current
        let frac = duration > 0 ? max(0, min(1, pos / duration)) : 0
        // 不显示时间（拖动时预览气泡里有），只留细进度条
        return VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    // 平时半透明不挡画面（横滑全屏都能拖进度），拖动时才变实
                    Capsule().fill(.white.opacity(seeking ? 0.28 : 0.12)).frame(height: (seeking ? 6 : 2) * ui)
                    Capsule().fill(.white.opacity(seeking ? 1 : 0.4)).frame(width: g.size.width * frac, height: (seeking ? 6 : 2) * ui)
                    Circle().fill(.white.opacity(seeking ? 1 : 0.45)).frame(width: (seeking ? 15 : 6) * ui, height: (seeking ? 15 : 6) * ui)
                        .offset(x: max(0, g.size.width * frac - (seeking ? 7.5 : 3) * ui))
                }
                .frame(maxHeight: .infinity)
                .onAppear { barWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in barWidth = w }
            }
            .frame(height: 16 * ui)
            .padding(.horizontal, 16 * ui)
            // 拖动区：进度条往上多 20pt 好按，不往下占空白
            .padding(.top, 20 * ui)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        if !seeking { holdAnchor = current; seeking = true }
                        seekPreview = max(0, min(duration, holdAnchor + v.translation.width / max(barWidth, 1) * duration))
                        seekDelta = seekPreview - current
                        requestPreview(seekPreview)
                    }
                    .onEnded { _ in if seeking { seekTo(seekPreview); seeking = false; previewImage = nil } })
        }
    }

    // MARK: 播放

    /// 头部缓存文件：把播放终点钉在安全位置，播到这里会正常 ended，而不是卡在没数据的尾部
    private func makeItem(asset: AVAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        if let h = headEndSeconds, h > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: h, preferredTimescale: 600)
        }
        return item
    }

    /// 头部缓存播完 → 用在线流从同一时间点接上（一次性；接上后不再触发）
    @discardableResult
    private func continueFromRemote(_ p: AVPlayer) -> Bool {
        guard !continued, let remote = continuationURL else { return false }
        let start = headEndSeconds ?? p.currentTime().seconds
        // 预热好的播放器直接接管：图层里的 player 从 p 换成 np（都不是 nil，不重建 surface）
        if let np = nextPlayer, np.currentItem?.status == .readyToPlay {
            handOver(to: np, from: p, at: start, primed: true)
            return true
        }
        continued = true
        #if DEBUG
        ddWrite("DDHEAD continue remote(cold) at \(String(format: "%.1f", start))")
        #endif
        teardownPlayerOnly()
        let np = AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(remote)))
        np.automaticallyWaitsToMinimizeStalling = true
        player = np
        attachObservers(np)
        np.isMuted = muted
        np.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in np.play() }
        isPlaying = true
        watchdog(np)
        return true
    }

    /// 距接续点还有几秒时，先把在线流的播放器拉起来缓冲（静音、不显示），到点零等待接管
    private func primeContinuation() {
        guard !continued, nextPlayer == nil, let remote = continuationURL, let h = headEndSeconds, h > 0 else { return }
        // 整条已经下完（多数视频在播到接续点前就下完了）→ 直接读本地文件续播，
        // 本地 seek 是瞬时的，切换后不会再有等网络缓冲的卡顿
        let localFull = DYVideoCache.localURL(id)
        let src = localFull ?? remote
        let np = AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(src)))
        np.automaticallyWaitsToMinimizeStalling = true
        np.isMuted = true
        // 缓冲就绪后停住；接续点前后各留一点已缓冲数据，切换时 seek 是瞬时的
        np.seek(to: CMTime(seconds: max(0, h - 0.4), preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                np.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.nextPlayer === np { np.pause() } }
            }
        }
        nextOpacity = 0.01          // 极低透明度常驻：layer 一直在出帧，切换时只改透明度，不来不急建层
        nextPlayer = np
        nextPrimedAt = h
        #if DEBUG
        ddWrite("DDHEAD prime at \(String(format: "%.1f", h)) src=\(localFull != nil ? "local" : "remote")")
        #endif
    }

    /// 把画面和时间轴从旧 player 交接到新 player：新画面先叠上层亮相，再撤旧层，全程不断帧
    private func handOver(to np: AVPlayer, from old: AVPlayer, at start: Double, primed: Bool) {
        guard !continued else { return }
        continued = true
        #if DEBUG
        ddWrite("DDHEAD continue remote at \(String(format: "%.1f", start)) primed=\(primed)")
        #endif
        let wasPlaying = isPlaying
        np.isMuted = muted
        // 先把它精确定位到接续点（预热过的话这段是已缓冲区间，seek 基本瞬时），
        // seek 完成才让它亮相，避免露出预热时的错帧
        np.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                if wasPlaying { np.play() }
                self.nextOpacity = 1
                // 新画面已经在顶层播同一位置 → 把主 player 换过去（此时 layer 换绑不会露黑）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    if let t = self.timeToken { old.removeTimeObserver(t); self.timeToken = nil }
                    if let o = self.endObserver { NotificationCenter.default.removeObserver(o); self.endObserver = nil }
                    self.player = np
                    self.nextOpacity = 0
                    self.nextPlayer = nil
                    self.attachObservers(np)
                    self.isPlaying = wasPlaying
                    self.watchdog(np)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { old.replaceCurrentItem(with: nil) }
                }
            }
        }
    }

    private func setup() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_FORCE_VLC"] == "1" {
            if knownDuration > 0 { duration = knownDuration }
            startVLC(); return
        }
        #endif
        let pre = preparedPlayer?()
        #if DEBUG
        let preReady = pre?.currentItem?.status == .readyToPlay
        let preBuf = pre?.currentItem?.loadedTimeRanges.first.map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0
        #endif
        let asset = (pre?.currentItem?.asset as? AVURLAsset) ?? DYMedia.asset(url)
        let p = pre ?? AVPlayer(playerItem: makeItem(asset: asset))
        if let pre, let h = headEndSeconds, pre.currentItem?.forwardPlaybackEndTime.seconds ?? 0 <= 0 {
            pre.currentItem?.forwardPlaybackEndTime = CMTime(seconds: h, preferredTimescale: 600)
        }
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        if knownDuration > 0 { duration = knownDuration }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)
        imgGen = gen
        attachObservers(p)
        if let r = resumePosition, r > 1 { p.seek(to: CMTime(seconds: r, preferredTimescale: 600)) }
        if isActive, shouldFastStart(p) {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            startFast(hd: p)
            return
        }
        p.isMuted = !isActive || muted
        if isActive {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            p.play()
        }
        isPlaying = isActive
        if isActive { watchdog(p) }
        #if DEBUG
        if isActive {
            let t0 = Date()
            func probe(_ n: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if p.currentTime().seconds > 0.05 {
                        ddWrite("DDSTART \(id) local=\(url.isFileURL) pre=\(pre != nil) preReady=\(preReady) preBuf=\(String(format: "%.1f", preBuf))s q=\(quality ?? "-") 起播用时=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s 距启动=\(String(format: "%.2f", Date().timeIntervalSince(DDLaunch.t0)))s")
                    } else if n < 100 { probe(n + 1) }
                }
            }
            probe(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            ddWrite("DDPLAY \(id) active=\(isActive) engine=\(vlc == nil ? "AV" : "VLC") status=\(p.currentItem?.status.rawValue ?? -1) t=\(p.currentTime().seconds) err=\(String(describing: p.currentItem?.error))")
        }
        #endif
    }

    #if DEBUG
    /// 滑到这条时记一笔：滑入时缓冲了多少、是不是本地文件、后台缓存在下几条，以及多久真正动起来
    private func logSwipeStart(_ p: AVPlayer, fast: Bool = false) {
        let t0 = Date(), start = p.currentTime().seconds
        let it = p.currentItem
        let buf = it?.loadedTimeRanges.first.map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0
        let st = it?.status.rawValue ?? -1
        let local = (it?.asset as? AVURLAsset)?.url.isFileURL ?? false
        let dl = DYVideoCache.activeDownloads
        let th = ProcessInfo.processInfo.thermalState.rawValue   // 0 正常 1 微热 2 烫 3 很烫
        func probe(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard player === p else { return }
                if p.currentTime().seconds > start + 0.05 {
                    ddWrite("DDSWIPE \(id) 起播=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s fast=\(fast) local=\(local) status=\(st) buf=\(String(format: "%.1f", buf))s dl=\(dl) th=\(th) q=\(quality ?? "-")")
                } else if n < 400 { probe(n + 1) }
                else { ddWrite("DDSWIPE \(id) 20s 未起播 local=\(local) status=\(st) buf=\(String(format: "%.1f", buf))s dl=\(dl)") }
            }
        }
        probe(0)
    }
    #endif

    // MARK: 秒开（低码率先放，高清缓冲好后无缝接管）

    /// 冷：没就绪，或就绪了但缓冲不到 1 秒。本地文件 / 没有低码率档 / VLC 接管中都不走秒开
    private func shouldFastStart(_ p: AVPlayer) -> Bool {
        // 默认关：实测低清也要 1–2s 才起播、还要两路解码陪跑发热；直连 CDN 后冷启动本身快了 ~1s。菜单里可开
        guard UserDefaults.standard.bool(forKey: "douyin_faststart_v1"), fastURL != nil, vlc == nil, hdPlayer == nil, !url.isFileURL, let it = p.currentItem else { return false }
        if (it.asset as? AVURLAsset)?.url.isFileURL == true { return false }
        let buf = it.loadedTimeRanges.first.map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0
        return it.status != .readyToPlay || buf < 1
    }

    private func startFast(hd: AVPlayer) {
        guard let f = fastURL else { return }
        detachObservers()
        let resume = hd.currentTime()
        // 高清：静音陪跑（播着 AVPlayer 才会一直往前缓冲），放在上层几乎透明
        hd.isMuted = true
        hd.automaticallyWaitsToMinimizeStalling = true
        hd.currentItem?.preferredForwardBufferDuration = 0
        hd.play()
        hdPlayer = hd; hdVisible = false
        // 低清：拿到一点数据就开播
        let low = AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(f)))
        low.automaticallyWaitsToMinimizeStalling = false
        if resume.seconds > 1 { low.seek(to: resume) }
        player = low
        attachObservers(low)
        low.isMuted = muted
        low.play()
        isPlaying = true
        fastT0 = Date()
        #if DEBUG
        logSwipeStart(low, fast: true)
        #endif
        watchdog(low)
        pollUpgrade(low, hd, 0)
    }

    /// 高清在 target 之后已缓冲多少秒（target 不在已缓冲区间里 → 0）
    private func bufferedAhead(_ it: AVPlayerItem, from target: Double) -> Double {
        for v in it.loadedTimeRanges {
            let r = v.timeRangeValue
            let s = r.start.seconds, e = (r.start + r.duration).seconds
            if target >= s - 0.05 && target <= e { return e - target }
        }
        return 0
    }

    private func pollUpgrade(_ low: AVPlayer, _ hd: AVPlayer, _ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard isActive, player === low, hdPlayer === hd else { return }
            guard let it = hd.currentItem, it.status != .failed else { cancelUpgrade(); return }
            let t = low.currentTime().seconds
            if it.status == .readyToPlay, !seeking, bufferedAhead(it, from: t + 0.1) >= 1.5 {
                swapToHD(low, hd)
            } else if n < 160 {
                pollUpgrade(low, hd, n + 1)      // 最多等 40 秒；网太慢就一直看低清，不卡
            } else {
                cancelUpgrade()
            }
        }
    }

    private func swapToHD(_ low: AVPlayer, _ hd: AVPlayer) {
        let target = low.currentTime() + CMTime(seconds: 0.08, preferredTimescale: 600)
        hd.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { done in
            DispatchQueue.main.async {
                guard done, isActive, player === low, hdPlayer === hd else { return }
                hd.rate = isPlaying ? max(low.rate, 1) : 0
                // 等高清出两帧画面再盖上去，声音同时交接
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard player === low, hdPlayer === hd else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { hdVisible = true }
                    hd.isMuted = muted
                    low.isMuted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { finishUpgrade(low, hd) }
                }
            }
        }
    }

    /// 底层也换成高清（上层还盖着，所以不会黑一下），再拆掉低清和上层
    private func finishUpgrade(_ low: AVPlayer, _ hd: AVPlayer) {
        guard player === low, hdPlayer === hd else { return }
        detachObservers()
        low.pause(); low.replaceCurrentItem(with: nil)
        player = hd
        attachObservers(hd)
        #if DEBUG
        ddWrite("DDUPGRADE \(id) 高清接管=\(String(format: "%.2f", Date().timeIntervalSince(fastT0)))s")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if hdPlayer === hd { hdPlayer = nil; hdVisible = false }
        }
    }

    /// 秒开中途滑走：丢掉低清，把高清（停在同一时间点）留作这一页的播放器
    private func revertToHD() {
        guard let hd = hdPlayer, let low = player else { return }
        let t = low.currentTime()
        detachObservers()
        low.pause(); low.replaceCurrentItem(with: nil)
        hd.pause(); hd.isMuted = true
        hd.seek(to: t)
        player = hd
        attachObservers(hd)
        hdPlayer = nil; hdVisible = false
    }

    private func cancelUpgrade() {
        guard let hd = hdPlayer else { return }
        hd.pause(); hd.replaceCurrentItem(with: nil)
        hdPlayer = nil; hdVisible = false
    }

    private func detachObservers() {
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        failObserver?.invalidate(); failObserver = nil
    }

    /// 无声排查：起播 3 秒后把「这条视频到底有没有音轨」和当时的静音/音量/输出状态记进 ddlog.txt（DDAUDIO）。
    /// audioTracks=0 → 选到的档位本身没有声音；有音轨但 muted=true / volume=0 → 播放器状态问题；
    /// 都正常但 sysVol=0 或 route 不对 → 系统音量 / 输出设备问题。
    private func logAudio(_ p: AVPlayer) {
        DDAudioGuard.install()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard isActive, player === p, let item = p.currentItem else { return }
            let itemAudio = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
            let enabled = itemAudio.filter(\.isEnabled).count
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
            let src = (item.asset as? AVURLAsset)?.url
            let head = "DDAUDIO \(id)"
            let state = "itemAudio=\(itemAudio.count) enabled=\(enabled) muted=\(p.isMuted) volume=\(p.volume) rate=\(p.rate) "
                + "t=\(String(format: "%.1f", p.currentTime().seconds)) status=\(item.status.rawValue) userMuted=\(muted) "
                + "sysVol=\(session.outputVolume) route=\(route.isEmpty ? "-" : route) \(DDAudioGuard.sessionState) "
                + "appActive=\(DDPlayback.shared.appIsActive) "
                + "local=\(src?.isFileURL ?? false) host=\(src?.host ?? "-") q=\(quality ?? "-")"
            let asset = item.asset
            Task {
                let n = (try? await asset.loadTracks(withMediaType: .audio).count) ?? -1
                DYLiveModel.log("\(head) \(n == 0 ? "NO_AUDIO_TRACK " : "")audioTracks=\(n) \(state)")
            }
        }
    }

    /// 起播看门狗：当前屏 6 秒还没走（网络抖 / 预加载的 item 失效），重建播放项再来一次
    private func watchdog(_ p: AVPlayer) {
        logAudio(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard isActive, isPlaying, player === p, !seeking, vlc == nil else { return }
            let stuck = p.currentItem == nil || p.currentItem?.status == .failed || p.currentTime().seconds < 0.1
            guard stuck else { return }
            recover()
        }
    }

    /// 起播失败的统一出路：先换备用地址重建一次，还不行交给 VLC
    private func recover() {
        if avRetried { startVLC() } else { avRetried = true; rebuild() }
    }

    private func rebuild() {
        cancelUpgrade()
        teardownPlayerOnly()
        #if DEBUG
        ddWrite("DDREBUILD \(id) alt=\(altURL != nil)")
        #endif
        let item = makeItem(asset: DYMedia.asset(altURL ?? url))
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        attachObservers(p)
        p.isMuted = muted
        p.play()
        isPlaying = true
        watchdog(p)
    }

    /// 失焦/切后台：立即暂停并释放音频会话，声音一秒都不该多留
    private func pauseForBackground() {
        if DDPlayback.bgPlay { return }
        #if DEBUG
        ddWrite("DDBG pauseForBackground id=\(id) vlc=\(vlc != nil) av=\(player != nil) rate=\(player?.rate ?? -9) t=\(String(format: "%.1f", player?.currentTime().seconds ?? -1)) active=\(isActive)")
        #endif
        if let v = vlc, v.isPlaying {
            v.mediaPlayer.pause(); isPlaying = false
            onSavePosition(v.current)
        }
        if let p = player, p.rate != 0 {
            p.pause(); isPlaying = false
            onSavePosition(p.currentTime().seconds)
        }
        hdPlayer?.pause()
        #if DEBUG
        ddWrite("DDBG pauseForBackground id=\(id) vlc=\(vlc != nil) av=\(player != nil) rate=\(player?.rate ?? -9) t=\(String(format: "%.1f", player?.currentTime().seconds ?? -1)) active=\(isActive)")
        #endif
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 回到前台：还是当前条就接着播
    private func resumeAfterBackground() {
        #if DEBUG
        ddWrite("DDBG resumeAfterBackground id=\(id) active=\(isActive) av=\(player != nil) t=\(String(format: "%.1f", player?.currentTime().seconds ?? -1))")
        #endif
        guard isActive else { return }
        if let v = vlc {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            v.mediaPlayer.audio?.isMuted = muted
            v.mediaPlayer.play(); isPlaying = true
            return
        }
        if let p = player {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            p.play(); isPlaying = true
            hdPlayer?.play()      // 秒开中：高清继续静音陪跑缓冲
        }
    }

    /// VLC 软解接管（AVPlayer 两次起不来 / 状态 failed）
    private func startVLC() {
        teardownPlayerOnly()
        let v = VLCPlayerController()
        if knownDuration > 0 { v.setKnownDuration(knownDuration) }
        v.onProgress = { pos in
            if !seeking { current = pos }
            if !firstFrame, pos > 0.02 { firstFrame = true }
            refreshNowPlaying(pos)
            if isActive { DDNowPlaying.id = id; DDNowPlaying.time = pos }
            dmClock.sync(pos, playing: v.isPlaying && !seeking, rate: Double(v.mediaPlayer.rate))
            if !rateBoost, v.isPlaying, v.mediaPlayer.rate != Float(lockedRate) { v.setRate(Float(lockedRate)) }
            if v.duration > 0 { duration = v.duration }
        }
        v.onEnd = { [weak v] in
            DispatchQueue.main.async {
                if let onEnded { onEnded() } else if let v, isActive { v.seekTo(0); v.mediaPlayer.play() }
            }
        }
        v.play(url: url, autoplay: isActive, headers: DYMedia.headers)
        vlc = v
        #if DEBUG
        ddWrite("DDVLC takeover \(id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { ddWrite("DDVLC \(id) t=\(v.current) playing=\(v.isPlaying)") }
        #endif
        isPlaying = isActive
    }

    private func attachObservers(_ p: AVPlayer) {
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
            MainActor.assumeIsolated {
                if !seeking { current = t.seconds }
                if !firstFrame, t.seconds > 0.02 { firstFrame = true }
                if isActive { DDNowPlaying.id = id; DDNowPlaying.time = t.seconds }
                if isActive, p.rate > 0 { DDAudioGuard.reassert(id) }
                dmClock.sync(t.seconds, playing: p.rate > 0 && !seeking, rate: Double(p.rate))
                refreshNowPlaying(t.seconds)
                // 锁定倍速：play()/换播放器都会回到 1 倍，每 0.25s 拉回选定速度
                if !rateBoost, p.rate > 0, p.rate != Float(lockedRate) { p.rate = Float(lockedRate) }
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
                // 头部缓存 → 在线流：提前预热，到点直接交接（不等 ended，避免尾部没数据干等）
                if let h = headEndSeconds, h > 0, !continued {
                    if nextPlayer == nil, t.seconds > h - 4 { primeContinuation() }
                    if t.seconds >= h - 0.12, let np = nextPlayer, np.currentItem?.status == .readyToPlay {
                        DispatchQueue.main.async { if !continued { handOver(to: np, from: p, at: h, primed: true) } }
                    }
                    // 兜底：预估接续点比真实可播长度乐观时，头部数据会先耗尽（rate 掉 0、时间不动），
                    // 这时候立刻交接，不让画面干等
                    if isPlaying, !seeking, p.rate == 0, let np = nextPlayer, np.currentItem?.status == .readyToPlay {
                        stalledTicks += 1
                        if stalledTicks >= 4 {
                            let at = max(t.seconds, 0.5)
                            DispatchQueue.main.async { if !continued { handOver(to: np, from: p, at: at, primed: true) } }
                        }
                    } else {
                        stalledTicks = 0
                    }
                }
            }
        }
        failObserver = p.currentItem?.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard isActive, isPlaying, player === p, vlc == nil else { return }
                #if DEBUG
                ddWrite("DDFAILFAST \(id) \(item.error?.localizedDescription ?? "-")")
                #endif
                recover()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: p.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                if continueFromRemote(p) { return }
                if let onEnded { onEnded() } else { p.seek(to: .zero); p.play() }   // 抖音同款：单条循环
            }
        }
    }

    private func teardownPlayerOnly() {
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    // MARK: 锁屏 / 控制中心播放控件（播放暂停、前进后退 10 秒、进度条、倍速）

    private func bindRemote() {
        let c = MPRemoteCommandCenter.shared()
        // 没开「后台播放」就不要锁屏播放窗口：关掉所有控件并清掉「正在播放」
        guard DDPlayback.bgPlay else {
            [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.skipForwardCommand, c.skipBackwardCommand,
             c.changePlaybackPositionCommand, c.changePlaybackRateCommand].forEach { $0.removeTarget(nil); $0.isEnabled = false }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            DDRemoteOwner.id = ""
            return
        }
        DDRemoteOwner.id = id
        let now = { vlc?.current ?? player?.currentTime().seconds ?? current }
        func on(_ cmd: MPRemoteCommand, _ f: @escaping (MPRemoteCommandEvent) -> Void) {
            cmd.removeTarget(nil); cmd.isEnabled = true
            cmd.addTarget { e in DispatchQueue.main.async { f(e) }; return .success }
        }
        on(c.playCommand) { _ in if !isPlaying { togglePlay() } }
        on(c.pauseCommand) { _ in if isPlaying { togglePlay() } }
        on(c.togglePlayPauseCommand) { _ in togglePlay() }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { _ in seekTo(min(max(duration, 1), now() + 10)) }
        on(c.skipBackwardCommand) { _ in seekTo(max(0, now() - 10)) }
        on(c.changePlaybackPositionCommand) { e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { seekTo(e.positionTime) }
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2]
        on(c.changePlaybackRateCommand) { e in
            if let e = e as? MPChangePlaybackRateCommandEvent { lockedRate = Double(e.playbackRate) }
        }
        lastNowPlaying = -10
        refreshNowPlaying(now())
    }

    /// 约每秒刷新一次锁屏上的标题 / 进度 / 速度
    private func refreshNowPlaying(_ t: Double) {
        guard isActive, abs(t - lastNowPlaying) >= 1 else { return }
        lastNowPlaying = t
        // 开关中途被切换：开了就补绑控件，关了就清掉
        if DDPlayback.bgPlay != (DDRemoteOwner.id == id) { bindRemote(); if !DDPlayback.bgPlay { return } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title.isEmpty ? "DouDuo" : title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: t,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? lockedRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
    }

    private func togglePlay() {
        defer { lastNowPlaying = -10; refreshNowPlaying(vlc?.current ?? player?.currentTime().seconds ?? current) }   // 锁屏上的播放/暂停状态马上跟上
        if let v = vlc { v.togglePlay(); isPlaying = v.isPlaying; dmClock.sync(v.current, playing: v.isPlaying, rate: 1); return }
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
        dmClock.sync(p.currentTime().seconds, playing: isPlaying, rate: Double(max(p.rate, 1)))
    }

    private func seekTo(_ pos: Double) {
        dmClock.sync(pos, playing: isPlaying, rate: rateBoost ? 2 : 1)
        if let v = vlc { v.seekTo(pos); current = pos; return }
        let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        hdPlayer?.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        current = pos
    }

    private func requestPreview(_ time: Double) {
        guard let gen = imgGen else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastPreviewAt > 0.15 else { return }
        lastPreviewAt = now
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: time, preferredTimescale: 600))]) { _, cg, _, result, _ in
            if result == .succeeded, let cg {
                let img = UIImage(cgImage: cg)
                DispatchQueue.main.async { if seeking { previewImage = img } }
            }
        }
    }

    private func teardown() {
        cancelUpgrade()
        if let v = vlc { onSavePosition(v.current); v.onEnd = nil; v.onProgress = nil; v.stop(); vlc = nil }
        if let p = player { onSavePosition(p.currentTime().seconds) }
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let np = nextPlayer { np.pause(); np.replaceCurrentItem(with: nil); nextPlayer = nil }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        imgGen?.cancelAllCGImageGeneration(); imgGen = nil
        isPlaying = false
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); let h = t / 3600, m = t % 3600 / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}


#if DEBUG
enum DDLaunch { static let t0 = Date() }
/// 调试：播放状态写进 Documents/ddlog.txt，真机上用 devicectl copy 拉回来看
private let ddWriteQueue = DispatchQueue(label: "douduo.ddlog", qos: .utility)
func ddWrite(_ s: String) {
    // 时间戳在调用点取，文件读写挪到后台串行队列：顺序不变，不再在主线程上开关文件
    let line = "\(Date()) \(s)\n"
    ddWriteQueue.async {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddlog.txt")
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: u) }
    }
}
#endif

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var fillWidth: Bool = true
    /// 画面层第一次有帧可显示时回调（先按同向规则定好铺满方式再回调，不会先小后跳）
    var onReady: (() -> Void)? = nil
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView(player: player)
        v.fillWidth = fillWidth
        v.onReady = onReady
        // 初始用 fit；真正的铺满由 applyGravity 按「是否同向」决定（surface 首帧前隐藏，看不到这中间态）
        v.playerLayer.videoGravity = .resizeAspect
        v.watchSize()
        return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.detached == nil, uiView.playerLayer.player !== player { uiView.playerLayer.player = player; uiView.watchSize() }
        uiView.fillWidth = fillWidth
        uiView.onReady = onReady
        uiView.applyGravity()
    }
}

final class PlayerUIView: UIView {
    var fillWidth = true
    var onReady: (() -> Void)?
    private var readyObs: NSKeyValueObservation?
    /// 后台播放：进后台前把 player 从画面层摘下，系统才不会因「视频不可见」把声音一起停掉；回前台再挂回
    var detached: AVPlayer?
    private var bgObs: [NSObjectProtocol] = []
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        let nc = NotificationCenter.default
        bgObs = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard DDPlayback.bgPlay, let self, let p = self.playerLayer.player else { return }
                p.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                self.detached = p; self.playerLayer.player = nil
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let p = self.detached else { return }
                self.playerLayer.player = p; self.detached = nil
            },
        ]
        readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.applyGravity(); self?.onReady?() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { bgObs.forEach(NotificationCenter.default.removeObserver) }

    /// 自适应（仅同向时）：竖屏看竖屏铺满宽度；横屏看横屏铺满高度。竖屏看横屏保持原样。
    /// presentationSize 要等 readyToPlay 才有值，所以 layoutSubviews + KVO 都刷一次。
    override func layoutSubviews() {
        super.layoutSubviews()
        applyGravity()
    }
    private var sizeObs: NSKeyValueObservation?
    func watchSize() {
        sizeObs = playerLayer.player?.currentItem?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyGravity() }
        }
    }
    func applyGravity() {
        guard let size = playerLayer.player?.currentItem?.presentationSize, size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let video = size.width / size.height, screen = bounds.width / bounds.height
        // 「自动铺满宽度」只在视频和屏幕同向时铺满（竖屏看竖屏 / 横屏看横屏）；
        // 竖屏看横屏保持完整画面，不裁掉两侧。
        let sameOrientation = (video < 1) == (screen < 1)
        let crop = 1 - min(video, screen) / max(video, screen)
        let g: AVLayerVideoGravity = (fillWidth && sameOrientation) ? .resizeAspectFill : .resizeAspect
        #if DEBUG
        if playerLayer.videoGravity != g {
            ddWrite("DDGRAVITY video=\(String(format: "%.2f", video)) screen=\(String(format: "%.2f", screen)) bounds=\(bounds.size) fill=\(fillWidth) same=\(sameOrientation) crop=\(String(format: "%.2f", crop)) -> \(g == .resizeAspectFill ? "FILL" : "FIT")")
        }
        #endif
        if playerLayer.videoGravity != g { playerLayer.videoGravity = g }
    }
}

