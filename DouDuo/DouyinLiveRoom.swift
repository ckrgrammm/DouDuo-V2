import SwiftUI
import UIKit
import Combine
import AVFoundation

struct DYLiveStream: Hashable {
    let url: URL
    let quality: String
    let isFLV: Bool
    var cacheMS: Int32 { isFLV ? 800 : 1500 }
}

extension DYLiveRoom {
    /// 优先连续 HTTP-FLV，避免 HLS 播放列表/分片等待；同画质 HLS 保留为兜底。
    var liveStreams: [DYLiveStream] {
        let flv = flv ?? [:]
        let keys = ["HD1", def ?? "", "FULL_HD1", "SD1", "SD2"] + Array(Set(hls.keys).union(flv.keys)).sorted()
        var seen = Set<URL>()
        var result: [DYLiveStream] = []
        #if DEBUG
        let hlsOnly = ProcessInfo.processInfo.environment["DOUDUO_LIVE_HLS"] == "1"
        #else
        let hlsOnly = false
        #endif
        for key in keys where !key.isEmpty {
            for isFLV in [true, false] where !(hlsOnly && isFLV) {
                guard let value = (isFLV ? flv : hls)[key], let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { continue }
                result.append(DYLiveStream(url: url, quality: key, isFLV: isFLV))
            }
        }
        return result
    }
}

private let dyLiveLogQueue = DispatchQueue(label: "douduo.live-log", qos: .utility)
/// 只在 dyLiveLogQueue 上用
private let dyLiveLogFormatter: DateFormatter = {
    let df = DateFormatter(); df.dateFormat = "HH:mm:ss"; return df
}()

@MainActor
final class DYLiveModel: ObservableObject {
    @Published var rooms: [DYLiveRoom] = []
    @Published var currentID: String?
    @Published var error: String?
    @Published var playbackError: String?
    @Published var loading = false
    private(set) var fetchedAt = Date.distantPast
    @Published var ready = false
    /// 当前这一路解码出的画面尺寸。只在尺寸变化时更新，用来重新判断横屏分屏。
    @Published var playbackVideoSize: CGSize = .zero
    @Published var zone: DYLiveZone?
    /// 关注的主播里正在开播的（网页版直播首页顶上那排头像，复用同一个接口）
    @Published var followLive: [DYLiveRoom] = []
    /// 最近一次关注列表的分类。空数组本身不能当成未登录。
    @Published var followLiveKind: DYFollowLiveKind?
    private var followLiveFetchedAt = Date.distantPast
    private var loadedFollowSession = -1
    private var followedOnly = false
    @Published var clean = false
    @Published var entered = false
    /// 「发现更多」面板展开（在挑直播间）：不播任何直播，免得后台挂着一个还在出声
    var browsing = false
    /// 手动选的清晰度（nil = 自动，用抖音给的默认）；全局记住，换直播间也沿用
    @Published var quality: String? = UserDefaults.standard.string(forKey: "douyin_live_quality_v1")
    /// 这个直播间有的清晰度，高到低
    var qualityOptions: [String] {
        let have = Set((roomRef?.liveStreams ?? []).map(\.quality))
        return ["ORIGION", "FULL_HD1", "HD1", "SD1", "SD2"].filter(have.contains)
    }
    static func qualityName(_ q: String) -> String {
        ["ORIGION": "原画", "FULL_HD1": "蓝光", "HD1": "超清", "SD1": "高清", "SD2": "标清"][q] ?? q
    }
    func setQuality(_ q: String?) {
        quality = q
        UserDefaults.standard.set(q, forKey: "douyin_live_quality_v1")
        retry()
    }
    @Published var muted = false {
        didSet {
            vlc.outputMuted = muted
            if !muted, sessionReleased {
                if activatePlaybackSession() {
                    vlc.reopenAudioOutput()
                    sessionReleased = false
                }
            } else {
                vlc.mediaPlayer.audio?.isMuted = muted
            }
        }
    }
    let vlc = VLCPlayerController()
    private var requestGeneration = UUID()
    private var loadedRoom: String?
    private var roomRef: DYLiveRoom?
    private var sources: [DYLiveStream] = []
    private var retryTask: Task<Void, Never>?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var streamGeneration = UUID()
    private let lifecycleID = UUID()
    private var visible = false
    /// 推荐流里的直播预览：优先轻量 FLV 线路、缩短缓冲与起播超时（本地功能）
    var isFeedPreview = false
    /// 前后台过渡已经开始。重复回调不能再改策略，也不能再重连一次。
    private var suspended = false
    /// 后台声音关闭时，这次进后台已经停掉媒体。回前台必须重开，不能复用。
    private var stoppedForBackground = false
    /// 这次离开前台的墙钟时间。不用会在睡眠中停住的 systemUptime。
    private var suspendedAt: Date?
    /// 系统打断了音频。恢复时不能把打断前的缓冲接着播。
    private var audioInterrupted = false
    /// 音频会话被交还过。视频可能还在，但 VLC 的音频输出已经拆掉。
    private var sessionReleased = false
    private var interruptionObserver: NSObjectProtocol?
    /// 进入后台时输入模块已读字节。demux 计数会消化旧缓冲，不能当作新数据。
    private var inputReadAtBackground: Int64 = 0
    private var visit = DYLiveVisit()
    private var savedFeed: SavedLiveFeed?
    var isFollowedVisit: Bool { visit.followed }
    var isFollowedCatalog: Bool { followedOnly }
    /// 关注分类里的当前房间还没有播放地址时，界面用它重新解析这一间。
    @Published private(set) var catalogResolveNonce = 0

    private struct SavedLiveFeed {
        var rooms: [DYLiveRoom]
        var currentID: String?
        var zone: DYLiveZone?
        var error: String?
        var fetchedAt: Date
    }

    func activate() {
        visible = true
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    self?.handleAudioInterruption(note)
                }
            }
        }
        DDPlayback.shared.register(lifecycleID, stop: { [weak self] in self?.suspendForBackground() }, start: { [weak self] in
            self?.resumeFromBackground()
        }, retainsAudioSession: { [weak self] in
            self?.wantsBackgroundAudioSession ?? false
        })
        play(roomRef)
    }
    func deactivate() {
        visible = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        DDPlayback.shared.unregister(lifecycleID)
        stop()
    }

    /// 日志在调用点取时间，开关文件挪到后台串行队列：顺序不变，主线程（翻页 / 播放回调）不再做文件 IO。
    nonisolated static func log(_ s: String) {
        let now = Date()
        dyLiveLogQueue.async {
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("ddlog.txt")
            let line = dyLiveLogFormatter.string(from: now) + " " + s + "\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    init() {
        vlc.onProgress = { [weak self] time in
            guard let self else { return }
            if self.suspended {
                self.reapplyBackgroundMuteIfNeeded()
            } else if self.vlc.mediaPlayer.audio?.isMuted != DYLivePlaybackGate.foregroundOutputMuted(userMuted: self.muted) {
                self.vlc.mediaPlayer.audio?.isMuted = DYLivePlaybackGate.foregroundOutputMuted(userMuted: self.muted)
            }
            guard !self.ready, self.loadedRoom != nil, time > 0,
                  self.liveCanProgress,
                  self.vlc.mediaPlayer.hasVideoOut else { return }
            self.ready = true
            self.retryTask?.cancel()
            Self.log("DDLIVE_READY room=\(self.loadedRoom ?? "-") elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - self.startedAt)) videoOut=true")
        }
        vlc.onVideoSize = { [weak self] size in
            guard let self, self.loadedRoom != nil, self.playbackVideoSize != size else { return }
            self.playbackVideoSize = size
        }
        vlc.onError = { [weak self] in
            guard let self, self.loadedRoom != nil, self.liveCanProgress else { return }
            self.tryNextSource(reason: "decoder/network error", generation: self.streamGeneration)
        }
        vlc.onEnd = { [weak self] in
            guard let self, self.loadedRoom != nil, self.liveCanProgress else { return }
            self.playbackError = "直播已结束或连接中断，可重试或上滑换台"
            self.ready = false
        }
    }

    func load(_ bridge: DouyinBridge, reset: Bool = false) async {
        guard visit.acceptsRecommendation else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_LIVEMOCK"] == "1" {
            guard reset || rooms.isEmpty else { return }
            let seeded = DYLiveRoom.debugFeed()
            rooms = seeded
            currentID = seeded.first?.id
            error = nil
            fetchedAt = .distantFuture
            visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
            return
        }
        #endif
        guard !loading, !followedOnly else { return }
        let generation = requestGeneration, requestedZone = zone
        let start = ProcessInfo.processInfo.systemUptime
        loading = true
        defer { if requestGeneration == generation { loading = false } }
        do {
            let r = try await bridge.fetchLive(reset: reset, zone: requestedZone)
            guard requestGeneration == generation, zone == requestedZone else { return }
            if reset { rooms = [] }
            var seen = Set(rooms.map(\.id))
            rooms.append(contentsOf: r.filter { seen.insert($0.id).inserted })
            if !rooms.contains(where: { $0.id == currentID }) { noteVisibleRoom(rooms.first?.id) }
            fetchedAt = Date()
            error = rooms.isEmpty ? (zone == nil ? "暂时没有直播" : "这个分类暂时没有直播") : nil
            visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
            Self.log("DDLIVE_FEED count=\(r.count) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
        } catch {
            guard requestGeneration == generation else { return }
            if rooms.isEmpty { self.error = error.localizedDescription }
        }
    }

    func prepareFeaturedEntry(_ bridge: DouyinBridge) async {
        guard !visible, !entered, !followedOnly, zone == nil,
              let room = rooms.first, currentID == room.id else { return }
        let generation = requestGeneration
        if let cover = room.cover.flatMap(URL.init(string:)) {
            Task { _ = await ImageCache.shared.load(cover) }
        }
        let refreshed = room.webRid.isEmpty ? nil : (try? await bridge.refreshLivePreview(room))
        guard !Task.isCancelled, requestGeneration == generation, !visible,
              currentID == room.id, rooms.first?.id == room.id else { return }
        if let refreshed { rooms[0] = refreshed }
        if let source = rooms[0].liveStreams.first { Self.warmEntrySource(source, roomID: room.id) }
    }

    func play(_ room: DYLiveRoom?) {
        guard let room else { return }
        roomRef = room
        let restart = loadedRoom != room.id || DYLivePlaybackGate.shouldRestartSameRoom(
            state: playbackState(), ready: ready, hasMedia: vlc.mediaPlayer.media != nil)
        let applicationActive = UIApplication.shared.applicationState == .active
        if DYLivePlaybackGate.acceptsRoomChange(playbackRegisteredActive: DDPlayback.shared.appIsActive, applicationActive: applicationActive, visible: visible), restart {
            suspended = false
            suspendedAt = nil
            audioInterrupted = false
        }
        guard !browsing, DYLivePlaybackGate.acceptsRoomChange(playbackRegisteredActive: DDPlayback.shared.appIsActive, applicationActive: applicationActive, visible: visible), !suspended else {
            if loadedRoom != room.id {
                ready = false
                playbackError = nil
            }
            return
        }
        guard restart else { return }
        loadedRoom = room.id
        sources = room.liveStreams
        // 选了清晰度就把它排最前，起不来才退回其他档。全局清晰度跨直播间保留。
        if isFeedPreview, let ordered = Self.previewOrdered(sources) {
            sources = ordered
        } else if let q = quality, sources.contains(where: { $0.quality == q }) {
            sources = sources.filter { $0.quality == q } + sources.filter { $0.quality != q }
        }
        startCurrentSource()
    }

    /// 滑到另一间时先撤掉上一间的就绪状态，避免旧画面被当成这一间已经播出。
    func noteVisibleRoom(_ id: String?) {
        guard id != currentID else { return }
        currentID = id
        if loadedRoom != id {
            ready = false
            playbackError = nil
        }
    }

    /// 人已经在前台时，清掉过期的后台锁，让超时和换源还能继续。
    private var liveCanProgress: Bool {
        let applicationActive = UIApplication.shared.applicationState == .active
        let allowed = DYLivePlaybackGate.acceptsRoomChange(
            playbackRegisteredActive: DDPlayback.shared.appIsActive,
            applicationActive: applicationActive,
            visible: visible)
        if allowed, applicationActive { suspended = false }
        return allowed && !suspended
    }

    private var backgroundSoundEnabled: Bool {
        UserDefaults.standard.bool(forKey: DYLiveBackgroundSound.storageKey)
    }

    /// 只有真正要播出直播声音时才占着播放会话。静音或被打断时不拿它保活。
    private var wantsBackgroundAudioSession: Bool {
        guard DDPlayback.shared.pauseReason == .background, !audioInterrupted else { return false }
        return DYLivePlaybackGate.retainsAudioSession(
            visible: visible,
            hasMedia: vlc.mediaPlayer.media != nil,
            userMuted: muted,
            backgroundSound: backgroundSoundEnabled,
            interrupted: audioInterrupted)
    }

    private func suspendForBackground() {
        let reason = DDPlayback.shared.pauseReason
        if reason == .inactive || !visible { return }
        if reason == .cover {
            guard !suspended else { return }
            suspended = true
            suspendedAt = Date()
            retryTask?.cancel()
            sessionReleased = true
            if loadedRoom != nil, vlc.mediaPlayer.media != nil { vlc.pause() }
            return
        }
        let first = !suspended
        if first {
            suspended = true
            suspendedAt = Date()
            retryTask?.cancel()
        }
        // 只有「后台直播声音」关闭、并且已经进了真正的 background，才停媒体。
        if DYLivePlaybackGate.stopsMediaOnBackground(backgroundSound: backgroundSoundEnabled) {
            guard loadedRoom != nil, !stoppedForBackground else {
                if loadedRoom == nil, first {
                    suspended = false
                    suspendedAt = nil
                }
                return
            }
            stoppedForBackground = true
            sessionReleased = true
            streamGeneration = UUID()
            vlc.stop()
            return
        }
        guard first else { return }
        captureBackgroundInput()
        let outputMuted = audioInterrupted || DYLivePlaybackGate.backgroundOutputMuted(
            userMuted: muted, backgroundSound: backgroundSoundEnabled)
        vlc.outputMuted = outputMuted
        vlc.mediaPlayer.audio?.isMuted = outputMuted
        if wantsBackgroundAudioSession {
            if activatePlaybackSession() { sessionReleased = false }
        } else {
            sessionReleased = true
        }
    }

    private func resumeFromBackground() {
        if DDPlayback.shared.coverHold { return }
        if stoppedForBackground {
            let action = DYLivePlaybackGate.silenceResume(
                visible: visible, hasRoom: roomRef != nil, coverHold: false, pending: true)
            stoppedForBackground = false
            suspended = false
            suspendedAt = nil
            audioInterrupted = false
            guard action == .reconnect else { return }
            let room = roomRef
            loadedRoom = nil
            play(room)
            return
        }
        let away = suspendedAt.map { Date().timeIntervalSince($0) }
        let age = vlc.lastAdvanceAge
        let inputAdvanced = inputAdvancedSinceBackground()
        let decision = DYLivePlaybackGate.recovery(
            suspended: suspended,
            visible: visible,
            sameRoom: loadedRoom != nil && loadedRoom == roomRef?.id,
            hasMedia: vlc.mediaPlayer.media != nil,
            state: playbackState(),
            backgroundDuration: away,
            lastAdvanceAge: age,
            inputAdvanced: inputAdvanced,
            interrupted: audioInterrupted)
        let interrupted = audioInterrupted
        let awayText = String(format: "%.0f", away ?? -1)
        let ageText = age.map { String(format: "%.1f", $0) } ?? "-"
        Self.log("DDLIVE_RESUME action=\(decision.action == .continueExisting ? "reuse" : decision.action == .reconnect ? "reconnect" : "ignore") reason=\(decision.reason) away=\(awayText) age=\(ageText) input=\(inputAdvanced ? 1 : 0) gen=\(streamGeneration.uuidString.prefix(4))")
        guard decision.action != .ignore else { return }
        audioInterrupted = false
        suspendedAt = nil
        suspended = false
        switch decision.action {
        case .ignore:
            break
        case .continueExisting:
            let reopen = sessionReleased
            _ = activatePlaybackSession()
            applyForegroundAudio(reopenTrack: reopen)
            let age = vlc.lastAdvanceAge ?? .infinity
            let pictureReady = DYLivePlaybackGate.canShowExistingPicture(state: playbackState(), hasVideoOut: vlc.mediaPlayer.hasVideoOut)
            if pictureReady || age <= DYLivePlaybackGate.continuityWindow {
                ready = true
                playbackError = nil
                retryTask?.cancel()
            }
            armResumeWatch()
        case .reconnect:
            if DYLivePlaybackGate.shouldRebuildPlayer(
                backgroundSound: backgroundSoundEnabled,
                interrupted: interrupted,
                action: decision.action,
                coverHold: DDPlayback.shared.coverHold,
                visible: visible,
                hasRoom: roomRef != nil) {
                ready = false
                retryTask?.cancel()
                vlc.onInterruptionPlayerReady = { [weak self] in
                    guard let self, self.visible, self.roomRef != nil, !DDPlayback.shared.coverHold else { return }
                    let room = self.roomRef
                    self.loadedRoom = nil
                    self.play(room)
                }
                vlc.onInterruptionRebuildFailed = { [weak self] in
                    guard let self, self.visible, self.roomRef != nil else { return }
                    self.ready = false
                    self.playbackError = "直播连接失败，请重试或上滑换台"
                }
                vlc.rebuildPlayerAfterInterruption()
                return
            }
            let room = roomRef
            loadedRoom = nil
            play(room)
        }
    }

    /// 回到前台时只恢复进房静音。会话被释放过且用户没静音时，重开音轨，不换媒体。
    private func applyForegroundAudio(reopenTrack: Bool) {
        let output = DYLivePlaybackGate.foregroundAudio(userMuted: muted, sessionReleased: reopenTrack)
        vlc.outputMuted = output.muted
        if output.reopenTrack {
            vlc.reopenAudioOutput()
            sessionReleased = false
        } else if sessionReleased {
            vlc.mediaPlayer.audio?.isMuted = true
        } else {
            vlc.mediaPlayer.audio?.isMuted = output.muted
            if !output.muted { vlc.mediaPlayer.audio?.volume = 100 }
        }
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard visible, loadedRoom != nil else { return }
            audioInterrupted = true
            sessionReleased = true
            // 系统已经拿走音频。只静音的话，VLC 仍可能把播放会话抢回来。
            vlc.pause()
            vlc.outputMuted = true
            vlc.mediaPlayer.audio?.isMuted = true
            DYLiveModel.log("DDAUDIO live interruption began preview=\(isFeedPreview) muted=\(muted)")
            // 推荐流里静音预播的直播不拥有音频会话（短视频在用）：停用会话会让后台音乐接着放、短视频被暂停
            if !(isFeedPreview && muted) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        case .ended:
            let applicationActive = UIApplication.shared.applicationState == .active
            guard audioInterrupted, DDPlayback.shared.appIsActive || applicationActive else { return }
            resumeFromBackground()
        default:
            break
        }
    }

    private func captureBackgroundInput() {
        inputReadAtBackground = Int64(vlc.mediaPlayer.media?.statistics.readBytes ?? 0)
    }

    /// 只看输入模块的 readBytes。demux 字节增加只表示在消化已经读入的缓冲。
    private func inputAdvancedSinceBackground() -> Bool {
        guard let media = vlc.mediaPlayer.media else { return false }
        return Int64(media.statistics.readBytes) > inputReadAtBackground
    }

    /// 音轨对象可能晚于进后台才出现。进度回调上把后台静音再写一次。
    private func reapplyBackgroundMuteIfNeeded() {
        guard suspended, DDPlayback.shared.pauseReason == .background else { return }
        let shouldMute = audioInterrupted || DYLivePlaybackGate.backgroundOutputMuted(
            userMuted: muted, backgroundSound: backgroundSoundEnabled)
        guard vlc.mediaPlayer.audio?.isMuted != shouldMute else { return }
        vlc.mediaPlayer.audio?.isMuted = shouldMute
    }

    private func playbackState() -> DYLivePlaybackGate.PlayerState {
        guard vlc.mediaPlayer.media != nil else { return .empty }
        switch vlc.mediaPlayer.state {
        case .opening, .esAdded: return .opening
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        case .ended, .error: return .failed
        @unknown default: return .failed
        }
    }

    private func startCurrentSource() {
        retryTask?.cancel()
        streamGeneration = UUID()
        let generation = streamGeneration
        ready = false; playbackError = nil; playbackVideoSize = .zero
        guard let source = sources.first else {
            playbackError = "没有可用直播线路，请重试或换一个直播间"
            vlc.stop()
            return
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        let sessionOK = activatePlaybackSession()
        if sessionOK { sessionReleased = false }
        vlc.outputMuted = DYLivePlaybackGate.foregroundOutputMuted(userMuted: muted)
        let flv = source.isFLV
        vlc.onMediaAssigned = { [weak self] in
            self?.armSourceTimeout(generation: generation, flv: flv)
        }
        let cacheMS: Int32 = isFeedPreview && source.isFLV ? 500 : source.cacheMS
        vlc.replace(url: source.url, headers: DYMedia.liveHeaders, cachingMs: cacheMS)
        Self.log("DDLIVEPLAY room=\(loadedRoom ?? "-") protocol=\(source.isFLV ? "FLV" : "HLS") q=\(source.quality) cache=\(cacheMS) drawable=\(vlc.mediaPlayer.drawable != nil) session=\(sessionOK ? 1 : 0)")
    }

    @discardableResult
    private func activatePlaybackSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            return false
        }
    }

    private func armSourceTimeout(generation: UUID, flv: Bool) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            let startupTimeout = flv ? (self?.isFeedPreview == true ? 3 : 6) : (self?.isFeedPreview == true ? 6 : 10)
            do { try await Task.sleep(for: .seconds(startupTimeout)) } catch { return }
            guard let self else { return }
            guard DYLivePlaybackGate.acceptEvent(currentGeneration: self.streamGeneration, eventGeneration: generation, ownerRoomID: self.loadedRoom, eventRoomID: self.loadedRoom),
                  !self.ready, self.liveCanProgress else { return }
            self.tryNextSource(reason: "startup timeout", generation: generation)
        }
    }

    /// 沿用当前会话之后，时钟停住才整段重连。这只发现卡死，不证明还在直播前沿。
    private func armResumeWatch() {
        retryTask?.cancel()
        let generation = streamGeneration
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self else { return }
            guard DYLivePlaybackGate.acceptEvent(currentGeneration: self.streamGeneration, eventGeneration: generation, ownerRoomID: self.loadedRoom, eventRoomID: self.loadedRoom),
                  self.liveCanProgress else { return }
            let age = self.vlc.lastAdvanceAge ?? .infinity
            if age <= DYLivePlaybackGate.continuityWindow { return }
            self.loadedRoom = nil
            self.play(self.roomRef)
        }
    }

    private func tryNextSource(reason: String, generation: UUID) {
        guard DYLivePlaybackGate.acceptEvent(currentGeneration: streamGeneration, eventGeneration: generation, ownerRoomID: loadedRoom, eventRoomID: loadedRoom),
              liveCanProgress else { return }
        retryTask?.cancel()
        Self.log("DDLIVE_FALLBACK reason=\(reason) remaining=\(sources.count)")
        if !sources.isEmpty { sources.removeFirst() }
        guard !sources.isEmpty else {
            playbackError = "直播连接失败，请重试或上滑换台"; ready = false; vlc.stop(); return
        }
        startCurrentSource()
    }

    func retry() {
        if isFollowedCatalog, let room = rooms.first(where: { $0.id == currentID }), room.liveStreams.isEmpty {
            playbackError = nil
            catalogResolveNonce += 1
            return
        }
        guard let room = roomRef else { return }
        loadedRoom = nil; play(room)
    }
    func enterRoom() {
        entered = true; clean = false
        Self.log("DDLIVE_ENTER room=\(currentID ?? "-") reused=true")
    }
    func leaveRoom() {
        guard visit.followed, let saved = savedFeed else {
            entered = false; clean = false
            Self.log("DDLIVE_LEAVE room=\(currentID ?? "-") reused=true")
            return
        }
        visit.leave()
        savedFeed = nil
        requestGeneration = UUID()
        loading = false
        stop()
        rooms = saved.rooms
        currentID = visit.currentID
        if currentID == nil || !rooms.contains(where: { $0.id == currentID }) { currentID = rooms.first?.id }
        zone = saved.zone
        error = saved.error
        fetchedAt = saved.fetchedAt
        entered = false
        clean = false
        playbackError = nil
        visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
        Self.log("DDLIVE_LEAVE followed=1 restored=\(rooms.count)")
        let restored = rooms.first { $0.id == currentID }
        if followedOnly, restored?.liveStreams.isEmpty != false {
            playbackError = nil
        } else {
            play(restored)
        }
    }
    func stop() {
        suspended = false
        suspendedAt = nil
        stoppedForBackground = false
        audioInterrupted = false
        sessionReleased = false
        retryTask?.cancel(); streamGeneration = UUID()
        vlc.cancelInterruptionRebuild()
        loadedRoom = nil; vlc.stop(); ready = false
    }
    func reset() {
        followedOnly = false
        requestGeneration = UUID(); loading = false
        stop(); rooms = []; currentID = nil; error = nil; playbackError = nil
        entered = false; clean = false
        visit.clear(); savedFeed = nil
    }
    func select(_ z: DYLiveZone?, _ bridge: DouyinBridge) {
        guard z != zone || rooms.isEmpty else { return }
        zone = z; reset()
        Task { await load(bridge, reset: true) }
    }
    /// 从推荐流的直播预览卡进房（本地功能）：沿用预览正在播的这一路流。
    func enterFromPreview(_ room: DYLiveRoom) {
        isFeedPreview = false
        browsing = false
        rooms = [room]
        currentID = room.id
        fetchedAt = Date()
        muted = false
        enterRoom()
    }

    func open(_ room: DYLiveRoom) {
        if !visit.followed {
            savedFeed = SavedLiveFeed(rooms: rooms, currentID: currentID, zone: zone, error: error, fetchedAt: fetchedAt)
            visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
        }
        visit.open(room.id)
        requestGeneration = UUID()
        loading = false
        stop()
        playbackError = nil
        error = nil
        rooms = [room]
        currentID = room.id
        entered = true
        clean = false
        fetchedAt = Date()
        play(room)
    }

    /// 关注分类里只补当前这一间的播放地址，不换掉整条列表。
    func adoptFollowPlayback(_ room: DYLiveRoom) {
        guard followedOnly else { return }
        guard let index = rooms.firstIndex(where: {
            $0.id == room.id || (!room.webRid.isEmpty && $0.webRid == room.webRid)
        }) else { return }
        let previous = rooms[index].id
        rooms[index] = room
        if currentID == previous { currentID = room.id }
        guard currentID == room.id else { return }
        loadedRoom = nil
        play(room)
    }

    /// 推荐流预览的线路顺序：轻量 FLV（SD）排最前。没有轻量线路时返回 nil，沿用默认顺序。
    static func previewOrdered(_ sources: [DYLiveStream]) -> [DYLiveStream]? {
        guard let lightweight = sources.firstIndex(where: {
            $0.isFLV && ($0.quality == "SD1" || $0.quality == "SD2")
        }) else { return nil }
        var ordered = sources
        ordered.insert(ordered.remove(at: lightweight), at: 0)
        return ordered
    }

    /// 推荐流直播卡快刷到时先暖预览要用的那条线路：DNS、CDN 回源、低清档的按需转码都在这一步触发，
    /// VLC 随后连上去时已经是热的。只读首包（最多 3 秒）就取消。
    private static var warmedPreview = Set<URL>()
    static func warmPreview(_ room: DYLiveRoom) {
        let streams = room.liveStreams
        guard let source = (previewOrdered(streams) ?? streams).first else { return }
        warmEntrySource(source, roomID: room.id)
    }

    private static func warmEntrySource(_ source: DYLiveStream, roomID: String) {
        guard warmedPreview.insert(source.url).inserted else { return }
        if warmedPreview.count > 60 { warmedPreview = [source.url] }
        var req = URLRequest(url: source.url, timeoutInterval: 6)
        for (k, v) in DYMedia.liveHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let start = ProcessInfo.processInfo.systemUptime
        let task = warmSession.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            log("DDLIVE_PREVIEW_WARM room=\(roomID) proto=\(source.isFLV ? "FLV" : "HLS") q=\(source.quality) code=\(code) bytes=\(data?.count ?? 0) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
        }
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { task.cancel() }
    }

    /// 提前暖一下下一两间（和上一间）的直播线路：触发 DNS 解析、CDN 回源和边缘缓存。
    /// 只读前 1KB 就取消，不占带宽；VLC 自己的连接不能复用，收益在 DNS 与 CDN 首包。
    private var warmed = Set<URL>()
    func warmNeighbors() {
        guard let id = currentID, let i = rooms.firstIndex(where: { $0.id == id }) else { return }
        let ids = [i + 1, i + 2, i - 1].filter { rooms.indices.contains($0) }
        for idx in ids {
            guard let source = rooms[idx].liveStreams.first, warmed.insert(source.url).inserted else { continue }
            if warmed.count > 40 { warmed.removeAll() }
            var req = URLRequest(url: source.url, timeoutInterval: 6)
            for (k, v) in DYMedia.liveHeaders { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let start = ProcessInfo.processInfo.systemUptime
            let task = Self.warmSession.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                Self.log("DDLIVE_WARM idx=\(idx) proto=\(source.isFLV ? "FLV" : "HLS") code=\(code) bytes=\(data?.count ?? 0) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
            }
            task.resume()
            // FLV 是无尽流：拿到首包就够，最多 3 秒后取消，别一直占着 CDN 连接。
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { task.cancel() }
        }
    }
    private static let warmSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func invalidateFollowLive() {
        followLive = []
        followLiveKind = nil
        followLiveFetchedAt = .distantPast
        loadedFollowSession = -1
    }

    /// 关注列表按账号代际隔离。同一账号 2 分钟内不重复请求；换账号立刻丢掉上一份。
    /// `refresh` 只在用户点重试时绕过这两分钟，仍走原来的关注列表请求。
    func loadFollowLive(_ bridge: DouyinBridge, refresh: Bool = false) async {
        let session = bridge.followSession
        let sessionChanged = session != loadedFollowSession
        guard refresh || sessionChanged || Date().timeIntervalSince(followLiveFetchedAt) > 120 else { return }
        if sessionChanged {
            followLive = []
            followLiveKind = nil
        }
        followLiveFetchedAt = Date()
        loadedFollowSession = session
        let result = await bridge.followLiveResult(ignoreCache: refresh)
        guard session == bridge.followSession else { return }
        followLiveKind = result.kind
        switch result.kind {
        case .rooms:
            followLive = result.items
        case .nobodyLive, .filtered:
            followLive = []
        case .notLoggedIn, .requestFailed, .decodeFailed, .unexpectedShape:
            break
        }
    }

    /// 一级分类「关注」：把整条流换成关注主播的开播列表，仍可上下滑换台
    func openFollowed(_ bridge: DouyinBridge) {
        guard !followLive.isEmpty else { return }
        zone = nil; reset()
        rooms = followLive; currentID = followLive.first?.id
        followedOnly = true // 关注列表到末尾不能混入推荐直播。
        fetchedAt = Date()
        Self.log("DDLIVE_FOLLOWED count=\(followLive.count)")
    }

    /// 一级分类「精选」：不论之前是关注列表还是游戏专区，都回到推荐直播流
    func backToFeatured(_ bridge: DouyinBridge) {
        zone = nil; reset()
        Task { await load(bridge, reset: true) }
    }
}

// MARK: - live-playback-gate
enum DYLiveSceneSignal: Equatable {
    case active, inactive, background
}

enum DYLiveSceneCommand: Equatable {
    case none, pause, resume
}

enum DYLiveSurfaceMask: Equatable {
    case showVideo, coverPrevious
}

enum DYLiveResumeAction: Equatable {
    case ignore, continueExisting, reconnect
}

enum DYLiveMediaReplacement: Equatable {
    case assignNow, waitUntilStopped
}

/// 「后台直播声音」。默认关闭。和直播间里的静音开关不是同一个偏好。
enum DYLiveBackgroundSound {
    static let storageKey = "douyin_live_background_sound_v1"
}

/// 直播前后台和房间遮挡的纯判断。播放器实例仍只有一个。
/// 后台声音开或关共用 `resume`。设置只决定出声，不另起一套重连。
struct DYLivePlaybackGate {
    enum PlayerState: Equatable {
        case empty, opening, buffering, playing, paused, stopped, failed
    }

    static func sceneCommand(_ signal: DYLiveSceneSignal) -> DYLiveSceneCommand {
        switch signal {
        case .active: .resume
        case .background: .pause
        case .inactive: .none
        }
    }

    /// 已经在前台或后台时，重复回调不再停流、也不再重连。
    static func apply(appIsActive: Bool, command: DYLiveSceneCommand) -> Bool {
        switch command {
        case .none: false
        case .pause: appIsActive
        case .resume: !appIsActive
        }
    }

    static func mask(isCurrent: Bool, ready: Bool, failed: Bool) -> DYLiveSurfaceMask {
        isCurrent && ready && !failed ? .showVideo : .coverPrevious
    }

    /// 播放线程上的时钟比这个更旧，就说明进程已经停过，不能把离开前的缓冲接着播。
    /// 这个时间不是直播前沿距离。VLCKit 3.6 没有那项测量。readBytes 也不证明还在前沿。
    static let continuityWindow: TimeInterval = 3

    /// 后台只改出声。用户本来就静音，或者关掉了后台声音，输出都保持静音。
    static func backgroundOutputMuted(userMuted: Bool, backgroundSound: Bool) -> Bool {
        userMuted || !backgroundSound
    }

    /// 回到前台时恢复进房静音偏好，不把后台策略留下来。
    static func foregroundOutputMuted(userMuted: Bool) -> Bool { userMuted }

    /// 只有确实要播出声音时才保留播放会话。静音会话不拿来保活。
    static func retainsAudioSession(visible: Bool, hasMedia: Bool, userMuted: Bool, backgroundSound: Bool, interrupted: Bool) -> Bool {
        visible && hasMedia && backgroundSound && !userMuted && !interrupted
    }

    /// 开/关后台声音都走这里。播放线程的时钟还新鲜才沿用；否则换新的 VLCMedia。
    /// `inputAdvanced` 只留给诊断。计数停在 0 不能否定一条还在出声的流，增加了也不能证明就在直播前沿。
    static func resume(suspended: Bool, visible: Bool, sameRoom: Bool, hasMedia: Bool, state: PlayerState, backgroundDuration: TimeInterval? = nil, lastAdvanceAge: TimeInterval? = nil, inputAdvanced: Bool = false, interrupted: Bool = false) -> DYLiveResumeAction {
        recovery(suspended: suspended, visible: visible, sameRoom: sameRoom, hasMedia: hasMedia, state: state, backgroundDuration: backgroundDuration, lastAdvanceAge: lastAdvanceAge, inputAdvanced: inputAdvanced, interrupted: interrupted).action
    }

    /// 前台一次已确认的打断重连要换掉已经无法再 opening 的那只 VLC。后台声音开或关都换。
    /// 真正进入后台时，关闭后台声音仍由 `stopsMediaOnBackground` 停媒体，不经过这里。
    /// 没有打断标志的回前台、健康复用、遮罩和已经离房都不换。
    static func shouldRebuildPlayer(backgroundSound: Bool, interrupted: Bool, action: DYLiveResumeAction, coverHold: Bool, visible: Bool, hasRoom: Bool) -> Bool {
        _ = backgroundSound
        return interrupted && action == .reconnect && !coverHold && visible && hasRoom
    }

    static func recovery(suspended: Bool, visible: Bool, sameRoom: Bool, hasMedia: Bool, state: PlayerState, backgroundDuration: TimeInterval? = nil, lastAdvanceAge: TimeInterval? = nil, inputAdvanced: Bool = false, interrupted: Bool = false) -> (action: DYLiveResumeAction, reason: String) {
        guard visible else { return (.ignore, "hidden") }
        guard suspended || interrupted else { return (.ignore, "already-foreground") }
        if interrupted { return (.reconnect, "interrupted") }
        if !sameRoom { return (.reconnect, "different-room") }
        if !hasMedia { return (.reconnect, "no-media") }
        let alive = state == .playing || state == .buffering
        if !alive { return (.reconnect, "not-playing") }
        guard let age = lastAdvanceAge, age <= continuityWindow else { return (.reconnect, "stale-callback") }
        _ = backgroundDuration
        _ = inputAdvanced
        return (.continueExisting, "callbacks-fresh")
    }

    /// 后台声音关闭时，真正的 background 要停掉当前媒体。打开时继续原来的出声路径。
    static func stopsMediaOnBackground(backgroundSound: Bool) -> Bool { !backgroundSound }

    enum DYLiveSilenceResume: Equatable {
        case ignore, reconnect
    }

    /// OFF 回前台只重连一次。离开房间、覆盖层还在、或这次并没有因静音而停止，都不再打开。
    static func silenceResume(visible: Bool, hasRoom: Bool, coverHold: Bool, pending: Bool) -> DYLiveSilenceResume {
        guard pending, visible, hasRoom, !coverHold else { return .ignore }
        return .reconnect
    }

    /// 正在拆掉的流不能马上装新媒体。状态读数已经是 stopped 也不能证明异步 stop 已经返回。
    static func mediaReplacement(state: PlayerState, stopInFlight: Bool) -> DYLiveMediaReplacement {
        if stopInFlight { return .waitUntilStopped }
        switch state {
        case .empty, .stopped, .failed: return .assignNow
        case .opening, .buffering, .playing, .paused: return .waitUntilStopped
        }
    }

    enum LateStopKind: Equatable {
        case stopped, error, ended
    }

    /// 只重开仍属于当前这次换流的 stopped/error。换房、清晰度、手动重连和退房都会换掉 token。
    static func acceptsLateReplay(replayToken: Int?, currentToken: Int, kind: LateStopKind) -> Bool {
        guard let replayToken, replayToken == currentToken else { return false }
        switch kind {
        case .stopped, .error: return true
        case .ended: return false
        }
    }

    /// 渲染层重新挂上时，不能再发一次 play。已经排队的启动，或还没完成的 stop，由它们自己的所有权启动。
    static func surfaceMayStart(stopInFlight: Bool, ownedStartPending: Bool, waitingForSurface: Bool, playingIntent: Bool, state: PlayerState) -> Bool {
        if stopInFlight || ownedStartPending { return false }
        if waitingForSurface { return true }
        return playingIntent && (state == .stopped || state == .paused || state == .failed)
    }

    /// 同一房间还在打开或播放时，不要再 stop 一次。已经停住或失败则重新打开。
    static func shouldRestartSameRoom(state: PlayerState, ready: Bool, hasMedia: Bool) -> Bool {
        guard hasMedia else { return true }
        _ = ready
        switch state {
        case .opening, .buffering, .playing: return false
        case .empty, .paused, .stopped, .failed: return true
        }
    }

    /// 沿用的画面已经在输出时，加载指示可以拿掉。没有画面时不要假装已经播出来。
    static func canShowExistingPicture(state: PlayerState, hasVideoOut: Bool) -> Bool {
        hasVideoOut && (state == .playing || state == .buffering)
    }

    /// 后台或打断关掉音频会话之后，只把静音打开不够，音轨要重新接上。用户自己静音时不动音轨。
    static func foregroundAudio(userMuted: Bool, sessionReleased: Bool) -> (muted: Bool, reopenTrack: Bool) {
        (userMuted, sessionReleased && !userMuted)
    }

    /// 停止回调迟到时，只允许到点后强制装上已经排队的那一条新媒体。
    static let stopCompletionLimit: TimeInterval = 2

    static func shouldForceAssign(stopInFlight: Bool, hasPending: Bool, waited: TimeInterval) -> Bool {
        stopInFlight && hasPending && waited >= stopCompletionLimit
    }

    /// 用户已经回到前台时，登记表上的「仍在后台」不能挡住换房和重试。
    static func acceptsRoomChange(playbackRegisteredActive: Bool, applicationActive: Bool, visible: Bool) -> Bool {
        visible && (playbackRegisteredActive || applicationActive)
    }

    static func acceptEvent(currentGeneration: UUID, eventGeneration: UUID, ownerRoomID: String?, eventRoomID: String?) -> Bool {
        currentGeneration == eventGeneration && ownerRoomID != nil && ownerRoomID == eventRoomID
    }
}
// MARK: - live-playback-gate-end

private enum DYLiveCategoryKind {
    case featured, gameZones
    case partition(DYLiveZone)
}
private struct DYLiveCategory: Identifiable {
    let id: String, name: String
    let kind: DYLiveCategoryKind
}
private let ddLiveCategories: [DYLiveCategory] = [
    .init(id: "featured", name: "精选", kind: .featured),
    .init(id: "game", name: "游戏", kind: .gameZones),
    .init(id: "chat", name: "聊天", kind: .partition(.init(id: "101", type: "4", name: "聊天"))),
    .init(id: "music", name: "音乐", kind: .partition(.init(id: "102", type: "4", name: "音乐"))),
    .init(id: "anime", name: "二次元", kind: .partition(.init(id: "104", type: "4", name: "二次元"))),
    .init(id: "dance", name: "舞蹈", kind: .partition(.init(id: "105", type: "4", name: "舞蹈"))),
    .init(id: "culture", name: "文化", kind: .partition(.init(id: "106", type: "4", name: "文化"))),
    .init(id: "life", name: "生活", kind: .partition(.init(id: "107", type: "4", name: "生活"))),
    .init(id: "exercise", name: "运动", kind: .partition(.init(id: "108", type: "4", name: "运动"))),
]

@available(iOS 27.1, *)
private func dyLiveHingeStatus(_ hinge: DeviceHinge?) -> DYLiveHingeStatus {
    guard let hinge else { return .unsupported }
    if hinge.status == .closed { return .closed }
    if hinge.status == .partiallyOpen { return .partiallyOpen }
    if hinge.status == .fullyOpen { return .fullyOpen }
    return .unsupported
}

private extension View {
    @ViewBuilder
    func onLiveHingeChange(_ apply: @escaping (DYLiveHingeStatus) -> Void) -> some View {
        if #available(iOS 27.1, *) {
            onHingeChange { _, context in apply(dyLiveHingeStatus(context.hinge)) }
        } else {
            self
        }
    }

    func placed(in pane: CGRect) -> some View {
        frame(width: pane.width, height: pane.height)
            .position(x: pane.midX, y: pane.midY)
    }
}

private func livePane(_ requested: CGRect, fallback: CGSize) -> CGRect {
    let rect = requested.standardized
    guard rect.width > 1, rect.height > 1 else { return CGRect(origin: .zero, size: fallback) }
    return rect
}

/// 预览和直播间共用同一个 drawable / VLC，不用网页开第二套播放器。

/// 简洁 / 极简模块菜单发给直播页的一次性动作。token 变化才会再次触发。
struct DYLiveModuleRequest: Equatable {
    enum Action: Equatable {
        case followedLive
        case discover
    }
    var token: Int
    var action: Action
}

/// 布局 A 时，把下窗格从直播视图坐标换到 `douduo.feed`，供父级摆模块圆钮。
struct DYLiveModuleAnchor: Equatable {
    var active = false
    var pane = CGRect.zero
    var compact = false
    var safeBottom: CGFloat = 0
    var safeTrailing: CGFloat = 0
}

struct DYLiveModuleAnchorKey: PreferenceKey {
    static var defaultValue = DYLiveModuleAnchor()
    static func reduce(value: inout DYLiveModuleAnchor, nextValue: () -> DYLiveModuleAnchor) {
        let next = nextValue()
        if next.active || !value.active { value = next }
    }
}

struct DYLiveFeed: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let bridge: DouyinBridge
    @ObservedObject var model: DYLiveModel
    let onWeb: (URL) -> Void
    var active = true
    /// 顶栏在 `douduo.feed` 坐标里的框。位置仍由顶栏自己决定，这里只用来把按钮放到它下面。
    var topChrome: CGRect = .zero
    var screenInsets: EdgeInsets = .init()
    var entryStartedAt: TimeInterval? = nil
    @State private var entryListLogged = false
    @State private var entryFrameLogged = false
    var moduleRequest: DYLiveModuleRequest? = nil
    /// 默认模式保留左上角「发现更多 / 正在直播」。简洁和极简只从模块菜单进入。
    var classicPreviewChrome: Bool = true
    /// 从推荐流预览进房时，离开直播间要回到推荐流（本地功能）
    var onLeaveRoom: (() -> Void)? = nil
    @StateObject private var chat = DYLiveChat()
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var showCategories = false
    @State private var showFollowLive = false
    /// 「发现更多」只放分类。关注开播走旁边的「关注直播」。
    @State private var showDiscover = false
    /// 关注主播头像条：默认收起，只显示「N 位正在直播」胶囊；点胶囊展开，选了主播或离开直播页就收起。
    @State private var followStripExpanded = false
    @State private var appliedModuleToken = 0
    @State private var selectedCategory = "featured"
    @State private var categoryHint: String?
    @State private var followPick = DYFollowSelection()
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var gestureStartID: String?
    @State private var scrollEndTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    /// 键盘盖住当前视口底部的高度。分页本身忽略键盘安全区，只用这个值把评论栏抬上去。
    @State private var keyboardOverlap: CGFloat = 0
    @State private var viewportMinY: CGFloat = 0
    @State private var viewportMaxY: CGFloat = 0
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    /// 系统只通过 onHingeChange 给出开合。没收到回调前保持不支持，继续整屏。
    @State private var hingeStatus: DYLiveHingeStatus = .unsupported
    @State private var layoutMemory = DYLiveAdaptiveMemory.empty
    /// 半折叠时仍可手动回到原来的整屏。只在同一种分屏仍然成立时保留。
    @State private var forceImmersive = false
    /// 内屏完全展开时，用户在「更多」里手动分屏（不需要半折叠）。
    @State private var manualSplit = false
    @State private var immersiveAnchor: DYLiveAdaptiveLayout = .existing
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }
    private var currentRoom: DYLiveRoom? { model.rooms.first { $0.id == model.currentID } }
    private var chatRoom: String? {
        guard model.entered, danmakuOn, let rid = currentRoom?.webRid, !rid.isEmpty else { return nil }
        return rid
    }
    /// 评论网页要加载的房间。进房立刻加载；预览阶段视频出画后再预热当前这一间，进房时评论区已经连上。
    private var chatTarget: String? {
        guard active, danmakuOn, !model.browsing, let rid = currentRoom?.webRid, !rid.isEmpty else { return nil }
        if model.entered { return rid }
        return model.ready ? rid : nil
    }
    /// 键盘弹出期间锁住换台。收起后再接受竖滑。
    private var keyboardLocksPaging: Bool { inputFocused || keyboardOverlap > 1 }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.frame(in: .global)
            let layout = resolvedLayout(in: geo)
            let shown = layout.shown
            let placement = layoutTogglePlacement(stable: layout.stable.decision, in: geo)
            // 整屏仍按竖屏铺满。只有桌面模式把横屏画面放到状态栏下面，并贴住上窗格底边。
            let fillWidth = shown.layout == .existing && currentRoom?.portrait == true && geo.size.height > geo.size.width * 1.2
            let videoFrame = shown.layout == .layoutA
                ? DYLiveLayoutAVideo.frame(
                    in: shown.video,
                    aspect: DYLiveLayoutAVideo.aspect(of: model.playbackVideoSize),
                    safeTop: inset(geo.safeAreaInsets.top, screenInsets.top))
                : shown.video
            ZStack {
                Color.black
                VLCPlayerSurface(controller: model.vlc, fillWidth: fillWidth)
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .position(x: videoFrame.midX, y: videoFrame.midY)
                    .allowsHitTesting(false)
                if model.rooms.isEmpty { emptyState }
                else {
                    pages(video: shown.video, interaction: shown.interaction,
                          ambientAxis: DYLiveAmbientTreatment.axis(for: shown.layout),
                          splitRole: menuSplitRole(placement.role),
                          splitAction: {
                              if canManualSplit { withAnimation(.easeInOut(duration: 0.2)) { manualSplit.toggle() } }
                              else { performSplitToggle(role: placement.role, eligible: layout.stable.decision.layout) }
                          })
                }
                if !model.entered, classicPreviewChrome || showDiscover || followStripExpanded {
                    let chrome = previewChrome(in: geo, pane: shown.interaction)
                    VStack(alignment: .leading, spacing: 0) {
                        if classicPreviewChrome {
                            discoverBar
                                .padding(.trailing, chrome.trailing)
                        } else if followStripExpanded {
                            // 关闭键只占发现按钮那一行的高度，头像条才和经典模式展开后对齐。
                            railFollowDismiss
                                .padding(.trailing, chrome.trailing)
                        }
                        if followStripExpanded, (!classicPreviewChrome || !model.followLive.isEmpty) {
                            Group {
                                if model.followLive.isEmpty {
                                    railFollowNote
                                } else {
                                    followStrip(scrollTail: chrome.stripTail)
                                }
                            }
                            .padding(.top, 10)
                            .padding(.trailing, chrome.stripTrailing)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if showDiscover {
                            discoverPanel
                                .padding(.trailing, chrome.trailing)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.leading, chrome.leading)
                    .padding(.top, chrome.top)
                    .frame(width: shown.interaction.width, height: shown.interaction.height, alignment: .topLeading)
                    .position(x: shown.interaction.midX, y: shown.interaction.midY)
                    .animation(.easeInOut(duration: 0.2), value: showDiscover)
                    .animation(.easeInOut(duration: 0.2), value: followStripExpanded)
                }
                if placement.role != .hidden {
                    layoutToggle(placement, eligible: layout.stable.decision.layout)
                }
                #if DEBUG
                VStack {
                    Text(model.currentID ?? "-").accessibilityIdentifier("live.currentID")
                    Text(String(format: "%.1f", model.vlc.current)).accessibilityIdentifier("live.time")
                    Text(model.ready ? "1" : "0").accessibilityIdentifier("live.status")
                    Text("\(model.zone?.id ?? "featured")|\(model.rooms.count)|\(model.loading ? "loading" : "loaded")")
                        .accessibilityIdentifier("live.source")
                }.font(.caption2).opacity(0.01).allowsHitTesting(false)
                #endif
            }
            .preference(key: DYLiveModuleAnchorKey.self, value: liveModuleAnchor(in: geo, shown: shown))
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { syncViewport(minY: viewport.minY, maxY: viewport.maxY) }
            .onChange(of: viewport) { _, frame in syncViewport(minY: frame.minY, maxY: frame.maxY) }
            .onChange(of: layout.stable) { _, memory in layoutMemory = memory }
            .onChange(of: layout.stable.decision.layout) { _, kind in
                if !DYLiveLayoutToggle.manualApplies(active: forceImmersive, anchored: immersiveAnchor, eligible: kind) {
                    forceImmersive = false
                }
            }
        }
        .onLiveHingeChange { status in
            hingeStatus = status
            if status == .closed || status == .partiallyOpen { manualSplit = false }
        }
        // 分页与 drawable 共用整屏视口。键盘安全区不能把这一屏缩短，否则上一间封面会从顶上露出来。
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .background(DYLiveChatHost(chat: chat).frame(width: 1, height: 1).allowsHitTesting(false))
        .onChange(of: model.rooms.isEmpty, initial: true) { _, empty in
            guard !empty, !entryListLogged, let entryStartedAt else { return }
            entryListLogged = true
            DYLiveModel.log("DDLIVE_ENTRY_LIST ms=\(Int((ProcessInfo.processInfo.systemUptime - entryStartedAt) * 1000))")
        }
        .onChange(of: model.ready, initial: true) { _, ready in
            guard ready, active, !entryFrameLogged, let entryStartedAt else { return }
            entryFrameLogged = true
            DYLiveModel.log("DDLIVE_ENTRY_FRAME ms=\(Int((ProcessInfo.processInfo.systemUptime - entryStartedAt) * 1000))")
        }
        .onAppear {
            guard active else { return }
            model.activate()
            if model.isFollowedCatalog, currentRoom?.liveStreams.isEmpty == true { model.playbackError = nil }
        }
        .onChange(of: active) { _, value in
            if value {
                followStripExpanded = false
                model.activate()
                presentCurrentRoom()
            } else {
                dismissPreviewOverlays()
                model.deactivate()
            }
        }
        .task {
            if model.rooms.isEmpty || Date().timeIntervalSince(model.fetchedAt) > 60 {
                await model.load(bridge, reset: true)
            }
            scrollID = model.currentID
            presentCurrentRoom()
            model.warmNeighbors()
            // 并发拉取关注主播，不占用首播带宽也不阻塞起播
            Task { await model.loadFollowLive(bridge) }
        }
        .onChange(of: model.currentID) { _, id in
            if let id, scrollID != id { scrollID = id }
            draft = ""; sendError = nil; inputFocused = false
            presentCurrentRoom()
            model.warmNeighbors()
            if !model.isFollowedVisit, !model.isFollowedCatalog, let id, let i = model.rooms.firstIndex(where: { $0.id == id }), i >= model.rooms.count - 3 {
                Task { await model.load(bridge) }
            }
        }
        .task(id: chatTarget) {
            guard let id = chatTarget else {
                // 离开直播页或关闭弹幕才断开；退出房间回到预览时保留，下次进同一间不用重连。
                if !active || !danmakuOn { chat.close() }
                return
            }
            if chat.loadedRoom == id { return }
            // 预览预热：停留 1.5 秒才加载，快速上下翻台不会每间都开一次评论网页。
            if !model.entered {
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                guard !Task.isCancelled, id == chatTarget else { return }
            }
            chat.open(id)
        }
        .onChange(of: model.entered) { _, entered in
            if entered { dismissPreviewOverlays() }
            else {
                inputFocused = false; draft = ""; sendError = nil
                if model.isFollowedCatalog, currentRoom?.liveStreams.isEmpty == true { presentCurrentRoom() }
            }
        }
        .onChange(of: model.catalogResolveNonce) { _, _ in presentCurrentRoom() }
        .onChange(of: model.isFollowedVisit) { _, followed in
            if !followed, model.rooms.isEmpty { Task { await model.load(bridge, reset: true) } }
        }
        .onChange(of: showFollowLive) { _, shown in
            if shown { cancelFollowPick() }
        }
        .onChange(of: moduleRequest) { _, request in
            guard let request, request.token != appliedModuleToken else { return }
            appliedModuleToken = request.token
            switch request.action {
            case .followedLive:
                withAnimation(.easeInOut(duration: 0.2)) {
                    if followStripExpanded {
                        followStripExpanded = false
                    } else {
                        showDiscover = false
                        followStripExpanded = true
                    }
                }
            case .discover:
                withAnimation(.easeInOut(duration: 0.2)) {
                    followStripExpanded = false
                    showDiscover = true
                }
            }
        }
        .onChange(of: classicPreviewChrome) { _, _ in
            dismissPreviewOverlays()
        }
        .onChange(of: bridge.followSession) { _, _ in
            cancelFollowPick()
            model.invalidateFollowLive()
            Task { await model.loadFollowLive(bridge) }
        }
        .onDisappear { dismissPreviewOverlays(); scrollEndTask?.cancel(); cancelFollowPick(); model.deactivate(); chat.close() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { applyKeyboard($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardOverlap = 0
            userScrolling = false
            gestureStartID = nil
            pinCurrentPage()
        }
        .sheet(isPresented: $showCategories) {
            DYLiveCategories(selection: model.zone) { z in
                showCategories = false
                cancelFollowPick()
                if let z {
                    model.select(z, bridge)
                    selectedCategory = "game"
                    categoryHint = "已切到「\(z.name)」专区"
                } else {
                    model.backToFeatured(bridge)
                    selectedCategory = "featured"; categoryHint = nil
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFollowLive) {
            DYFollowLiveSheet(bridge: bridge) { room in
                showFollowLive = false
                model.open(room)
            } onLogin: {
                showFollowLive = false
                onWeb(DouyinWeb.home)
            }
            .presentationDragIndicator(.visible)
        }
    }

    /// 按钮顶边取导航下沿加 8pt，若顶部安全区更靠下则改到安全区下沿。左右各自让开安全区。
    private func resolvedLayout(in geo: GeometryProxy) -> (shown: DYLiveAdaptiveDecision, stable: DYLiveAdaptiveMemory) {
        let bounds = CGRect(origin: .zero, size: geo.size)
        let divisions = liveDivisions(in: geo)
        let proposed = DYLiveAdaptiveLayoutEngine.decide(
            bounds: bounds,
            status: hingeStatus,
            divisions: divisions,
            videoSize: DYLiveAdaptiveLayoutEngine.presentationSize(ready: model.ready, videoSize: model.playbackVideoSize))
        let stable = DYLiveAdaptiveLayoutEngine.stabilize(
            previous: layoutMemory,
            proposed: proposed,
            status: hingeStatus,
            bounds: bounds,
            divisions: divisions)
        let manual = DYLiveLayoutToggle.manualApplies(
            active: forceImmersive,
            anchored: immersiveAnchor,
            eligible: stable.decision.layout)
        var shown = manual
            ? DYLiveAdaptiveDecision(layout: .existing, video: bounds, interaction: bounds)
            : stable.decision
        if canManualSplit, manualSplit {
            shown = DYLiveAdaptiveLayoutEngine.manualSplit(
                bounds: bounds,
                videoSize: DYLiveAdaptiveLayoutEngine.presentationSize(ready: model.ready, videoSize: model.playbackVideoSize))
        }
        return (shown, stable)
    }

    /// `shown.interaction` 在直播 GeometryReader 里。换成 `douduo.feed` 后父级才能和自己的坐标相减。
    private func liveModuleAnchor(in geo: GeometryProxy, shown: DYLiveAdaptiveDecision) -> DYLiveModuleAnchor {
        let origin = geo.frame(in: .named("douduo.feed")).origin
        return DYLiveModuleAnchor(
            active: shown.layout == .layoutA,
            pane: shown.interaction.offsetBy(dx: origin.x, dy: origin.y),
            compact: hSize == .compact,
            safeBottom: inset(geo.safeAreaInsets.bottom, screenInsets.bottom),
            safeTrailing: inset(geo.safeAreaInsets.trailing, screenInsets.trailing))
    }

    private func layoutTogglePlacement(stable: DYLiveAdaptiveDecision, in geo: GeometryProxy) -> DYLiveLayoutTogglePlacement {
        DYLiveLayoutToggle.place(
            eligible: stable.layout,
            manual: DYLiveLayoutToggle.manualApplies(active: forceImmersive, anchored: immersiveAnchor, eligible: stable.layout),
            bounds: CGRect(origin: .zero, size: geo.size),
            interaction: stable.interaction,
            compact: hSize == .compact,
            safeBottom: geo.safeAreaInsets.bottom,
            safeTrailing: geo.safeAreaInsets.trailing,
            keyboardOverlap: keyboardOverlap,
            entered: model.entered)
    }

    private func liveDivisions(in geo: GeometryProxy) -> [DYLiveDivision] {
        guard #available(iOS 27.1, *) else { return [] }
        return geo.reservedRegions(kind: .division).map {
            DYLiveDivision(frame: $0.frame, isActive: $0.isActive)
        }
    }

    /// 「更多」里的分屏/整屏：内屏完全展开时随时可点；半折叠沿用原来的资格判断；其余（外屏/普通手机）灰掉。
    /// restoreSplit = 当前是整屏，点了去分屏；enterImmersive = 当前是分屏，点了去整屏。
    /// 内屏完全展开。系统若没回调铰链状态（unsupported），宽屏（regular）也按展开处理，免得按钮永远灰掉。
    private var canManualSplit: Bool {
        hingeStatus == .fullyOpen || (hingeStatus == .unsupported && hSize == .regular)
    }

    private func menuSplitRole(_ placed: DYLiveLayoutToggleRole) -> DYLiveLayoutToggleRole {
        if canManualSplit { return manualSplit ? .enterImmersive : .restoreSplit }
        return placed
    }

    private func performSplitToggle(role: DYLiveLayoutToggleRole, eligible: DYLiveAdaptiveLayout) {
        if role == .restoreSplit {
            forceImmersive = false
        } else if role == .enterImmersive, eligible != .existing {
            immersiveAnchor = eligible
            forceImmersive = true
        }
    }

    private func layoutToggle(_ placement: DYLiveLayoutTogglePlacement, eligible: DYLiveAdaptiveLayout) -> some View {
        let restoring = placement.role == .restoreSplit
        return Button {
            performSplitToggle(role: placement.role, eligible: eligible)
        } label: {
            Text(restoring ? "分屏" : "整屏")
                .font(.subheadline.weight(.semibold))
                .frame(width: placement.frame.width, height: placement.frame.height)
                .ddGlassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(restoring ? "live.layout.adaptive" : "live.layout.immersive")
        .position(x: placement.frame.midX, y: placement.frame.midY)
    }

    /// 按钮顶边取导航下沿加 8pt，若顶部安全区更靠下则改到安全区下沿。
    /// 遮挡区和折痕改成窗格内的内边距：整段平移会把左侧按钮和第一颗头像推出外屏。
    private func previewChrome(in geo: GeometryProxy, pane: CGRect) -> (top: CGFloat, leading: CGFloat, trailing: CGFloat, stripTrailing: CGFloat, stripTail: CGFloat) {
        let paneAtTop = pane.minY < 24
        let feedTop = geo.frame(in: .named("douduo.feed")).minY
        let top = paneAtTop
            ? DYLivePreviewChrome.buttonOriginY(
                feedMinY: feedTop,
                navMaxY: topChrome.maxY,
                safeTop: inset(geo.safeAreaInsets.top, screenInsets.top))
            : 12
        let leading = DYLivePreviewChrome.horizontalInset(inset(geo.safeAreaInsets.leading, screenInsets.leading))
        let trailing = DYLivePreviewChrome.horizontalInset(inset(geo.safeAreaInsets.trailing, screenInsets.trailing))
        let divisions = previewDivisions(in: geo)
        var regions = divisions
        if #available(iOS 27.1, *) {
            for region in geo.reservedRegions(kind: .occlusion) where region.isActive {
                regions.append(region.frame)
            }
        }
        let fitted = DYLivePreviewChrome.containedInsets(
            pane: pane, top: top, leading: leading, trailing: trailing, regions: regions)
        let strip = DYLivePreviewChrome.avatarStripInsets(
            conservativeTrailing: fitted.trailing, pane: pane, top: fitted.top,
            leading: fitted.leading, divisions: divisions)
        return (fitted.top, fitted.leading, fitted.trailing, strip.trailing, strip.scrollTail)
    }

    private func previewDivisions(in geo: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        var frames: [CGRect] = []
        for region in geo.reservedRegions(kind: .division) where region.isActive {
            frames.append(region.frame)
        }
        return frames
    }

    private func inset(_ local: CGFloat, _ passed: CGFloat) -> CGFloat {
        local > 0.5 ? local : passed
    }

    /// 顶部第一行：发现更多、关注直播选择器。位置由导航下沿和安全区决定。
    private var discoverBar: some View {
        HStack(spacing: hSize == .compact ? 8 : 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDiscover.toggle() }
            } label: {
                Label(showDiscover ? "收起" : "发现更多",
                      systemImage: showDiscover ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
                    .frame(minHeight: DYLivePreviewChrome.minTapHeight)
                    .ddGlassCapsule()
            }
            .foregroundStyle(foreground).buttonStyle(.plain)
            .accessibilityIdentifier("live.discover")
            if !model.followLive.isEmpty { followLiveButton }
            Spacer(minLength: 0)
        }
    }

    private var discoverPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !classicPreviewChrome {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showDiscover = false }
                } label: {
                    Text("关闭")
                        .font(.subheadline.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(foreground)
                .accessibilityIdentifier("live.discover.close")
            }
            categoryStrip
            if let categoryHint {
                Text(categoryHint).font(.caption)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
            }
        }
        .padding(.top, classicPreviewChrome ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一级分类条：只显示有真实列表接口的入口，横向滚动容纳窄屏。
    private var categoryStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("全部分类").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ddLiveCategories) { c in
                        Button { pickCategory(c) } label: {
                            Text(c.name)
                                .font(.subheadline.weight(selectedCategory == c.id ? .semibold : .regular))
                                .foregroundStyle(foreground)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(Capsule().fill(selectedCategory == c.id
                                    ? foreground.opacity(0.22)
                                    : theme.media.chromeFill.color(for: scheme)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live.category.\(c.id)")
                        .accessibilityValue(selectedCategory == c.id ? "已选择" : "未选择")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("live.categoryStrip")
        }
        .foregroundStyle(foreground)
    }

    private func pickCategory(_ c: DYLiveCategory) {
        cancelFollowPick()
        switch c.kind {
        case .featured:
            selectedCategory = c.id; categoryHint = nil
            model.backToFeatured(bridge)
        case .gameZones:
            selectedCategory = c.id
            model.select(DYLiveZone(id: "103", type: "4", name: "游戏"), bridge)
            categoryHint = "「游戏」下可选具体专区"
            showCategories = true
        case .partition(let zone):
            selectedCategory = c.id; categoryHint = nil
            model.select(zone, bridge)
        }
        if !classicPreviewChrome {
            withAnimation(.easeInOut(duration: 0.2)) { showDiscover = false }
        }
    }

    private func dismissPreviewOverlays() {
        showDiscover = false
        showFollowLive = false
        followStripExpanded = false
    }

    /// 有播放地址就直接播。关注分类里还没有地址的当前房间，只解析这一间。
    private func presentCurrentRoom() {
        if model.isFollowedCatalog, let room = currentRoom, room.liveStreams.isEmpty {
            model.playbackError = nil
            model.stop()
            resolveListedFollow(room, enter: false)
        } else {
            model.play(currentRoom)
        }
    }

    /// 列表里的关注直播只有展示信息。点某一间，或滑到分类里的一间时，才补这一间的播放地址。
    private func resolveListedFollow(_ room: DYLiveRoom, enter: Bool) {
        var pick = followPick
        let ticket = pick.begin(roomID: room.id, webRid: room.webRid, hasStream: !room.liveStreams.isEmpty)
        followPick = pick
        guard room.liveStreams.isEmpty else {
            if enter { model.open(room) } else { model.adoptFollowPlayback(room) }
            return
        }
        guard !room.webRid.isEmpty else {
            if !enter { model.playbackError = DYFollowSelectionFailure.unavailable.message }
            return
        }
        Task {
            let result = await bridge.resolveFollowRoom(webRid: room.webRid)
            guard followPick.isCurrent(roomID: room.id, token: ticket), !result.stale else { return }
            if result.kind == .notLoggedIn {
                model.followLive = []
                if !enter { model.playbackError = "抖音未登录" }
                return
            }
            if result.kind == .rooms, let resolved = result.items.first, !resolved.liveStreams.isEmpty {
                let ready = DYLiveRoom(playback: resolved, fallback: room)
                if enter { model.open(ready) } else { model.adoptFollowPlayback(ready) }
                return
            }
            if !enter {
                let failure = DYFollowSelectionFailure.from(kind: result.kind, hasPlayableRoom: false) ?? .unavailable
                model.playbackError = failure.message
            }
        }
    }

    private func cancelFollowPick() {
        var pick = followPick
        pick.cancel()
        followPick = pick
    }


    /// 替换原「我的关注」入口：有关注主播在播才出现，点开是一排头像，点头像直接进直播间。
    private var followLiveButton: some View {
        let count = model.followLive.count
        return Button { followStripExpanded.toggle() } label: {
            Label("\(count) 位正在直播", systemImage: followStripExpanded ? "chevron.up" : "chevron.down")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, hSize == .compact ? 10 : 14)
                .frame(minHeight: DYLivePreviewChrome.minTapHeight)
                .ddGlassCapsule()
        }
        .foregroundStyle(foreground).buttonStyle(.plain)
        .accessibilityIdentifier("live.follow")
        .accessibilityLabel("\(count) 位关注的主播正在直播")
    }

    private func followStrip(scrollTail: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(model.followLive) { r in
                    Button {
                        followStripExpanded = false
                        resolveListedFollow(r, enter: true)
                    } label: {
                        VStack(spacing: 4) {
                            CachedAsyncImage(url: r.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                                placeholder: { theme.media.chromeFill.color(for: scheme) }
                                .frame(width: 54, height: 54).clipShape(Circle())
                                .padding(3)
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
                    .accessibilityLabel("\(r.owner)，直播中")
                    .accessibilityIdentifier("live.strip.\(r.id)")
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 2 + scrollTail)
        }
        .scrollIndicators(.hidden)
        .themeShadow(.mediaLabel)
        .accessibilityIdentifier("live.follow.strip")
    }

    /// 简洁 / 极简没有发现和人数按钮。关闭键单独占这一行，高度与那两个按钮相同。
    private var railFollowDismiss: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { followStripExpanded = false }
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .frame(width: DYLivePreviewChrome.minTapHeight, height: DYLivePreviewChrome.minTapHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .accessibilityLabel("关闭我的关注")
        .accessibilityIdentifier("live.follow.strip.close")
    }

    /// 没有可展示的主播时，说明落在头像条同一条上，不开整页列表。
    private var railFollowNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(followStripNote)
                .font(.caption)
                .foregroundStyle(foreground)
                .accessibilityIdentifier("live.follow.strip.empty")
            if model.followLiveKind == .notLoggedIn {
                Button("登录") { onWeb(DouyinWeb.home) }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("live.follow.strip.login")
            } else if model.followLiveKind == .requestFailed || model.followLiveKind == .decodeFailed || model.followLiveKind == .unexpectedShape {
                Button("重试") { Task { await model.loadFollowLive(bridge, refresh: true) } }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("live.follow.strip.retry")
            }
        }
        .padding(.leading, 2)
    }

    private var followStripNote: String {
        switch model.followLiveKind {
        case .notLoggedIn: "登录后才能看到关注的直播"
        case .filtered: "暂时没有可播放的线路"
        case .requestFailed: "关注直播加载失败"
        case .decodeFailed, .unexpectedShape: "直播数据无法解析"
        case .nobodyLive, .rooms: "关注的人现在没有在直播"
        case nil: "正在查看关注的直播"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if let error = model.error {
                Text(error).font(.footnote)
                Button("重试") { Task { await model.load(bridge, reset: true) } }
                Button("网页版 / 登录") { onWeb(URL(string: "https://live.douyin.com/")!) }
            } else {
                ProgressView().tint(foreground)
                Text("连接直播…").font(.footnote)
            }
        }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func leaveRoom() {
        if let onLeaveRoom { onLeaveRoom() }
        else { model.leaveRoom() }
    }

    private func pages(video: CGRect, interaction: CGRect, ambientAxis: DYLiveAmbientAxis?,
                       splitRole: DYLiveLayoutToggleRole, splitAction: @escaping () -> Void) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.rooms) { room in
                    DYLiveRoomPage(room: room, model: model, isCurrent: model.currentID == room.id,
                                   messages: model.currentID == room.id && chat.loadedRoom == room.webRid ? chat.messages : [],
                                   keyboardOverlap: model.currentID == room.id ? keyboardOverlap : 0,
                                   input: AnyView(commentInput), onWeb: onWeb,
                                   videoPane: video, interactionPane: interaction,
                                   ambientAxis: model.currentID == room.id ? ambientAxis : nil,
                                   splitRole: splitRole, splitAction: splitAction,
                                   isolationID: "\(bridge.followSession):\(room.id)",
                                   onLeaveRoom: leaveRoom)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .contentShape(Rectangle())
                        .accessibilityHidden(model.currentID != room.id)
                        .id(room.id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .background(DYLivePagingKeyboardLock(locked: keyboardLocksPaging))
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if !userScrolling {
                    gestureStartID = model.currentID
                    #if DEBUG
                    DYLiveModel.log("DDLIVE_SCROLL start=\(model.currentID ?? "-") count=\(model.rooms.count)")
                    #endif
                }
                scrollEndTask?.cancel(); userScrolling = true
            }
            .onEnded { value in
                // 左缘右滑返回：与「我的 / 信息」页 DYEdgeSwipeBack 同一套判定（左缘 30pt 起、右滑 >70pt）。
                // 刻意复用分页这一个手势，不再叠第二层 simultaneousGesture，避免影响上滑换台。
                if (model.entered || model.clean),
                   value.startLocation.x < 30, value.translation.width > 70,
                   abs(value.translation.height) < abs(value.translation.width) {
                    if model.clean { model.clean = false } else { leaveRoom() }
                    scrollEndTask?.cancel(); userScrolling = false; gestureStartID = nil
                    return
                }
                if abs(value.translation.width) > 80 && abs(value.translation.width) > abs(value.translation.height) && model.entered {
                    withAnimation(.easeInOut(duration: 0.2)) { model.clean = value.translation.width > 0 }
                }
                scrollEndTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    userScrolling = false; gestureStartID = nil
                }
            })
        .onChange(of: scrollID) { _, id in
            // 键盘把分页视口顶偏时，把位置钉回当前房间，不接受这次换台。
            if keyboardLocksPaging {
                if id != model.currentID { pinCurrentPage() }
                return
            }
            guard let id, id != model.currentID else { return }
            // 仅接受真实竖滑引起的相邻页变化，布局/追加列表不得偷偷切台。
            let start = gestureStartID ?? model.currentID
            if userScrolling, let a = model.rooms.firstIndex(where: { $0.id == id }),
               let b = model.rooms.firstIndex(where: { $0.id == start }), abs(a - b) <= 1 {
                model.noteVisibleRoom(id)
            } else { scrollID = model.currentID }
        }
    }

    private func syncViewport(minY: CGFloat, maxY: CGFloat) {
        viewportMinY = minY
        viewportMaxY = maxY
    }

    private func applyKeyboard(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = DYLiveKeyboardLayout.overlap(
            viewportMinY: viewportMinY,
            viewportMaxY: viewportMaxY,
            keyboardMinY: frame.minY,
            keyboardMaxY: frame.maxY)
        if abs(keyboardOverlap - overlap) > 0.5 {
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: min(duration, 0.35))) { keyboardOverlap = overlap }
        }
        if overlap > 1 { pinCurrentPage() }
    }

    private func pinCurrentPage() {
        guard let id = model.currentID, scrollID != id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollID = id }
    }

    private var commentInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sendError { Text(sendError).font(.caption).foregroundStyle(theme.status.warning.color(for: scheme)) }
            HStack(spacing: 8) {
                TextField(chat.composerReady ? "说点什么…" : "评论区连接中…", text: $draft)
                    .font(.subheadline).foregroundStyle(foreground).focused($inputFocused)
                    .submitLabel(.send).onSubmit(sendComment)
                    .padding(.horizontal, 14).frame(height: 40).ddGlassCapsule()
                    .accessibilityIdentifier("live.chat.input")
                if !draft.isEmpty {
                    Button(action: sendComment) {
                        if sending { ProgressView() } else { Text(chat.composerReady ? "发送" : "连接中").font(.subheadline.weight(.semibold)) }
                    }.disabled(sending || !chat.composerReady).accessibilityIdentifier("live.chat.send")
                }
            }
        }
    }

    private func sendComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard chatRoom != nil, chat.composerReady else { sendError = "评论区连接中，稍后再试"; return }
        sending = true
        let target = chatRoom, submittedDraft = draft
        Task {
            let error = await chat.send(text)
            guard chatRoom == target else { sending = false; return }
            if let error { sendError = error }
            else if draft == submittedDraft { draft = ""; sendError = nil; inputFocused = false }
            sending = false
        }
    }
}

// MARK: - 推荐流直播预览（本地功能）

/// 直播预览卡的文案与进房按钮：推荐流里刷到的直播卡、直播页的预览态共用这一份，两处布局保持一致。
struct DYLivePreviewCardChrome: View {
    let room: DYLiveRoom
    var showsEnter = true
    var enterID = "live.preview.enter"
    let onOpen: () -> Void

    var body: some View {
        Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 7) {
                Text("直播中")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.94, green: 0.24, blue: 0.18), in: RoundedRectangle(cornerRadius: 4))
                Text(room.owner.hasPrefix("@") ? room.owner : "@" + room.owner)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(room.title).font(.footnote).lineLimit(2)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 52)
            .allowsHitTesting(false)
        }
        .overlay {
            if showsEnter {
                GeometryReader { geo in
                    Button(action: onOpen) {
                        Label("点击进入直播间", systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .ddGlassCapsule()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(enterID)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.67)
                }
            }
        }
    }
}

struct DYRecommendationLiveCard: View {
    let room: DYLiveRoom
    let active: Bool
    /// 这一间的画面已经出来。没出来之前用封面垫着，不露黑屏。
    var ready = true
    let previewError: String?
    let onRetry: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if !(active && ready) {
                // 滑入途中和连接期间显示直播封面（进入预热范围时已预载），画面一出来就让开
                CachedAsyncImage(url: room.cover.flatMap(URL.init(string:))) {
                    $0.resizable().scaledToFill()
                } placeholder: { Color.black }
                .overlay(Color.black.opacity(0.25))
                .clipped()
                .accessibilityHidden(true)
            }
        }
        .overlay { DYLivePreviewCardChrome(room: room, showsEnter: active, onOpen: onOpen) }
        .overlay {
            if active, !ready, previewError == nil {
                ProgressView().tint(.white).accessibilityLabel("连接直播")
            }
        }
        .overlay {
            if active, let previewError {
                VStack(spacing: 8) {
                    Text(previewError)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .clipped()
    }
}

struct DYRecommendationLivePlayback: View {
    let room: DYLiveRoom
    let audible: Bool
    @ObservedObject var model: DYLiveModel
    @State private var shownAt: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let showSidePanels = room.portrait && geo.size.width > geo.size.height
            ZStack {
                if showSidePanels && audible && model.ready {
                    CachedAsyncImage(url: room.cover.flatMap(URL.init(string:))) {
                        $0.resizable().scaledToFill()
                    } placeholder: { Color(white: 0.18) }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 36)
                    .overlay(Color.black.opacity(0.45))
                    .accessibilityHidden(true)
                }
                VLCPlayerSurface(controller: model.vlc, fillWidth: false)
                    .frame(width: showSidePanels ? geo.size.height * 9 / 16 : geo.size.width,
                           height: geo.size.height)
                    .opacity(model.ready ? 1 : 0)
                if audible && !model.ready && model.playbackError == nil {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("连接直播")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
            .onChange(of: model.ready) { _, ready in
                guard ready, let shownAt else { return }
                // 从刷到这张卡到出画面用了多久：0 表示预热已经完成
                DYLiveModel.log("DDLIVE_PREVIEW_READY room=\(room.id) wait_ms=\(Int((ProcessInfo.processInfo.systemUptime - shownAt) * 1000))")
                self.shownAt = nil
            }
            .task(id: audible) {
                if audible {
                    DYLiveModel.log("DDLIVE_PREVIEW_VISIBLE room=\(room.id) ready=\(model.ready)")
                    shownAt = model.ready ? nil : ProcessInfo.processInfo.systemUptime
                }
                if !audible {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
                model.isFeedPreview = true
                model.muted = !audible
                model.play(room)
                model.activate()
            }
            .onDisappear { if !model.entered { model.deactivate() } }
    }
}

private struct DYLiveRoomPage: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(DYLiveBackgroundSound.storageKey) private var backgroundSound = false
    let room: DYLiveRoom
    @ObservedObject var model: DYLiveModel
    let isCurrent: Bool
    let messages: [DYLiveMsg]
    let keyboardOverlap: CGFloat
    let input: AnyView
    let onWeb: (URL) -> Void
    var videoPane: CGRect
    var interactionPane: CGRect
    var ambientAxis: DYLiveAmbientAxis?
    /// 「更多」里的分屏/整屏入口。只有折叠屏处在可分屏姿态时才可点。
    var splitRole: DYLiveLayoutToggleRole = .hidden
    var splitAction: () -> Void = {}
    var isolationID: String
    var onLeaveRoom: () -> Void = {}
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }

    var body: some View {
        GeometryReader { geo in
            let video = livePane(videoPane, fallback: geo.size)
            let interaction = livePane(interactionPane, fallback: geo.size)
            let topInset = DYLiveLayoutToggle.returnTopInset(paneMinY: interaction.minY, compact: hSize == .compact)
            ZStack {
                ZStack {
                if DYLivePlaybackGate.mask(isCurrent: isCurrent, ready: model.ready, failed: model.playbackError != nil) == .coverPrevious {
                    ZStack {
                        Color.black
                        if let cover = room.cover, let url = URL(string: cover) {
                            CachedAsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: room.portrait ? .fill : .fit) }
                                placeholder: { Color.black }
                                .frame(width: geo.size.width, height: geo.size.height).clipped()
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }
                if isCurrent && !model.entered {
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.enterRoom() }
                }
                if isCurrent, !model.ready || model.playbackError != nil {
                    VStack(spacing: 10) {
                        if let error = model.playbackError {
                            Text(error).font(.footnote).multilineTextAlignment(.center)
                            Button("重试", action: model.retry).buttonStyle(.bordered)
                        } else {
                            ProgressView().tint(foreground)
                            Text("连接直播…").font(.caption)
                        }
                    }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }
                .placed(in: video)
                Group {
                if !isCurrent {
                    Color.clear.allowsHitTesting(false)
                } else if model.clean {
                    // 与进房态同一套「返回」胶囊，放左上避开右上系统状态栏 / 前摄挖孔
                    VStack { HStack { backCapsule(action: { model.clean = false }, id: "live.room.restore"); Spacer() }; Spacer() }
                        .contentShape(Rectangle())
                        .onTapGesture { model.clean = false }
                        .padding(.leading, 18).padding(.trailing, hSize == .compact ? 82 : 18).padding(.top, topInset)
                } else if model.entered {
                    let closeOnBottom = DYLiveChromePlacement.closeOnBottomTrailing(
                        regularWidth: hSize == .regular,
                        foldActive: DYDuoMetrics.foldIsActive(geo))
                    VStack {
                        header(showsClose: !closeOnBottom)
                        Spacer(minLength: 12)
                        HStack(alignment: .bottom, spacing: 12) {
                            VStack(alignment: .leading, spacing: 12) {
                                if !messages.isEmpty { DYLiveChatOverlay(messages: messages) }
                                HStack(spacing: 12) {
                                    input
                                    Menu {
                                    Button("清屏", systemImage: "rectangle") { model.clean = true }
                                    Toggle("静音", systemImage: "speaker.slash", isOn: $model.muted)
                                    Toggle("后台播放", systemImage: "speaker.wave.2", isOn: $backgroundSound)
                                        .accessibilityIdentifier("live.room.backgroundSound")
                                    Menu("清晰度", systemImage: "sparkles.tv") {
                                        Picker("清晰度", selection: Binding(get: { model.quality ?? "" },
                                                                         set: { model.setQuality($0.isEmpty ? nil : $0) })) {
                                            Text("自动").tag("")
                                            ForEach(model.qualityOptions, id: \.self) { Text(DYLiveModel.qualityName($0)).tag($0) }
                                        }
                                    }
                                    .accessibilityIdentifier("live.room.quality")
                                    Button(splitRole == .restoreSplit ? "分屏" : "整屏",
                                           systemImage: splitRole == .restoreSplit ? "rectangle.split.1x2" : "rectangle.expand.vertical",
                                           action: splitAction)
                                        .disabled(splitRole == .hidden)
                                        .accessibilityIdentifier("live.room.split")
                                    Button("重新连接", systemImage: "arrow.clockwise", action: model.retry)
                                    Button("官网互动（礼物）", systemImage: "safari") { onWeb(room.webURL) }
                                    } label: { Image(systemName: "ellipsis").font(.title2).frame(width: 44, height: 44).ddGlassCircle() }
                                    .accessibilityIdentifier("live.room.more")
                                }
                            }
                            .frame(maxWidth: 420, alignment: .leading)
                            if closeOnBottom {
                                Spacer(minLength: 12)
                                backCapsule(action: onLeaveRoom, id: "live.room.close", minHeight: 44)
                                    .modifier(DYRailReservedNudge())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, hSize == .compact ? 82 : 18)
                    .padding(.top, topInset)
                    .padding(.bottom, DYLiveKeyboardLayout.bottomPadding(
                        safeBottom: geo.safeAreaInsets.bottom,
                        keyboardOverlap: isCurrent ? keyboardOverlap : 0))
                } else {
                    // 预览态与推荐流里刷到的直播卡同一套布局（文案在左下、进房按钮在画面中下）
                    DYLivePreviewCardChrome(room: room, enterID: "live.room.enter", onOpen: model.enterRoom)
                }
                }
                .background {
                    if isCurrent, let axis = ambientAxis {
                        DouyinLiveAmbientBackground(
                            coverURL: room.cover.flatMap(URL.init(string:)),
                            axis: axis,
                            isolationID: isolationID)
                            .clipped()
                            .allowsHitTesting(false)
                    }
                }
                .placed(in: interaction)
            }
            .foregroundStyle(foreground)
        }
        #if DEBUG
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.page.\(room.id)")
        #endif
    }

    private var avatar: some View {
        CachedAsyncImage(url: room.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
            placeholder: { theme.media.chromeFill.color(for: scheme) }
            .frame(width: 36, height: 36).clipShape(Circle())
    }
    private func header(showsClose: Bool) -> some View {
        // 直播间唯一的返回键：与「我的 / 信息 / 网页版」页同款标题 + chevron.backward 符号。
        // 外屏和半折叠仍放左上，右上留给系统状态栏/前摄挖孔。
        // 完全展开的内屏改放右下，避免被内屏系统层盖住，并离开左下聊天和更多按钮。
        // 主视图不再挂 NavigationStack / toolbar，Duo 系统侧栏不会再多渲染一颗返回。
        HStack(spacing: 10) {
            if showsClose {
                backCapsule(action: onLeaveRoom, id: "live.room.close")
            }
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.owner).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(room.viewers) 在看").font(.caption2)
                }
            }.padding(.trailing, 12).padding(.leading, 4).padding(.vertical, 4).ddGlassCapsule()
            Spacer(minLength: 8)
        }
    }
    /// 和 douyin.web.back / douyin.mine.back / douyin.messages.back 同一套返回键语义：
    /// 「返回」标题 + chevron.backward 符号 + 胶囊底。直播间只保留这一颗，不再叠加系统侧栏返回。
    private func backCapsule(action: @escaping () -> Void, id: String, minHeight: CGFloat = 40) -> some View {
        Button(action: action) {
            Label("返回", systemImage: "chevron.backward")
                .font(.system(size: theme.typography.pointSize(.headline), weight: .semibold))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .padding(.horizontal, 14).frame(minWidth: 44).frame(height: minHeight)
                .background(Capsule().fill(theme.media.chromeFill.color(for: scheme)))
        }
        .buttonStyle(.plain)
        .themeShadow(.floatingPanel)
        .accessibilityIdentifier(id)
    }
}

// MARK: - live-close-placement
enum DYLiveChromePlacement {
    /// 只有完全展开的内屏（regular 且折痕未激活）把关闭按钮放到右下。
    /// 外屏是 compact；半折叠时折痕激活，两者都保持左上。
    static func closeOnBottomTrailing(regularWidth: Bool, foldActive: Bool) -> Bool {
        regularWidth && !foldActive
    }
}
// MARK: - live-close-placement-end

// MARK: - live-layout-toggle
enum DYLiveLayoutToggleRole: Equatable {
    case hidden
    case enterImmersive
    case restoreSplit
}

struct DYLiveLayoutTogglePlacement: Equatable {
    var role: DYLiveLayoutToggleRole
    var frame: CGRect
}

enum DYLiveLayoutToggle {
    static let spacing: CGFloat = 12
    static let controlSize = CGSize(width: 72, height: 36)
    static let returnHeight: CGFloat = 40
    static let returnLeading: CGFloat = 18
    static let composerHeight: CGFloat = 44
    static let composerMaxWidth: CGFloat = 420

    static func returnTopInset(paneMinY: CGFloat, compact: Bool) -> CGFloat {
        paneMinY > 24 ? 12 : (compact ? 64 : 70)
    }

    /// 手动整屏只跟着当时那一种分屏。换成另一种分屏、竖屏或不支持时取消。
    static func manualApplies(active: Bool, anchored: DYLiveAdaptiveLayout, eligible: DYLiveAdaptiveLayout) -> Bool {
        active && anchored == eligible && eligible != .existing
    }

    static func place(
        eligible: DYLiveAdaptiveLayout,
        manual: Bool,
        bounds: CGRect,
        interaction: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        keyboardOverlap: CGFloat,
        entered: Bool
    ) -> DYLiveLayoutTogglePlacement {
        guard eligible == .layoutA || eligible == .layoutB else {
            return DYLiveLayoutTogglePlacement(role: .hidden, frame: .zero)
        }
        if manual {
            return DYLiveLayoutTogglePlacement(
                role: .restoreSplit,
                frame: restoreFrame(bounds: bounds, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing, keyboardOverlap: keyboardOverlap))
        }
        let frame = eligible == .layoutA
            ? layoutAFrame(interaction: interaction, compact: compact, safeTrailing: safeTrailing)
            : layoutBFrame(interaction: interaction, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing, entered: entered)
        return DYLiveLayoutTogglePlacement(role: .enterImmersive, frame: frame)
    }

    private static func trailingInset(compact: Bool, safeTrailing: CGFloat) -> CGFloat {
        max(compact ? 82 : 18, safeTrailing)
    }

    private static func layoutAFrame(interaction: CGRect, compact: Bool, safeTrailing: CGFloat) -> CGRect {
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        return CGRect(
            x: interaction.maxX - trailing - controlSize.width,
            y: interaction.minY + spacing,
            width: controlSize.width,
            height: controlSize.height)
    }

    private static func layoutBFrame(
        interaction: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        entered: Bool
    ) -> CGRect {
        guard entered else {
            return layoutBPreviewFrame(interaction: interaction, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing)
        }
        let top = returnTopInset(paneMinY: interaction.minY, compact: compact)
        return CGRect(
            x: interaction.minX + returnLeading,
            y: interaction.minY + top + returnHeight + spacing,
            width: controlSize.width,
            height: controlSize.height)
    }

    /// 预览还没有进房「返回」。整屏改放右窗格右下，避开进入按钮。
    private static func layoutBPreviewFrame(
        interaction: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat
    ) -> CGRect {
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        let bottom = DYLiveKeyboardLayout.bottomPadding(safeBottom: safeBottom, keyboardOverlap: 0)
        var frame = CGRect(
            x: interaction.maxX - trailing - controlSize.width,
            y: interaction.maxY - bottom - controlSize.height,
            width: controlSize.width,
            height: controlSize.height)
        let entry = previewEntryFrame(interaction: interaction, safeBottom: safeBottom)
        if frame.intersects(entry) {
            frame.origin.y = entry.minY - spacing - controlSize.height
        }
        return frame
    }

    private static func previewEntryFrame(interaction: CGRect, safeBottom: CGFloat) -> CGRect {
        let bottom = max(safeBottom, 12) + 24
        let width = min(168, max(0, interaction.width - 40))
        return CGRect(
            x: interaction.minX + 20,
            y: interaction.maxY - bottom - 44,
            width: width,
            height: 44)
    }

    private static func restoreFrame(
        bounds: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        keyboardOverlap: CGFloat
    ) -> CGRect {
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        let bottom = DYLiveKeyboardLayout.bottomPadding(safeBottom: safeBottom, keyboardOverlap: keyboardOverlap)
        var frame = CGRect(
            x: bounds.maxX - trailing - controlSize.width,
            y: bounds.maxY - bottom - controlSize.height,
            width: controlSize.width,
            height: controlSize.height)
        let composer = composerFrame(bounds: bounds, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing, keyboardOverlap: keyboardOverlap)
        if frame.intersects(composer) {
            frame.origin.y = composer.minY - spacing - controlSize.height
        }
        return frame
    }

    private static func composerFrame(
        bounds: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        keyboardOverlap: CGFloat
    ) -> CGRect {
        let leading = returnLeading
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        let bottom = DYLiveKeyboardLayout.bottomPadding(safeBottom: safeBottom, keyboardOverlap: keyboardOverlap)
        let available = max(0, bounds.width - leading - trailing)
        return CGRect(
            x: bounds.minX + leading,
            y: bounds.maxY - bottom - composerHeight,
            width: min(composerMaxWidth, available),
            height: composerHeight)
    }

    /// 布局 A 的模块圆钮放在下窗格右下。边距沿用分屏按钮的 12pt，再加安全区。
    /// 窗格太矮、右下角会压住「整屏」或「进入直播间」时，先上移，再改到「整屏」左侧。
    static func layoutAModuleFrame(
        interaction: CGRect,
        button: CGSize,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat
    ) -> CGRect {
        let margin = spacing
        let width = max(0, button.width)
        let height = max(0, button.height)
        var frame = CGRect(
            x: interaction.maxX - max(0, safeTrailing) - margin - width,
            y: interaction.maxY - max(0, safeBottom) - margin - height,
            width: width,
            height: height)
        frame.origin.x = clamped(frame.origin.x, min: interaction.minX + margin, max: interaction.maxX - margin - width)
        frame.origin.y = clamped(frame.origin.y, min: interaction.minY + margin, max: interaction.maxY - margin - height)
        let entry = previewEntryFrame(interaction: interaction, safeBottom: safeBottom)
        if frame.intersects(entry) {
            let lifted = entry.minY - spacing - height
            if lifted >= interaction.minY + margin { frame.origin.y = lifted }
        }
        let toggle = layoutAFrame(interaction: interaction, compact: compact, safeTrailing: safeTrailing)
        if frame.intersects(toggle) {
            let lifted = toggle.minY - spacing - height
            if lifted >= interaction.minY + margin {
                frame.origin.y = lifted
            } else {
                let beside = toggle.minX - spacing - width
                if beside >= interaction.minX + margin { frame.origin.x = beside }
            }
        }
        frame.origin.x = clamped(frame.origin.x, min: interaction.minX + margin, max: interaction.maxX - margin - width)
        frame.origin.y = clamped(frame.origin.y, min: interaction.minY + margin, max: interaction.maxY - margin - height)
        return frame
    }

    private static func clamped(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}
// MARK: - live-layout-toggle-end

// MARK: - live-keyboard-layout
enum DYLiveKeyboardLayout {
    /// 只计算贴住视口底边的键盘。悬浮键盘不顶起分页。
    static func overlap(viewportMinY: CGFloat, viewportMaxY: CGFloat, keyboardMinY: CGFloat, keyboardMaxY: CGFloat) -> CGFloat {
        guard keyboardMaxY >= viewportMaxY - 1 else { return 0 }
        let covered = min(viewportMaxY, keyboardMaxY) - max(viewportMinY, keyboardMinY)
        guard covered > 0 else { return 0 }
        return min(covered, max(0, viewportMaxY - viewportMinY))
    }

    /// 键盘收起时保留原来的底部留白；弹出后评论栏贴在键盘上沿，不再叠加安全区。
    static func bottomPadding(safeBottom: CGFloat, keyboardOverlap: CGFloat) -> CGFloat {
        let resting = max(safeBottom, 12) + 12
        guard keyboardOverlap > 1 else { return resting }
        return keyboardOverlap + 12
    }
}

/// 只在键盘占用期间关掉分页 ScrollView 的自动 inset。收起后恢复系统 inset，避免平时把页面顶进状态栏。
private struct DYLivePagingKeyboardLock: UIViewRepresentable {
    var locked: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let locked = locked
        DispatchQueue.main.async { apply(locked, from: uiView) }
    }

    private func apply(_ locked: Bool, from view: UIView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView {
                let behavior: UIScrollView.ContentInsetAdjustmentBehavior = locked ? .never : .automatic
                if scroll.contentInsetAdjustmentBehavior != behavior {
                    scroll.contentInsetAdjustmentBehavior = behavior
                }
                scroll.automaticallyAdjustsScrollIndicatorInsets = !locked
                return
            }
            ancestor = current.superview
        }
    }
}
// MARK: - live-keyboard-layout-end

private struct DYLiveCategories: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let selection: DYLiveZone?
    let onSelect: (DYLiveZone?) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 14) {
                    ForEach([nil] + DYLiveZone.all.map(Optional.some), id: \.self) { zone in
                        Button { onSelect(zone) } label: {
                            HStack {
                                Text(zone?.name ?? "推荐直播").font(.subheadline)
                                if selection == zone { Image(systemName: "checkmark").font(.caption) }
                            }
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .foregroundStyle(theme.media.onMedia.color(for: scheme))
                            .ddGlassCapsule()
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }
            .navigationTitle("直播分类").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("live.categories.close")
                }
            }
        }
    }
}

@MainActor
private final class DYFollowLiveList: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready, empty, notLoggedIn, failed, decodeFailed, filtered
    }

    @Published var rooms: [DYLiveRoom] = []
    @Published private(set) var phase: Phase = .idle
    @Published var resolvingID: String?
    @Published var selectionMessage: String?
    private var token = UUID()
    private var task: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var selection = DYFollowSelection()
    private var didRetryStale = false

    func reload(_ bridge: DouyinBridge, refresh: Bool = false) {
        task?.cancel()
        resolveTask?.cancel()
        selection.cancel()
        resolvingID = selection.resolvingID
        selectionMessage = nil
        let token = UUID()
        self.token = token
        #if DEBUG
        if let mocked = Self.mocked() {
            rooms = mocked.rooms
            phase = mocked.phase
            return
        }
        #endif
        phase = .loading
        let started = ProcessInfo.processInfo.systemUptime
        task = Task {
            let result = await bridge.followLiveResult(ignoreCache: refresh)
            guard !Task.isCancelled, token == self.token else { return }
            if result.stale {
                guard !didRetryStale else {
                    rooms = []
                    phase = .failed
                    return
                }
                didRetryStale = true
                reload(bridge)
                return
            }
            didRetryStale = false
            switch result.kind {
            case .rooms where !result.items.isEmpty:
                rooms = result.items
                phase = .ready
            case .nobodyLive:
                rooms = []
                phase = .empty
            case .notLoggedIn:
                rooms = []
                phase = .notLoggedIn
            case .filtered:
                rooms = []
                phase = .filtered
            case .requestFailed:
                rooms = []
                phase = .failed
            case .rooms, .decodeFailed, .unexpectedShape:
                rooms = []
                phase = .decodeFailed
            }
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            DYLiveModel.log("DDFOLLOWLIST phase=\(self.phase) n=\(self.rooms.count) elapsed=\(elapsed) cache=\(result.fromCache ? 1 : 0) listRequests=\(result.fromCache ? 0 : 1) detailRequests=0")
        }
    }

    func pick(_ room: DYLiveRoom, bridge: DouyinBridge, open: @escaping (DYLiveRoom) -> Void) {
        resolveTask?.cancel()
        selectionMessage = nil
        let ticket = selection.begin(roomID: room.id, webRid: room.webRid, hasStream: !room.liveStreams.isEmpty)
        resolvingID = selection.resolvingID
        guard room.liveStreams.isEmpty else {
            guard selection.isCurrent(roomID: room.id, token: ticket) else { return }
            DYLiveModel.log("DDFOLLOWPLAY outcome=ready reused=1 detailRequests=0 elapsed=0.000")
            open(room)
            return
        }
        guard !room.webRid.isEmpty else {
            selectionMessage = DYFollowSelectionFailure.unavailable.message
            return
        }
        selection.startResolving(roomID: room.id)
        resolvingID = selection.resolvingID
        let started = ProcessInfo.processInfo.systemUptime
        resolveTask = Task {
            let result = await bridge.resolveFollowRoom(webRid: room.webRid)
            guard selection.complete(roomID: room.id, token: ticket) else { return }
            resolvingID = selection.resolvingID
            guard !Task.isCancelled else { return }
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            if result.stale { return }
            if result.kind == .notLoggedIn {
                DYLiveModel.log("DDFOLLOWPLAY outcome=notLoggedIn reused=0 detailRequests=1 elapsed=\(elapsed)")
                rooms = []
                phase = .notLoggedIn
                return
            }
            if result.kind == .rooms, let resolved = result.items.first, !resolved.liveStreams.isEmpty {
                DYLiveModel.log("DDFOLLOWPLAY outcome=ready reused=0 detailRequests=1 elapsed=\(elapsed)")
                open(DYLiveRoom(playback: resolved, fallback: room))
                return
            }
            let failure = DYFollowSelectionFailure.from(kind: result.kind, hasPlayableRoom: false) ?? .unavailable
            DYLiveModel.log("DDFOLLOWPLAY outcome=\(failure) reused=0 detailRequests=1 elapsed=\(elapsed)")
            selectionMessage = failure.message
        }
    }

    func cancel() {
        task?.cancel()
        resolveTask?.cancel()
        selection.cancel()
        token = UUID()
        resolvingID = selection.resolvingID
    }

    #if DEBUG
    private static func mocked() -> (phase: Phase, rooms: [DYLiveRoom])? {
        switch ProcessInfo.processInfo.environment["DOUDUO_FOLLOWMOCK"] {
        case "rooms": return (.ready, DYLiveRoom.debugFollowed())
        case "empty": return (.empty, [])
        case "login": return (.notLoggedIn, [])
        case "failed": return (.failed, [])
        case "decode": return (.decodeFailed, [])
        case "filtered": return (.filtered, [])
        default: return nil
        }
    }
    #endif
}

// MARK: - follow-live-sheet-layout
enum DYFollowLiveSheetLayout {
    static let minimumTap: CGFloat = 44
    static let ringWidth: CGFloat = 2
    static let expandedContentWidth: CGFloat = 520
    static let navigationChrome: CGFloat = 64
    static let bottomAllowance: CGFloat = 36
    static let messageHeight: CGFloat = 44

    static func avatarSide(regularWidth: Bool) -> CGFloat { regularWidth ? 64 : 56 }
    static func rowSpacing(regularWidth: Bool) -> CGFloat { regularWidth ? 12 : 6 }
    static func rowVerticalPadding(regularWidth: Bool) -> CGFloat { regularWidth ? 8 : 6 }
    static let listVerticalPadding: CGFloat = 8
    static func maximumSheetHeight(regularWidth: Bool) -> CGFloat { regularWidth ? 640 : 520 }

    static func contentMaxWidth(regularWidth: Bool) -> CGFloat {
        regularWidth ? expandedContentWidth : .infinity
    }

    static func rowHeight(regularWidth: Bool) -> CGFloat {
        let avatar = avatarSide(regularWidth: regularWidth) + ringWidth * 2
        let padded = avatar + rowVerticalPadding(regularWidth: regularWidth) * 2
        return max(padded, minimumTap)
    }

    /// 按行数估算 sheet 高度，并限制在一屏可放下的上限内。人少时不拉高，人多时只让列表滚动。
    static func sheetHeight(rowCount: Int, regularWidth: Bool, showsMessage: Bool) -> CGFloat {
        let maximum = maximumSheetHeight(regularWidth: regularWidth)
        let message = showsMessage ? messageHeight : 0
        guard rowCount > 0 else {
            return min(navigationChrome + bottomAllowance + 168 + message, maximum)
        }
        let spacing = rowSpacing(regularWidth: regularWidth)
        let rows = CGFloat(rowCount) * rowHeight(regularWidth: regularWidth)
        let gaps = CGFloat(rowCount - 1) * spacing
        let raw = navigationChrome + bottomAllowance + message + rows + gaps + listVerticalPadding * 2
        return min(max(raw, navigationChrome + minimumTap), maximum)
    }
}
// MARK: - follow-live-sheet-layout-end

private struct DYFollowLiveSheet: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @ObservedObject var bridge: DouyinBridge
    let onPick: (DYLiveRoom) -> Void
    let onLogin: () -> Void
    @StateObject private var model = DYFollowLiveList()
    @State private var foldActive = false
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }
    private var secondary: Color { theme.media.onMediaSecondary.color(for: scheme) }
    private var regularWidth: Bool { hSize == .regular && !foldActive }
    private var sheetDetent: CGFloat {
        DYFollowLiveSheetLayout.sheetHeight(
            rowCount: model.phase == .ready ? model.rooms.count : 0,
            regularWidth: regularWidth,
            showsMessage: model.selectionMessage != nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle, .loading:
                    ProgressView("加载我的关注…").tint(foreground)
                case .ready:
                    VStack(alignment: .leading, spacing: 0) {
                        if let message = model.selectionMessage {
                            Text(message)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                                .accessibilityIdentifier("live.follow.selection")
                        }
                        list
                    }
                case .empty:
                    notice("关注的人现在没有在直播", id: "live.follow.empty", action: "刷新") { model.reload(bridge, refresh: true) }
                case .notLoggedIn:
                    notice("抖音未登录，登录后才能看到关注的直播", id: "live.follow.login", action: "网页版 / 登录", actionID: "live.follow.login.button", onLogin)
                case .failed:
                    notice("我的关注加载失败", id: "live.follow.failed", action: "重试") { model.reload(bridge, refresh: true) }
                case .decodeFailed:
                    notice("直播数据无法解析", id: "live.follow.decode", action: "重试") { model.reload(bridge, refresh: true) }
                case .filtered:
                    notice("关注的人正在直播，但暂时没有可播放的线路", id: "live.follow.filtered", action: "重试") { model.reload(bridge, refresh: true) }
                }
            }
            .frame(maxWidth: DYFollowLiveSheetLayout.contentMaxWidth(regularWidth: regularWidth), maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(foreground)
            .navigationTitle("我的关注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新") { model.reload(bridge, refresh: true) }
                        .disabled(model.phase == .loading)
                        .accessibilityIdentifier("live.follow.refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("live.follow.close")
                }
            }
        }
        .background {
            DYFollowFoldReader { foldActive = $0 }
        }
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.height(sheetDetent)])
        .presentationBackground(.black)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .task { model.reload(bridge) }
        .onChange(of: bridge.followSession) { _, _ in
            model.rooms = []
            model.reload(bridge)
        }
        .onDisappear { model.cancel() }
    }

    @Environment(\.dismiss) private var dismiss

    private var list: some View {
        let side = DYFollowLiveSheetLayout.avatarSide(regularWidth: regularWidth)
        return ScrollView {
            LazyVStack(spacing: DYFollowLiveSheetLayout.rowSpacing(regularWidth: regularWidth)) {
                ForEach(model.rooms) { room in
                    Button { model.pick(room, bridge: bridge, open: onPick) } label: {
                        HStack(spacing: 12) {
                            liveAvatar(room, side: side)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(room.owner.isEmpty ? "未命名主播" : room.owner)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                HStack(spacing: 8) {
                                    Text("直播中")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(theme.media.onMedia.color(for: scheme))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                                    if !room.viewers.isEmpty {
                                        Text("\(room.viewers) 在看")
                                            .font(.subheadline)
                                            .foregroundStyle(secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            if model.resolvingID == room.id {
                                ProgressView().controlSize(.small).tint(foreground)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(secondary.opacity(0.75))
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, DYFollowLiveSheetLayout.rowVerticalPadding(regularWidth: regularWidth))
                        .frame(maxWidth: .infinity, minHeight: DYFollowLiveSheetLayout.minimumTap, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("live.follow.room.\(room.id)")
                    .accessibilityLabel(rowLabel(room))
                }
            }
            .padding(.vertical, DYFollowLiveSheetLayout.listVerticalPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("live.follow.list")
    }

    private func rowLabel(_ room: DYLiveRoom) -> String {
        let name = room.owner.isEmpty ? "未命名主播" : room.owner
        if room.viewers.isEmpty { return "\(name)，直播中" }
        return "\(name)，直播中，\(room.viewers) 在看"
    }

    private func liveAvatar(_ room: DYLiveRoom, side: CGFloat) -> some View {
        CachedAsyncImage(url: room.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
            placeholder: { theme.media.chromeFill.color(for: scheme) }
            .frame(width: side, height: side)
            .clipShape(Circle())
            .padding(DYFollowLiveSheetLayout.ringWidth)
            .overlay(Circle().stroke(theme.status.danger.color(for: scheme), lineWidth: DYFollowLiveSheetLayout.ringWidth))
    }

    private func notice(_ text: String, id: String, action: String, actionID: String? = nil, _ run: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(text).font(.footnote).multilineTextAlignment(.center).accessibilityIdentifier(id)
            Button(action, action: run)
                .buttonStyle(.bordered)
                .accessibilityIdentifier(actionID ?? "\(id).action")
        }
        .padding(24)
    }
}

private struct DYFollowFoldReader: View {
    var onChange: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let active = DYDuoMetrics.foldIsActive(geo)
            Color.clear
                .onAppear { onChange(active) }
                .onChange(of: active) { _, value in onChange(value) }
        }
        .allowsHitTesting(false)
    }
}

#if DEBUG
extension DYLiveRoom {
    static func debugRoom(_ id: String, owner: String, title: String, viewers: String) -> DYLiveRoom {
        DYLiveRoom(id: id, webRid: id, title: title, owner: owner, avatar: nil, cover: nil, viewers: viewers,
                   hls: ["HD1": "https://example.com/\(id).m3u8"], portrait: true, def: "HD1")
    }

    static func debugFeed() -> [DYLiveRoom] {
        [debugRoom("rec-a", owner: "推荐甲", title: "推荐直播甲", viewers: "10"),
         debugRoom("rec-b", owner: "推荐乙", title: "推荐直播乙", viewers: "20")]
    }

    static func debugFollowed() -> [DYLiveRoom] {
        [debugRoom("fol-a", owner: "关注甲", title: "关注直播甲", viewers: "30"),
         debugRoom("fol-b", owner: "关注乙", title: "关注直播乙", viewers: "")]
    }
}
#endif
