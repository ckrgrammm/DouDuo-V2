// 抖音网页版内嵌：官方 App 不适配 iPhone Duo，用电脑版网页模拟 App。
// - 桌面 Safari UA：手机 UA 会被导去下载/唤起 App，电脑版布局自适应任意宽度（Duo 内外屏、横竖屏都铺满）。
// - 拦掉 snssdk / itms 等私有 scheme，抖音域名链接不尝试 Universal Link → 不再自动跳 App。
// - 电脑版 viewport 写死 initial-scale=0.5（手机上字小一半），注入脚本按屏宽重写：宽屏 1 倍，窄屏（Duo 外屏）以 760 布局等比塞满；菜单可调缩放档。
// - 推荐流在电脑版靠键盘 ↑↓ 切视频：注入触屏上下滑 → 方向键，手感接近 App。
// - 登录态存在 WKWebsiteDataStore.default()，退出 App 不丢。
import SwiftUI
import WebKit

enum DouyinWeb {
    static let home = URL(string: "https://www.douyin.com/?recommend=1")!
    static let zoomKey = "douyin_web_zoom_v1"
    static let zoomSteps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25]
    /// 电脑版 Safari UA（不带 Mobile），抖音据此出电脑版且不弹「打开 App」
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// 直接打开 ?recommend=1 首次会被导回「精选」，点导航栏「推荐」才稳
    static let goRecommendJS = "(()=>{const a=[...document.querySelectorAll('a')].find(a=>a.innerText.trim()==='推荐');if(a){a.click();return true}location.href='https://www.douyin.com/?recommend=1';return false})()"

    static let bootstrapJS = #"""
    (() => {
      if (window.__wuweiDouyin) return; window.__wuweiDouyin = true;
      // 1) 适配宽度：电脑版自带 viewport initial-scale=0.5（手机上字小一半），网格两列最小要 ~760px。
      //    改写 viewport：布局宽 L = max(屏宽/缩放档, 760)，scale = 屏宽/L。内屏 1 倍；Duo 外屏竖着（~466pt）760 等比塞满。
      window.__wuweiFixViewport = () => {
        const vw = window.__wuweiViewW || window.screen.width;
        const uz = window.__wuweiZoom || 1;
        const L = Math.round(Math.max(vw / uz, window.__wuweiMinWidth || 760));
        const sc = (vw / L).toFixed(4);
        const want = `width=${L},initial-scale=${sc},minimum-scale=${sc},maximum-scale=${sc},user-scalable=no,viewport-fit=cover`;
        let m = document.querySelector('meta[name=viewport]');
        if (!m) { if (!document.head) return; m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); }
        if (m.content !== want) {
          m.content = want;
          // 页面的网格列宽由 JS 按窗口宽算，改完 viewport 补发 resize 让它重排
          clearTimeout(window.__wuweiRz);
          window.__wuweiRz = setTimeout(() => window.dispatchEvent(new Event('resize')), 60);
        }
      };
      const fixViewport = window.__wuweiFixViewport;
      fixViewport();
      new MutationObserver(fixViewport).observe(document.documentElement, { childList: true, subtree: true });
      // 2) 推荐流：触屏上下滑 → ↑↓ 方向键切视频
      let sx = 0, sy = 0, st = 0, armed = false;
      const inFeed = t => {
        if (!t || !t.closest) return false;
        if (t.closest('[data-e2e="comment-list"], [class*="comment"], input, textarea')) return false;
        return !!t.closest('[data-e2e="feed-active-video"], [data-e2e="slideList"]');
      };
      const key = k => {
        const o = { key: k, code: k, keyCode: k === 'ArrowDown' ? 40 : 38, which: k === 'ArrowDown' ? 40 : 38, bubbles: true };
        document.dispatchEvent(new KeyboardEvent('keydown', o));
        document.dispatchEvent(new KeyboardEvent('keyup', o));
      };
      window.__wuweiKey = key;
      document.addEventListener('touchstart', e => {
        if (e.touches.length !== 1) { armed = false; return; }
        armed = inFeed(e.target);
        sx = e.touches[0].clientX; sy = e.touches[0].clientY; st = Date.now();
      }, { passive: true, capture: true });
      document.addEventListener('touchmove', e => {
        if (!armed) return;
        const dx = e.touches[0].clientX - sx, dy = e.touches[0].clientY - sy;
        if (Math.abs(dy) > Math.abs(dx)) e.preventDefault();   // 别让整页跟着滚
      }, { passive: false, capture: true });
      document.addEventListener('touchend', e => {
        if (!armed) return; armed = false;
        const t = e.changedTouches[0]; const dx = t.clientX - sx, dy = t.clientY - sy;
        if (Math.abs(dy) < 50 || Math.abs(dy) < Math.abs(dx) * 1.3 || Date.now() - st > 900) return;
        key(dy < 0 ? 'ArrowDown' : 'ArrowUp');
      }, { passive: true, capture: true });
    })();
    """#
}

/// 首页「影音」里的入口卡点进来：全屏抖音
struct DouyinWebScreen: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DouyinWeb.zoomKey) private var zoom = 1.0
    @StateObject private var model = DouyinWebModel()
    var start: URL = DouyinWeb.home
    @State private var drag: CGSize = .zero
    /// 悬浮钮位置（占屏比例），默认盖在左上角抖音 logo 上（logo 本身只是回首页，菜单里有）
    @AppStorage("douyin_web_handle_x_v2") private var handleX = 0.0
    @AppStorage("douyin_web_handle_y_v2") private var handleY = 0.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                theme.media.strongScrim.color(for: scheme).ignoresSafeArea()
                DouyinWebContainer(model: model, zoom: zoom, start: start)
                    .ignoresSafeArea(edges: [.bottom, .horizontal])
                if model.progress < 1 {
                    ProgressView(value: model.progress)
                        .tint(theme.accent.color(for: scheme))
                        .frame(maxWidth: .infinity)
                }
                // 左上角常驻「返回」：从作者主页 / 网页版一点就回原生页（原来藏在菜单里，找不到会以为回不去）
                HStack(spacing: 8) {
                    Button { dismiss() } label: {
                        Label("返回", systemImage: "chevron.backward")
                            .font(.system(size: theme.typography.pointSize(.headline), weight: .semibold))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme))
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(Capsule().fill(theme.media.chromeFill.color(for: scheme)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.web.back")
                    handle
                }
                .themeShadow(.floatingPanel)
                .padding(.leading, 10)
                .padding(.top, 4)
            }
        }
    }

    private func point(in size: CGSize, extra: CGSize) -> CGPoint {
        let r: CGFloat = 22
        let x = handleX > 0 ? CGFloat(handleX) * size.width : r + 6
        let y = handleY > 0 ? CGFloat(handleY) * size.height : r + 2
        return CGPoint(x: min(max(x + extra.width, r), size.width - r),
                       y: min(max(y + extra.height, r), size.height - r))
    }

    /// 一颗可拖的悬浮钮：点开菜单（关闭 / 后退 / 刷新 / 回推荐 / 缩放）
    private var handle: some View {
        Menu {
            Button("网页后退一页", systemImage: "arrow.uturn.backward") { model.web?.goBack() }
                .disabled(!model.canGoBack)
            Button("刷新", systemImage: "arrow.clockwise") { model.web?.reload() }
            Button("推荐（上下滑）", systemImage: "play.square.stack") { model.web?.evaluateJavaScript(DouyinWeb.goRecommendJS) }
            Picker("页面缩放", selection: $zoom) {
                ForEach(DouyinWeb.zoomSteps, id: \.self) { z in
                    Text("\(Int(z * 100))%").tag(z)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: theme.typography.pointSize(.headline), weight: .semibold))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.media.chromeFill.color(for: scheme)))
        }
        .accessibilityLabel("抖音菜单")
    }
}

@MainActor
final class DouyinWebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var canGoBack = false
    @Published var progress: Double = 0
    weak var web: WKWebView?
    /// 网页 postMessage("ddMsg") 转给 App（如聊天页点分享视频 → 跳原生播放）
    var onAppMessage: ((String) -> Void)?
    private var clickedLogin = false
    private var filledPhone = false
    private var filledCode = false
    private var observers: [NSKeyValueObservation] = []

    func attach(_ wv: WKWebView) {
        web = wv
        observers = [
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                let p = w.estimatedProgress
                Task { @MainActor in self?.progress = p }
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
                let b = w.canGoBack
                Task { @MainActor in self?.canGoBack = b }
            },
        ]
    }

    private static func isDouyinHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return ["douyin.com", "douyinpic.com", "douyinvod.com", "iesdouyin.com", "amemv.com", "snssdk.com", "bytedance.com", "zijieapi.com"]
            .contains { h == $0 || h.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel); return
        }
        // snssdk1128:// / itms-apps:// / aweme:// 等一律拦掉，不唤起 App 也不去 App Store
        guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
            decisionHandler(.cancel); return
        }
        // 抖音系域名：允许但不尝试 Universal Link（WKNavigationActionPolicyAllowWithoutTryingAppLink = .allow + 2）
        if Self.isDouyinHost(url.host), let noAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) {
            decisionHandler(noAppLink); return
        }
        decisionHandler(.allow)
    }

    /// 打开时像 App 一样直接进「推荐」竖屏流（首次访问会被导到精选）
    private var jumpedToFeed = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
        // 模拟器调试：DOUDUO_OPEN=login 时自动点「登录」弹出扫码框
        if ProcessInfo.processInfo.environment["DOUDUO_OPEN"] == "login", !clickedLogin {
            clickedLogin = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                webView.evaluateJavaScript("(()=>{const b=[...document.querySelectorAll('button,div,span,a')].find(e=>e.childElementCount===0&&e.innerText&&e.innerText.trim()==='登录');if(b){b.click();(b.closest('button')||b.parentElement).click();return 'clicked'}return 'none'})()")
                // 登录框窄屏下藏了扫码栏：放宽布局 + 找「扫码」入口点开，把框里的文字写日志方便排查
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let js = """
                    (()=>{
                      const all=[...document.querySelectorAll('*')];
                      const qr=all.find(e=>e.childElementCount===0&&e.innerText&&/扫码/.test(e.innerText.trim())&&e.innerText.trim().length<10);
                      if(qr){qr.click();(qr.parentElement||qr).click();}
                      const ic=all.find(e=>/qrcode|scan|qr-/i.test((e.className&&e.className.baseVal!==undefined?e.className.baseVal:e.className)||''));
                      if(!qr&&ic){ic.click();}
                      const box=all.find(e=>/登录后免费畅享/.test(e.innerText||'')&&e.childElementCount>2&&e.innerText.length<400);
                      const imgs=[...document.querySelectorAll('img,canvas')].filter(i=>{const r=i.getBoundingClientRect();return r.width>100&&r.width<400&&Math.abs(r.width-r.height)<10}).map(i=>i.tagName+':'+Math.round(i.getBoundingClientRect().width)+':'+(i.src||'').slice(0,40));
                      return 'qr='+(qr?qr.innerText:'-')+' icon='+(ic?String(ic.className).slice(0,40):'-')+' squares='+imgs.join(',')+' box='+(box?box.innerText.replace(/\\s+/g,' ').slice(0,200):'-');
                    })()
                    """
                    webView.evaluateJavaScript(js) { r, _ in DYLiveModel.log("DDLOGIN " + String(describing: r ?? "nil")) }
                }
            }
        }
        // 自动填手机号 + 点「获取验证码」（DOUDUO_LOGIN_PHONE=手机号）
        if let phone = ProcessInfo.processInfo.environment["DOUDUO_LOGIN_PHONE"], !phone.isEmpty, !filledPhone {
            filledPhone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                let js = """
                (()=>{
                  const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
                  const ins=[...document.querySelectorAll('input')].filter(i=>i.type==='tel'||/手机号|请输入手机/.test(i.placeholder||''));
                  if(!ins.length) return 'no-input';
                  setter.call(ins[0],'\(phone)');
                  ins[0].dispatchEvent(new Event('input',{bubbles:true}));
                  ins[0].dispatchEvent(new Event('change',{bubbles:true}));
                  ins[0].blur();
                  const btn=[...document.querySelectorAll('button,div,span,a')].find(e=>e.childElementCount===0&&e.innerText&&/获取验证码|发送验证码|获取短信/.test(e.innerText.trim()));
                  if(btn){(btn.closest('button')||btn.parentElement||btn).click();return 'filled+code-sent'}
                  return 'filled-no-btn:'+ins.length;
                })()
                """
                webView.evaluateJavaScript(js) { r, _ in DYLiveModel.log("DDLOGINFILL " + String(describing: r ?? "nil")) }
            }
        }
        // 自动填验证码 + 点登录（DOUDUO_LOGIN_CODE=6位码）
        if let code = ProcessInfo.processInfo.environment["DOUDUO_LOGIN_CODE"], !code.isEmpty, !filledCode {
            filledCode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                let js = """
                (()=>{
                  const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
                  const ins=[...document.querySelectorAll('input')].filter(i=>i.type!=='tel'&&(/验证码|code/i.test(i.placeholder||'')||i.maxLength===6));
                  if(!ins.length) return 'no-code-input';
                  setter.call(ins[0],'\(code)');
                  ins[0].dispatchEvent(new Event('input',{bubbles:true}));
                  ins[0].dispatchEvent(new Event('change',{bubbles:true}));
                  const btn=[...document.querySelectorAll('button,div,span,a')].find(e=>e.childElementCount===0&&e.innerText&&/^登录$|立即登录/.test(e.innerText.trim().replace(/\\s/g,'')));
                  if(btn){(btn.closest('button')||btn.parentElement||btn).click();return 'code+login-clicked'}
                  return 'code-filled-no-btn';
                })()
                """
                webView.evaluateJavaScript(js) { r, _ in DYLiveModel.log("DDLOGINCODE " + String(describing: r ?? "nil")) }
            }
        }
        #endif
        guard !jumpedToFeed, webView.url?.path.hasPrefix("/jingxuan") == true else { return }
        jumpedToFeed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { webView.evaluateJavaScript(DouyinWeb.goRecommendJS) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (webView as? DouyinFitWebView)?.syncViewport()
    }


    /// target=_blank：在当前页打开，别丢
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

/// 网页 → App 消息通道：window.webkit.messageHandlers.ddMsg.postMessage(JSON)
final class DDAppMessageHandler: NSObject, WKScriptMessageHandler {
    private let model: DouyinWebModel
    init(_ model: DouyinWebModel) { self.model = model }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let s = message.body as? String { model.onAppMessage?(s) }
    }
}

/// 聊天页点「分享视频」卡片 → 拦下点击、抽出 aweme_id 发给 App 跳原生播放（只在 /chat 页生效，别处不动）
/// 卡片通常是缩略图不是 <video>：从点击处向上找含媒体特征的消息卡，再从 React props 抽 aweme_id；
/// 抽不到就把卡片 HTML / 类名回传（video-miss / video-probe），用来迭代选择器。
private let ddVideoTapHookJS = #"""
(() => {
  if (window.__ddVideoTapHook) return; window.__ddVideoTapHook = 1;
  const post = (o) => { try { window.webkit.messageHandlers.ddMsg.postMessage(JSON.stringify(o)); } catch (e) {} };
  const findID = (root) => {
    // Verified IM ShareAweme payload: message.parsedContent (aweType=800).
    // Never infer an aweme ID from a user/message ID or an arbitrary DOM attribute.
    const fromMessage = message => {
      try {
        const payload = message.parsedContent || JSON.parse(message.content || 'null');
        const id = payload?.itemId;
        return Number(payload?.aweType) === 800 && typeof id === 'string' && /^\d{15,25}$/.test(id) ? id : null;
      } catch (_) { return null; }
    };
    const seen = new Set();
    for (let n = root, d = 0; n && d < 12; n = n.parentElement, d++) {
      for (const k of Object.keys(n)) {
        if (k.startsWith('__reactProps')) {
          const message = n[k]?.message;
          if (message) return fromMessage(message);
        }
        if (!k.startsWith('__reactFiber') && !k.startsWith('__reactInternalInstance')) continue;
        for (let f = n[k], depth = 0; f && depth < 24 && !seen.has(f); f = f.return, depth++) {
          seen.add(f);
          const message = f.memoizedProps?.message;
          // Stop at this card's nearest message. Never read a sibling/conversation payload.
          if (message) return fromMessage(message);
        }
      }
      if (n.matches?.('[data-e2e="message-item"]')) break;
    }
    return null;
  };
  document.addEventListener('click', (ev) => {
    try {
      if (!/\/chat/.test(location.pathname)) return;
      const t = ev.target;
      const pane = t.closest('[class*="componentsRightPanel"],[class*="rightPanel"]');
      if (!pane) return;
      // 实测类名：分享视频卡 = MessageItemShareAweme* / BulletBulletVideo*
      const media = t.closest('[class*="ShareAweme"],[class*="BulletBulletVideo"],[class*="videoCard"],[class*="VideoCard"]');
      if (!media) return;
      // 严格向上找第一个「消息项」祖先（closest 会命中自身，不能用）
      let card = null;
      for (let n = media.parentElement; n && n !== pane; n = n.parentElement) {
        if (String(n.className || '').includes('MessageItem')) { card = n; break; }
      }
      if (!card) card = media;
      const id = findID(card);
      if (id) {
        ev.preventDefault(); ev.stopPropagation();
        console.log('DDVIDEOTAP jump ' + id);
        post({type: 'video', id: id});
        return;
      }
      // Leave unsupported cards to the official web UI; don't guess an ID.
      post({type: 'video-miss', html: 'shared-video-payload-unavailable'});
    } catch (e) {}
  }, true);
})();
"""#

struct DouyinWebContainer: UIViewRepresentable {
    @ObservedObject var model: DouyinWebModel
    let zoom: Double
    let start: URL
    var reuseExisting = false

    func makeUIView(context: Context) -> WKWebView {
        if reuseExisting, let existing = model.web { return existing }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()            // 登录态持久化
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // 网页全屏按钮走网页自己的全屏（同电脑版），不弹系统播放器；系统播放器退出后网页还以为在全屏，再点就没反应
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile   // 电脑版靠 UA；.desktop 会锁死 viewport 缩放
        cfg.userContentController.addUserScript(
            WKUserScript(source: DouyinWeb.bootstrapJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(
            WKUserScript(source: DouyinWeb.bootstrapJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // 聊天页点分享视频 → 抽 aweme_id 发给 App（只在 /chat 页生效）
        cfg.userContentController.addUserScript(
            WKUserScript(source: ddVideoTapHookJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 网页 → App 消息通道
        cfg.userContentController.add(DDAppMessageHandler(model), name: "ddMsg")
        DYLiveModel.log("DDMSG ddmsg-handler registered")
        // 电脑版直播间的播放器要 MediaSource，iPhone 的 WebView 只有 ManagedMediaSource（iOS 17.1+），
        // 没有它就一直「直播加载中」。这里把它补成 MediaSource；ManagedMediaSource 要求关掉隔空播放才能挂到 <video> 上
        cfg.userContentController.addUserScript(WKUserScript(source: """
        (() => {
          if (window.MediaSource || !window.ManagedMediaSource) return;
          window.MediaSource = window.ManagedMediaSource;
          window.SourceBuffer = window.SourceBuffer || window.ManagedSourceBuffer;
          const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
          if (d && d.set) Object.defineProperty(HTMLMediaElement.prototype, 'src', { configurable: true, get: d.get,
            set(v) { try { this.disableRemotePlayback = true } catch (e) {} d.set.call(this, v) } });
          const so = HTMLMediaElement.prototype.hasOwnProperty('srcObject') && Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'srcObject');
          if (so && so.set) Object.defineProperty(HTMLMediaElement.prototype, 'srcObject', { configurable: true, get: so.get,
            set(v) { try { this.disableRemotePlayback = true } catch (e) {} so.set.call(this, v) } });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let wv = DouyinFitWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = DouyinWeb.userAgent
        wv.navigationDelegate = model
        wv.uiDelegate = model
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.userZoom = zoom
        #if DEBUG
        wv.isInspectable = true
        #endif
        model.attach(wv)
        wv.load(URLRequest(url: start))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        (wv as? DouyinFitWebView)?.userZoom = zoom
    }
}

/// 把当前宽度和缩放档同步给页面脚本（开合 / 旋转 / 换档 / 每次页面提交都同步一次）
final class DouyinFitWebView: WKWebView {
    var userZoom: Double = 1 { didSet { if oldValue != userZoom { syncViewport() } } }
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 { lastWidth = bounds.width; syncViewport() }
    }

    func syncViewport() {
        guard bounds.width > 0 else { return }
        evaluateJavaScript("window.__wuweiViewW = \(Int(bounds.width)); window.__wuweiZoom = \(userZoom); window.__wuweiFixViewport && window.__wuweiFixViewport();")
    }
}
