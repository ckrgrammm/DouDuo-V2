import SwiftUI
import UIKit
import AVFoundation

/// 前后台过渡用 AppDelegate。Scene 的 onChange 在部分切后台路径下不触发。
/// 短视频仍在这里暂停。直播继续或静音由「后台直播声音」在同一条生命周期里决定。
final class DouDuoAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillResignActive(_ application: UIApplication) {
        DDPlayback.shared.pauseForInactivity()
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        DDPlayback.shared.pauseAll()
    }
    func applicationDidBecomeActive(_ application: UIApplication) {
        // 只有「之前真被切过后台」才恢复，避免启动时抢跑播放
        DDPlayback.shared.resumeAll()
    }

    #if DEBUG
    private let _launch = DDLaunch.t0
    #endif
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = DDThermal.shared   // 启动即开始记录温度档（DDTHERMAL）
        #if DEBUG
        // 自动测试用：DOUDUO_CHROME_MODE=classic|rail|minimal 启动时写入界面模式（不用 -key 启动参数，那会盖住运行时修改）
        if let m = ProcessInfo.processInfo.environment["DOUDUO_CHROME_MODE"] { UserDefaults.standard.set(m, forKey: "douyin_chrome_mode_v1") }
        #endif
        #if DEBUG
        // 自动测试用：DOUDUO_ACTTEST=<aweme_id> → 起播后直接打点赞/收藏接口，结果写 ddlog
        if let aid = ProcessInfo.processInfo.environment["DOUDUO_ACTTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                Task { @MainActor in
                    let bridge = actTestBridge
                    do {
                        let ok = try await bridge.digg(aid, like: true)
                        LocalVideoLaunch.log("DDACTTEST digg ok=\(ok)")
                        let ok2 = try await bridge.digg(aid, like: false)
                        LocalVideoLaunch.log("DDACTTEST undigg ok=\(ok2)")
                    } catch { LocalVideoLaunch.log("DDACTTEST digg error \(error)") }
                    do {
                        let f = try await bridge.favorite(aid, add: true)
                        LocalVideoLaunch.log("DDACTTEST fav ok=\(f)")
                    } catch { LocalVideoLaunch.log("DDACTTEST fav error \(error)") }
                }
            }
        }
        // 自动测试用：DOUDUO_LIVETEST=1 → 对比不同 Referer 下是否能拿到视频轨
        if ProcessInfo.processInfo.environment["DOUDUO_LIVETEST"] == "1" {
            Task { @MainActor in
                let rooms = (try? await actTestBridge.fetchLive(reset: true)) ?? []
                LocalVideoLaunch.log("DDLIVE rooms=\(rooms.count)")
                for (i, r) in rooms.prefix(4).enumerated() {
                    guard let u = r.bestHLS else { continue }
                    for ref in ["https://live.douyin.com/", "https://live.douyin.com/\(r.webRid)", "https://www.douyin.com/"] {
                        var h = DYMedia.headers
                        h["Referer"] = ref
                        let asset = AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": h])
                        let item = AVPlayerItem(asset: asset)
                        let p = AVPlayer(playerItem: item)
                        p.play()
                        try? await Task.sleep(nanoseconds: 7_000_000_000)
                        if i == 0, ref.hasSuffix(".com/") { LocalVideoLaunch.log("DDLIVEURL \(u.absoluteString)") }
                        LocalVideoLaunch.log("DDLIVE #\(i) ref=\(ref.suffix(12)) st=\(item.status.rawValue) size=\(item.presentationSize) n=\(item.tracks.count) types=\(item.tracks.compactMap { $0.assetTrack?.mediaType.rawValue }.joined(separator: ",")) t=\(String(format: "%.1f", p.currentTime().seconds))")
                        p.pause()
                    }
                }
                LocalVideoLaunch.log("DDLIVE done")
            }
        }
        // 自动测试用：DOUDUO_BGTEST=1 → 起播 20 秒后模拟一次「进后台」，验证停声链路
        if ProcessInfo.processInfo.environment["DOUDUO_BGTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                LocalVideoLaunch.log("DDBG bgtest pauseAll")
                DDPlayback.shared.pauseAll()
            }
        }
        #endif
        return true
    }
}

@main
struct DouDuoApp: App {
    @UIApplicationDelegateAdaptor(DouDuoAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DDPerf.mark("app.init")
        // 信息里的图片 / 封面都走网页：默认 URLCache 又小又以内存为主，进聊天每次都重下（上游 1.5.2）。
        // 放大到 512MB 磁盘（跨启动复用）。
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20, diskPath: "dd-url-cache")
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_TITLETEST"] == "1" {
                DYTitleLayoutProbe()
            } else if let target = LocalVideoLaunch.target {
                LocalVideoPlaybackView(url: target.url, fillWidth: target.fill)
            } else {
                DouyinFeedScreen()
                    .preferredColorScheme(.dark)
            }
            #else
            DouyinFeedScreen()
                .preferredColorScheme(.dark)
            #endif
        }
        // 退到后台 / 锁屏：短视频按「后台播放」停声。直播走同一条恢复，是否出声看「后台直播声音」。
        // 回到前台会先经过 inactive。这里如果当成后台，会把刚刚恢复的直播立刻停掉。
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            LocalVideoLaunch.log("DDSCENE phase=\(String(describing: phase))")
            #endif
            let signal: DYLiveSceneSignal
            switch phase {
            case .active: signal = .active
            case .background: signal = .background
            case .inactive: signal = .inactive
            @unknown default: signal = .inactive
            }
            switch DYLivePlaybackGate.sceneCommand(signal) {
            case .pause: DDPlayback.shared.pauseAll()
            case .resume: DDPlayback.shared.resumeAll()
            case .none: break
            }
        }
    }
}

#if DEBUG
/// 给 DOUDUO_ACTTEST 用的、独立于界面的桥接实例
@MainActor
let actTestBridge = DouyinBridge()

/// 用法：启动环境变量 DOUDUO_LOCALVIDEO=<Documents 里的文件名或绝对路径> [DOUDUO_LOCALFIT=0]
/// 直接把本地视频丢进播放页，用来核对「自动铺满宽度」的裁切效果。
enum LocalVideoLaunch {
    static func log(_ s: String) {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddlog.txt")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: u) }
    }
    static var target: (url: URL, fill: Bool)? {
        let env = ProcessInfo.processInfo.environment
        guard let p = env["DOUDUO_LOCALVIDEO"] else { return nil }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(p)
        return (url, env["DOUDUO_LOCALFIT"] != "0")
    }
}

struct LocalVideoPlaybackView: View {
    let url: URL
    let fillWidth: Bool
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerPage.external(id: "local", title: url.lastPathComponent, url: url, durationSec: 20,
                                isActive: true, topInset: 0, bottomInset: 0, resumePosition: nil,
                                compactChrome: true, onEnded: nil, onDoubleTap: nil,
                                onSavePosition: { _ in }, onClose: {}, fillWidth: fillWidth)
        }
        .preferredColorScheme(.dark)
    }
}
#endif

#if DEBUG
/// 接口探针：DOUDUO_APITEST=1，用界面里那个挂在窗口上的签名页跑
@MainActor enum DDApiProbe {
    static func run(_ b: DouyinBridge) async {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                let pre = #"""
                const sum = (name, r) => {
                  const d = parse(r.t) || {};
                  const lists = Object.keys(d).filter(k => Array.isArray(d[k])).map(k => k + ':' + d[k].length).join(',');
                  return name + ' http=' + r.s + ' code=' + d.status_code + ' msg=' + (d.status_msg || '') + ' lists=[' + lists + '] more=' + d.has_more + ' cur=' + (d.cursor ?? d.max_cursor) + ' keys=' + Object.keys(d).slice(0, 14).join('|') + (Object.keys(d).length ? '' : ' raw=' + (r.t || '').slice(0, 80));
                };
                """#
                // 先拿一条有评论的推荐视频
                let pick = await b.probe(pre + #"""
                const fr = await req('POST', '/aweme/v2/web/module/feed/?' + q({ module_id: '3003101', count: '10', refresh_index: '3', pull_type: '2', refer_type: '10' }), '');
                const list = (parse(fr.t) || {}).aweme_list || [];
                const a = list.find(a => a && a.statistics && a.statistics.comment_count > 50) || list[0] || {};
                return [a.aweme_id, (a.video && a.video.duration) || 60000, (a.author && a.author.sec_uid) || ''].join(' ');
                """#)
                LocalVideoLaunch.log("DDAPI pick=\(pick)")
                let parts = pick.split(separator: " ").map(String.init)
                _ = parts
                let base1 = "search_channel: 'aweme_video_web', keyword: '猫', search_source: 'normal_search', query_correct_type: '1', is_filter_search: '0', from_group_id: '', list_type: 'single'"
                let tests: [(String, String)] = [
                    ("p1", "const r = await req('GET', '/aweme/v1/web/search/item/?' + q({ \(base1), offset: '0', count: '16', need_filter_settings: '1' })); const d = parse(r.t) || {}; window.__sid = (d.log_pb||{}).impr_id || (d.extra||{}).logid || ''; return sum('p1', r) + ' impr=' + window.__sid + ' extra=' + JSON.stringify(d.extra||{}).slice(0,120);"),
                    ("p2-plain", "return sum('p2-plain', await req('GET', '/aweme/v1/web/search/item/?' + q({ \(base1), offset: '16', count: '16', need_filter_settings: '0' })));"),
                    ("p2-sid", "return sum('p2-sid', await req('GET', '/aweme/v1/web/search/item/?' + q({ \(base1), offset: '16', count: '16', need_filter_settings: '0', search_id: window.__sid || '' })));"),
                    ("p2-count10", "return sum('p2-count10', await req('GET', '/aweme/v1/web/search/item/?' + q({ \(base1), offset: '10', count: '10', need_filter_settings: '0', search_id: window.__sid || '' })));"),
                    ("p2-general", "return sum('p2-general', await req('GET', '/aweme/v1/web/general/search/single/?' + q({ search_channel: 'aweme_general', keyword: '猫', search_source: 'normal_search', query_correct_type: '1', is_filter_search: '0', from_group_id: '', offset: '10', count: '10', need_filter_settings: '0', list_type: 'single', search_id: window.__sid || '' })));"),
                ]
                for (name, body) in tests {
                    LocalVideoLaunch.log("DDAPI start \(name)")
                    let r = await withTaskGroup(of: String.self) { g -> String in
                        g.addTask { await b.probe(pre + body) }
                        g.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return "TIMEOUT" }
                        let first = await g.next() ?? "?"
                        g.cancelAll()
                        return first
                    }
                    LocalVideoLaunch.log("DDAPI \(name): " + r.prefix(900))
                }
                LocalVideoLaunch.log("DDAPI done")
            
    }
}
#endif
