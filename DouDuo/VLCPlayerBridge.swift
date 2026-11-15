import SwiftUI
import AVKit
import AVFoundation
// VLC 软解兜底（来自 無為 影库播放器）：AVPlayer 解不了 / 起播失败时接管。依赖 tylerjonesio/vlckit-spm。
import VLCKitSPM

// MARK: - VLC 播放器 UIKit 包装（软解 HEVC 等苹果硬解不认的格式）

struct VLCPlayerSurface: UIViewRepresentable {
    let controller: VLCPlayerController
    var fillWidth: Bool = true
    func makeUIView(context: Context) -> VLCPlayerUIView {
        let v = VLCPlayerUIView()
        v.controller = controller
        v.fillWidth = fillWidth
        controller.boundSurface = v
        guard !controller.blocksSurfaceAttachment else { return v }
        controller.mediaPlayer.drawable = v
        controller.drawableAttached()   // drawable 就绪后才真正 play，避免「有声无画」
        return v
    }
    /// 页面被拆掉时把 drawable 摘掉：直播切房间后旧页的视图已离屏，不能让新流画到它上面
    static func dismantleUIView(_ uiView: VLCPlayerUIView, coordinator: ()) {
        if let c = uiView.controller, c.mediaPlayer.drawable as? UIView === uiView { c.mediaPlayer.drawable = nil }
        if uiView.controller?.boundSurface === uiView { uiView.controller?.boundSurface = nil }
    }
    func updateUIView(_ uiView: VLCPlayerUIView, context: Context) {
        // ⚠️ 不要每次 updateUIView 都重设 drawable（@State 0.25s 变一次会反复触发，
        // 频繁 attach/detach 视频输出 → 画面冻结）。仅在 drawable 丢失时补挂。
        controller.boundSurface = uiView
        guard !controller.blocksSurfaceAttachment else { return }
        if controller.mediaPlayer.drawable == nil {
            controller.mediaPlayer.drawable = uiView
            controller.drawableAttached()
        }
        uiView.controller = controller
        uiView.fillWidth = fillWidth
        uiView.applyFill()   // videoSize 要播起来才有，靠 0.25s 刷新补上
    }
}

final class VLCPlayerUIView: UIView {
    weak var controller: VLCPlayerController?
    var fillWidth = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 自适应（仅同向时）：竖屏看竖屏按宽度铺满、横屏看横屏按高度铺满。竖屏看横屏保持完整画面。
    override func layoutSubviews() {
        super.layoutSubviews()
        applyFill()
    }
    func applyFill() {
        guard let mp = controller?.mediaPlayer, bounds.width > 1, bounds.height > 1 else { return }
        let vs = mp.videoSize
        guard vs.width > 1, vs.height > 1 else { layer.transform = CATransform3DIdentity; return }
        // VLC 按等比 fit 渲染（必有黑边）。把渲染层放大到「刚好铺满」即可：竖屏视频按宽度、横屏按高度，
        // 超出屏幕部分看不见（居中缩放，裁切对称）。
        let video = vs.width / vs.height, screen = bounds.width / bounds.height
        // 只在视频和屏幕同向时放大：竖屏看竖屏铺满宽度、横屏看横屏铺满高度；竖屏看横屏保持原样
        let sameOrientation = (video < 1) == (screen < 1)
        let s = (fillWidth && sameOrientation) ? max(screen / video, video / screen) : 1
        let t = CATransform3DMakeScale(s, s, 1)
        if !CATransform3DEqualToTransform(layer.transform, t) { layer.transform = t }
    }
}

// MARK: - VLC 播放控制器（管理 VLCMediaPlayer 生命周期 + 进度回调）

@MainActor
final class VLCPlayerController: NSObject, VLCMediaPlayerDelegate, ObservableObject {
    private(set) var mediaPlayer: VLCMediaPlayer
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var videoSize: CGSize = .zero

    var onProgress: ((Double) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?
    var onStopped: (() -> Void)?
    var onError: (() -> Void)?
    private var seekTarget: Double?       // seek 后短暂屏蔽回调防抖
    private var lastReported: Double = 0  // 上次回调值，防回退抖动
    private var pendingURL: URL?          // 等 drawable 就绪再 play
    private var pendingAutoplay = false
    /// 前台静音偏好。换媒体时音轨可能还没出现，play 时再写一次。
    var outputMuted = false
    /// 后台拆过音频输出后，要等音轨重新加上再取消静音。
    private var restoreAudio = false
    private var audioReopenID = 0
    /// SwiftUI 还拿着的渲染层。stop 之后 libvlc 的 nsobject 可能已空，drawable 读出来是 nil。
    weak var boundSurface: UIView?
    /// 新媒体已经装上之后才计启动超时。stop 还没完成时不能开始扣线路。
    var onMediaAssigned: (() -> Void)?
    /// stop/换流之后，已经排队的 VLC 回调不能再改当前这一路。
    private let callbackEpoch = VLCCallbackEpoch()
    /// 播放线程上的最近一次时钟回调。不能等主线程，后台出声时主线程任务会被推迟。
    private let advanceClock = VLCAdvanceClock()
    /// 只有这只播放器的回调可以改状态。旧实例在换代后被拒绝。
    private let activePlayer = VLCActivePlayer()
    private var replacementToken = 0
    private var replacement: VLCReplacement?
    private var stopInFlight = false
    private var stopWait: Task<Void, Never>?
    /// 这次换流已经调用 play，但 libVLC 仍可能再报一次旧输入的 stopped。只允许同一 token 再开一次。
    private var replayIfStopped: VLCReplacement?
    /// replace/stop 换代后，已经排队的那一次启动不能再碰播放器。
    private var pendingStartEpoch: Int?
    /// 当前 play 属于哪一次换流。短视频直接 play 时为空，迟到的 stopped 不会重开它。
    private var pendingOwned: VLCReplacement?

    override init() {
        let player = Self.makePlayer()
        mediaPlayer = player
        super.init()
        activePlayer.adopt(player, armStaleLog: false)
        mediaPlayer.delegate = self
        mediaPlayer.scaleFactor = 0  // 适应窗口
    }

    /// 闹钟打断后的这一只 VLC 已无法再启动。先只停这一只；旧实例离开渲染层并在后台释放之后，才接上唯一的新实例。
    var onInterruptionPlayerReady: (() -> Void)?
    var onInterruptionRebuildFailed: (() -> Void)?
    private var interruptionRebuild = false
    private var handoffInFlight = false
    private var handoffID = 0
    var blocksSurfaceAttachment: Bool { handoffInFlight }

    func rebuildPlayerAfterInterruption() {
        guard !interruptionRebuild, !handoffInFlight else { return }
        interruptionRebuild = true
        callbackEpoch.bump()
        replacementToken += 1
        stopWait?.cancel()
        stopWait = nil
        replacement = nil
        replayIfStopped = nil
        pendingStartEpoch = nil
        pendingOwned = nil
        pendingURL = nil
        pendingAutoplay = false
        restoreAudio = false
        audioReopenID &+= 1
        isPlaying = false
        #if DEBUG
        ddWrite("DDLIVE_TRACE PLAYER-REBUILD epoch=\(callbackEpoch.current)")
        #endif
        if mediaPlayer.media == nil || mediaPlayer.state == .stopped {
            Task { @MainActor in self.installFreshPlayer() }
            return
        }
        stopInFlight = true
        mediaPlayer.stop()
        let epoch = callbackEpoch.current
        let limit = DYLivePlaybackGate.stopCompletionLimit
        stopWait = Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            guard interruptionRebuild, epoch == callbackEpoch.current else { return }
            interruptionRebuild = false
            stopInFlight = false
            #if DEBUG
            ddWrite("DDLIVE_TRACE PLAYER-REBUILD-FAILED")
            #endif
            let failed = onInterruptionRebuildFailed
            onInterruptionPlayerReady = nil
            onInterruptionRebuildFailed = nil
            failed?()
        }
    }

    func cancelInterruptionRebuild() {
        interruptionRebuild = false
        handoffInFlight = false
        handoffID &+= 1
        onInterruptionPlayerReady = nil
        onInterruptionRebuildFailed = nil
    }

    /// 旧播放器先离开 drawable 和 delegate。新实例立刻成为唯一回调主人。
    /// 后台释放可以一直不返回；画面和播放不在等它。
    private func installFreshPlayer() {
        guard interruptionRebuild, !handoffInFlight else { return }
        interruptionRebuild = false
        handoffInFlight = true
        stopWait?.cancel()
        stopWait = nil
        stopInFlight = false
        activePlayer.suspendAcceptance()
        let retired = mediaPlayer
        retired.delegate = nil
        retired.drawable = nil
        handoffID &+= 1
        let id = handoffID
        let release = VLCPlayerRelease()
        release.player = retired
        let player = Self.makePlayer()
        mediaPlayer = player
        activePlayer.adopt(player, armStaleLog: true)
        player.delegate = self
        player.scaleFactor = 0
        #if DEBUG
        ddWrite("DDLIVE_TRACE PLAYER-RETIRED")
        #endif
        DispatchQueue.global(qos: .userInitiated).async {
            release.player = nil
        }
        Task { @MainActor in
            self.completeHandoff(id: id, player: player)
        }
    }

    /// 下一轮才把当前可见的渲染层交给新实例。播放再延后一轮，避免和旧实例的释放挤在同一次调用里。
    private func completeHandoff(id: Int, player: VLCMediaPlayer) {
        guard handoffInFlight, id == handoffID, mediaPlayer === player else { return }
        if let surface = boundSurface, surface.window != nil {
            player.drawable = surface
        }
        handoffInFlight = false
        #if DEBUG
        ddWrite("DDLIVE_TRACE PLAYER-NEW drawable=\(player.drawable == nil ? 0 : 1) epoch=\(callbackEpoch.current)")
        #endif
        let ready = onInterruptionPlayerReady
        onInterruptionPlayerReady = nil
        onInterruptionRebuildFailed = nil
        Task { @MainActor in
            guard self.handoffID == id, self.mediaPlayer === player, !self.handoffInFlight, !self.interruptionRebuild else { return }
            ready?()
        }
    }

    private static func makePlayer() -> VLCMediaPlayer {
        // 开 VideoToolbox 硬件解码 + 网络缓存调优，避免 h264/hevc 软解卡顿（一卡一卡）
        let options: [String] = [
            "--codec=videotoolbox,avcodec",   // 优先 VideoToolbox 硬解，失败再回退软解
            "--avcodec-hw=videotoolbox",       // 强制 avcodec 走硬件加速
            "--network-caching=1500",          // 网络流缓存 1.5s，抗抖动
            "--file-caching=1500",
            "--clock-jitter=0",                // 关时钟抖动补偿
            "--clock-synchro=0"
            // ⚠️ 不要加 --no-drop-late-frames / --no-skip-frames：解码一跟不上就死等 → 进度卡住不走。
            // 默认丢帧才能保持进度持续推进。
        ]
        return VLCMediaPlayer(options: options)
    }

    /// 设 media 但**不立即 play**——必须等 VLCPlayerSurface 把 drawable 挂上后
    /// 再由 drawableAttached() 触发，否则 VLC 解码无视频输出目标 → 有声无画。
    func play(url: URL, autoplay: Bool = true, headers: [String: String] = [:], cachingMs: Int32 = 1500, replacementOwner: Int? = nil) {
        if handoffInFlight || interruptionRebuild { return }
        callbackEpoch.bump()
        let epoch = callbackEpoch.current
        pendingStartEpoch = nil
        replayIfStopped = nil
        pendingOwned = replacementOwner.map { VLCReplacement(url: url, headers: headers, cachingMs: cachingMs, token: $0) }
        // 状态仍是 stopped/ended/error 时，同步 play 会打在还没拆完的旧输入上。
        // 这次启动只认自己的 epoch 和换流 token，不靠 isPlaying 还保持为 true。
        let deferStart = autoplay && [.stopped, .ended, .error].contains(mediaPlayer.state)
        if deferStart { pendingStartEpoch = epoch }
        let media = VLCMedia(url: url)
        // 抖音 CDN 不带浏览器 UA + Referer 会 403
        if let ua = headers["User-Agent"] { media.addOption(":http-user-agent=\(ua)") }
        if let ref = headers["Referer"] { media.addOption(":http-referrer=\(ref)") }
        // 逐 media 再声明一次硬解，确保 VideoToolbox 生效
        media.addOption(":avcodec-hw=videotoolbox")
        media.addOption(":codec=videotoolbox,avcodec")
        media.addOption(":network-caching=\(cachingMs)")
        media.addOption(":live-caching=\(cachingMs)")
        // 换视频必须清掉上个流的进度/尺寸，否则单调防抖会把新流前几十秒都吞掉。
        lastReported = 0; seekTarget = nil; current = 0; duration = 0; videoSize = .zero
        mediaPlayer.media = media
        pendingURL = url
        pendingAutoplay = autoplay
        isPlaying = autoplay
        mediaPlayer.audio?.isMuted = outputMuted
        if mediaPlayer.drawable == nil, let surface = boundSurface, surface.window != nil {
            mediaPlayer.drawable = surface
        }
        // ⚠️ drawable 已经在（复用同一个渲染层）时必须立刻 play：
        // 只靠 drawableAttached() 的话，stop() 之后再播会永远等不到回调 → 有声无画 / 完全不出画
        if mediaPlayer.drawable != nil, autoplay {
            pendingURL = nil
            if deferStart {
                let owner = replacementOwner
                #if DEBUG
                ddWrite("DDLIVE_TRACE START-SCHEDULED epoch=\(epoch) token=\(replacementToken) state=\(mediaPlayer.state.rawValue)")
                #endif
                Task { @MainActor in
                    #if DEBUG
                    ddWrite("DDLIVE_TRACE START-ENTERED epoch=\(epoch) now=\(callbackEpoch.current) pending=\(pendingStartEpoch ?? -1) token=\(owner ?? -1) current=\(replacementToken)")
                    #endif
                    if pendingStartEpoch != epoch {
                        #if DEBUG
                        ddWrite("DDLIVE_TRACE START-REJECTED category=pending-start epoch=\(epoch) pending=\(pendingStartEpoch ?? -1)")
                        #endif
                        return
                    }
                    if epoch != callbackEpoch.current {
                        #if DEBUG
                        ddWrite("DDLIVE_TRACE START-REJECTED category=callback-epoch epoch=\(epoch) now=\(callbackEpoch.current)")
                        #endif
                        return
                    }
                    if let owner, owner != replacementToken {
                        #if DEBUG
                        ddWrite("DDLIVE_TRACE START-REJECTED category=replacement-token token=\(owner) current=\(replacementToken)")
                        #endif
                        return
                    }
                    pendingStartEpoch = nil
                    commitOwnedPlay(path: "deferred")
                }
            } else {
                pendingStartEpoch = nil
                commitOwnedPlay(path: "sync")
            }
        } else if deferStart {
            pendingStartEpoch = nil
            #if DEBUG
            ddWrite("DDLIVE_TRACE START-REJECTED category=other epoch=\(epoch) token=\(replacementToken)")
            #endif
        }
        onMediaAssigned?()
    }

    /// 真正调用 libVLC play 之前才记住这一次换流。先换代，装媒体时已经排队的 stopped 不能用掉这一次重开。
    private func commitOwnedPlay(path: String = "sync") {
        callbackEpoch.bump()
        if let owned = pendingOwned, owned.token == replacementToken {
            replayIfStopped = owned
        }
        isPlaying = true
        #if DEBUG
        let before = mediaPlayer.state.rawValue
        ddWrite("DDLIVE_TRACE PLAY-INVOKED path=\(path) epoch=\(callbackEpoch.current) token=\(replacementToken) before=\(before)")
        #else
        _ = path
        #endif
        mediaPlayer.play()
        #if DEBUG
        ddWrite("DDLIVE_TRACE PLAY-RETURNED path=\(path) epoch=\(callbackEpoch.current) token=\(replacementToken) before=\(before) after=\(mediaPlayer.state.rawValue)")
        #endif
    }

    /// 换成新的直播媒体。正在拆旧流时只记住这一次请求，等状态落到 stopped/error 再 play。
    func replace(url: URL, headers: [String: String] = [:], cachingMs: Int32 = 1500) {
        if handoffInFlight || interruptionRebuild { return }
        replacementToken += 1
        replayIfStopped = nil
        pendingStartEpoch = nil
        pendingOwned = nil
        let job = VLCReplacement(url: url, headers: headers, cachingMs: cachingMs, token: replacementToken)
        let step = DYLivePlaybackGate.mediaReplacement(state: gateState(), stopInFlight: stopInFlight)
        #if DEBUG
        ddWrite("DDLIVE_TRACE replace step=\(step == .assignNow ? "assign" : "wait") inflight=\(stopInFlight ? 1 : 0)")
        #endif
        if step == .assignNow {
            stopWait?.cancel()
            stopWait = nil
            replacement = nil
            stopInFlight = false
            play(url: url, headers: headers, cachingMs: cachingMs, replacementOwner: job.token)
            return
        }
        replacement = job
        if stopInFlight {
            armStopDeadline(token: job.token)
            return
        }
        beginStop()
    }

    /// 会话拆掉后没有 aout 时，libvlc 会丢掉 `set_mute`，`get_mute` 的 -1 又被报成静音。
    /// 音轨要等这一轮返回后再选回去，输出出现后才写取消静音。
    func reopenAudioOutput() {
        outputMuted = false
        restoreAudio = true
        var track = mediaPlayer.currentAudioTrackIndex
        if track < 0 {
            for item in mediaPlayer.audioTrackIndexes {
                let number = (item as? NSNumber)?.intValue ?? -1
                if number >= 0 { track = Int32(number); break }
            }
        }
        let before = track
        let trackCount = mediaPlayer.audioTrackIndexes.count
        guard track >= 0 else {
            applyRestoredAudioIfNeeded()
            #if DEBUG
            ddWrite("DDLIVE_TRACE audio-track before=\(before) count=\(trackCount) after=-1 mute=\(mediaPlayer.audio?.isMuted == true ? 1 : 0)")
            #endif
            return
        }
        audioReopenID &+= 1
        let token = audioReopenID
        mediaPlayer.currentAudioTrackIndex = -1
        Task { @MainActor in
            guard token == audioReopenID else { return }
            mediaPlayer.currentAudioTrackIndex = track
            applyRestoredAudioIfNeeded()
            #if DEBUG
            let mute = mediaPlayer.audio?.isMuted == true
            ddWrite("DDLIVE_TRACE audio-track before=\(before) count=\(trackCount) after=\(mediaPlayer.currentAudioTrackIndex) mute=\(mute ? 1 : 0)")
            #endif
        }
    }

    /// 只在重新接上音频输出时写。用户静音或已经取消静音后不再碰音量。
    private func applyRestoredAudioIfNeeded() {
        guard restoreAudio else { return }
        if outputMuted {
            restoreAudio = false
            return
        }
        let audio = mediaPlayer.audio
        audio?.volume = 100
        audio?.isMuted = false
        if audio?.isMuted == false { restoreAudio = false }
    }

    /// 播放线程刚收到时钟。给前台恢复用，不经过主线程。
    var lastAdvanceAge: TimeInterval? { advanceClock.age }

    private func gateState() -> DYLivePlaybackGate.PlayerState {
        guard mediaPlayer.media != nil else { return .empty }
        switch mediaPlayer.state {
        case .opening, .esAdded: return .opening
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        case .ended, .error: return .failed
        @unknown default: return .failed
        }
    }

    private func beginStop() {
        callbackEpoch.bump()
        pendingStartEpoch = nil
        replayIfStopped = nil
        pendingOwned = nil
        pendingURL = nil
        pendingAutoplay = false
        isPlaying = false
        let idle = mediaPlayer.media == nil || [.stopped, .ended].contains(mediaPlayer.state)
        if idle {
            stopInFlight = false
            finishStopAndReplace()
            return
        }
        stopInFlight = true
        mediaPlayer.stop()
        if let token = replacement?.token { armStopDeadline(token: token) }
    }

    private func armStopDeadline(token: Int) {
        stopWait?.cancel()
        let limit = DYLivePlaybackGate.stopCompletionLimit
        stopWait = Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            let pending = replacement?.token == token
            guard DYLivePlaybackGate.shouldForceAssign(stopInFlight: stopInFlight, hasPending: pending, waited: limit) else { return }
            #if DEBUG
            ddWrite("DDLIVE_TRACE stop-timeout")
            #endif
            finishStopAndReplace(fromTimeout: true)
        }
    }

    private func finishStopAndReplace(fromTimeout: Bool = false) {
        stopWait?.cancel()
        stopWait = nil
        stopInFlight = false
        guard let job = replacement else { return }
        guard job.token == replacementToken else {
            #if DEBUG
            ddWrite("DDLIVE_TRACE START-REJECTED category=replacement-token epoch=\(callbackEpoch.current) token=\(job.token) current=\(replacementToken)")
            #endif
            replacement = nil
            return
        }
        replacement = nil
        let token = job.token
        // stop_async 的 stopped 回调返回前，旧 input 可能还在。同一轮里 play 不会新建输入。
        Task { @MainActor in
            if token != replacementToken || replacement != nil || stopInFlight {
                #if DEBUG
                let category = token != replacementToken ? "replacement-token" : (stopInFlight ? "stop-in-flight" : "other")
                ddWrite("DDLIVE_TRACE START-REJECTED category=\(category) epoch=\(callbackEpoch.current) token=\(token) current=\(replacementToken)")
                #endif
                return
            }
            play(url: job.url, headers: job.headers, cachingMs: job.cachingMs, replacementOwner: token)
            #if DEBUG
            ddWrite("DDLIVE_TRACE media-assigned timeout=\(fromTimeout ? 1 : 0) drawable=\(mediaPlayer.drawable == nil ? 0 : 1)")
            #else
            _ = fromTimeout
            #endif
        }
    }

    private func replayStoppedMediaIfNeeded() {
        guard let job = replayIfStopped else { return }
        let kind: DYLivePlaybackGate.LateStopKind
        switch mediaPlayer.state {
        case .stopped: kind = .stopped
        case .error: kind = .error
        case .ended: kind = .ended
        default:
            replayIfStopped = nil
            return
        }
        guard DYLivePlaybackGate.acceptsLateReplay(replayToken: job.token, currentToken: replacementToken, kind: kind) else {
            replayIfStopped = nil
            return
        }
        replayIfStopped = nil
        pendingOwned = nil
        play(url: job.url, headers: job.headers, cachingMs: job.cachingMs)
        #if DEBUG
        ddWrite("DDLIVE_TRACE late-stop-replay")
        #endif
    }

    /// drawable（渲染层）就绪后调用：首帧真正 play；或渲染层重连时恢复画面。
    /// 换流已经排了自己的启动时，这里不再 play，避免和它各发一次。
    func drawableAttached() {
        if handoffInFlight || interruptionRebuild { return }
        guard DYLivePlaybackGate.surfaceMayStart(
            stopInFlight: stopInFlight,
            ownedStartPending: pendingStartEpoch != nil,
            waitingForSurface: pendingURL != nil,
            playingIntent: isPlaying,
            state: gateState()) else { return }
        if pendingURL != nil {
            pendingURL = nil
            guard pendingAutoplay else { return }
            commitOwnedPlay(path: "surface")
        } else {
            // drawable 丢失后重挂 → 恢复渲染。正在打开/缓冲时别再 play：直播切房间时会把刚起的流打断
            #if DEBUG
            let before = mediaPlayer.state.rawValue
            ddWrite("DDLIVE_TRACE PLAY-INVOKED path=reattach epoch=\(callbackEpoch.current) token=\(replacementToken) before=\(before)")
            #endif
            mediaPlayer.play()
            #if DEBUG
            ddWrite("DDLIVE_TRACE PLAY-RETURNED path=reattach epoch=\(callbackEpoch.current) token=\(replacementToken) before=\(before) after=\(mediaPlayer.state.rawValue)")
            #endif
        }
    }

    func pause() {
        pendingStartEpoch = nil
        replayIfStopped = nil
        pendingOwned = nil
        mediaPlayer.pause()
        isPlaying = false
    }

    /// 继续同一路媒体。不更换 URL；渲染层还没挂上时，等 drawable 回来再 play。
    func resume() {
        isPlaying = true
        guard mediaPlayer.drawable != nil else { return }
        mediaPlayer.play()
    }

    func togglePlay() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            isPlaying = false
        } else {
            mediaPlayer.play()
            isPlaying = true
        }
    }

    /// 外部（JellyfinPlayerView）可用 Jellyfin 已知时长预置，避免 media.length 未解析时 seek 失效
    func setKnownDuration(_ d: Double) {
        if duration <= 0, d > 0 { duration = d }
    }

    func seekTo(_ pos: Double) {
        seekTarget = pos
        current = pos
        let wasPlaying = mediaPlayer.isPlaying
        if duration > 0 {
            mediaPlayer.position = Float(max(0, min(1, pos / duration)))
        } else {
            // 时长未知：用 VLC 的绝对时间跳转（毫秒）
            mediaPlayer.time = VLCTime(int: Int32(pos * 1000))
        }
        if wasPlaying { mediaPlayer.play() }
    }

    func setRate(_ rate: Float) {
        mediaPlayer.rate = rate
    }

    func stop() {
        replacementToken += 1
        replacement = nil
        beginStop()
    }

    private nonisolated func noteStaleCallback() {
        guard activePlayer.consumeStaleLog() else { return }
        #if DEBUG
        ddWrite("DDLIVE_TRACE STALE-CALLBACK rejected")
        #endif
    }

    // VLCMediaPlayerDelegate
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let source = aNotification.object as AnyObject?
        guard activePlayer.accepts(source) else {
            noteStaleCallback()
            return
        }
        let epoch = callbackEpoch.current
        advanceClock.stamp()
        Task { @MainActor in
            guard epoch == callbackEpoch.current, activePlayer.accepts(source), mediaPlayer.isPlaying else { return }
            publishAcceptedVideoSize(epoch: epoch)
            applyRestoredAudioIfNeeded()
            let raw = Double(mediaPlayer.time.intValue) / 1000.0
            let dur = mediaPlayer.media?.length.intValue ?? 0
            if dur > 0 { duration = Double(dur) / 1000.0 }

            // seek 防抖：seek 后 0.5 秒内忽略回调（VLC seek 后会报旧位置）
            if let target = seekTarget {
                if abs(raw - target) < 2.0 { seekTarget = nil }
                else { return }  // 还是旧值，跳过
            }

            // 单调递增防抖：回调值比上次小超过 1 秒 = 异常回退，跳过
            if raw < lastReported - 1.0 { return }
            lastReported = raw
            current = raw
            onProgress?(raw)
        }
    }

    private func publishAcceptedVideoSize(epoch: Int) {
        let sample = mediaPlayer.videoSize
        guard let next = DYLiveAdaptiveLayoutEngine.acceptedSize(
            current: videoSize,
            sample: sample,
            generation: epoch,
            callbackGeneration: callbackEpoch.current,
            playerIsCurrent: true) else { return }
        videoSize = next
        onVideoSize?(next)
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        let source = aNotification.object as AnyObject?
        // VLCKit 的 iOS 音频输出（audiounit_ios）停止时会自己 setActive(false, notifyOthersOnDeactivation)：
        // 整个 App 的音频会话被停用 → 后台音乐被通知接着放，正在播的短视频 AVPlayer 也被系统暂停。
        // 不管这条回调是否已过期（stop() 后的回调会被下面丢掉），都让当前短视频马上把会话拿回来；
        // aout 拆除可能比状态回调晚一点，稍后再补一次。
        if let st = (source as? VLCMediaPlayer)?.state, st == .stopped || st == .ended {
            Task { @MainActor in
                DDPlayback.shared.reclaimAudio("vlc-\(st == .ended ? "ended" : "stopped")")
                try? await Task.sleep(for: .milliseconds(300))
                DDPlayback.shared.reclaimAudio("vlc-stop+0.3s")
            }
        }
        guard activePlayer.accepts(source) else {
            noteStaleCallback()
            return
        }
        let epoch = callbackEpoch.current
        Task { @MainActor in
            guard epoch == callbackEpoch.current, activePlayer.accepts(source) else { return }
            let state = mediaPlayer.state
            switch state {
            case .opening, .buffering:
                replayIfStopped = nil
                pendingOwned = nil
            case .playing:
                replayIfStopped = nil
                pendingOwned = nil
                isPlaying = true
                applyRestoredAudioIfNeeded()
                publishAcceptedVideoSize(epoch: epoch)
            case .paused:
                isPlaying = false
            case .ended:
                isPlaying = false
                replayIfStopped = nil
                pendingOwned = nil
                onEnd?()
            case .error:
                isPlaying = false
                if stopInFlight || replacement != nil {
                    finishStopAndReplace()
                } else if pendingStartEpoch != nil {
                    break
                } else if replayIfStopped != nil {
                    replayStoppedMediaIfNeeded()
                } else {
                    onError?()
                }
            case .stopped:
                isPlaying = false
                let completion = onStopped
                onStopped = nil
                completion?()
                if interruptionRebuild {
                    Task { @MainActor in installFreshPlayer() }
                } else if stopInFlight || replacement != nil {
                    finishStopAndReplace()
                } else if pendingStartEpoch != nil {
                    break
                } else {
                    replayStoppedMediaIfNeeded()
                }
            case .esAdded:
                applyRestoredAudioIfNeeded()
                publishAcceptedVideoSize(epoch: epoch)
            default:
                break
            }
            #if DEBUG
            ddWrite("DDLIVE_TRACE vlc-state=\(state.rawValue) inflight=\(stopInFlight ? 1 : 0) pending=\(replacement == nil ? 0 : 1)")
            #endif
        }
    }
}

private final class VLCPlayerRelease: @unchecked Sendable {
    var player: VLCMediaPlayer?
}

private struct VLCReplacement {
    let url: URL
    let headers: [String: String]
    let cachingMs: Int32
    let token: Int
}

/// 当前允许改状态的那一只播放器。旧实例的通知在换代后被拒绝。
private final class VLCActivePlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var player: VLCMediaPlayer?
    private var staleArmed = false
    func adopt(_ player: VLCMediaPlayer, armStaleLog: Bool) {
        lock.lock()
        self.player = player
        if armStaleLog { staleArmed = true }
        lock.unlock()
    }
    func suspendAcceptance() {
        lock.lock()
        player = nil
        staleArmed = true
        lock.unlock()
    }
    func accepts(_ object: AnyObject?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return object != nil && object === player
    }
    func consumeStaleLog() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard staleArmed else { return false }
        staleArmed = false
        return true
    }
}

/// 播放线程写入、主线程读取的最近时钟时间。
private final class VLCAdvanceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stampedAt: Date?
    func stamp() {
        lock.lock(); stampedAt = Date(); lock.unlock()
    }
    var age: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let stampedAt else { return nil }
        return Date().timeIntervalSince(stampedAt)
    }
}

/// 给 VLC 委托回调用的代数。委托线程和主线程都会碰它。
private final class VLCCallbackEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() {
        lock.lock(); value += 1; lock.unlock()
    }
    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
