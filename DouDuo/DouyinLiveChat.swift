// 直播弹幕：后台开一个看不见的直播间网页（电脑版），让抖音页面自己连 WebSocket、解 protobuf，
// 我们只读它渲染出来的聊天列表 DOM。签名 / 协议跟着官方走，不逆向。
import SwiftUI
import WebKit

struct DYLiveMsg: Identifiable, Equatable {
    let id: Int
    let name: String
    let text: String
}

@MainActor
final class DYLiveChat: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var messages: [DYLiveMsg] = []
    @Published private(set) var composerReady = false
    let web: WKWebView
    private var timer: Timer?
    private var room: String?
    private var openedAt = ProcessInfo.processInfo.systemUptime
    private var composerLogged = false
    private var seq = 0
    private var ticks = 0
    private var generation = UUID()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        // 直播间页面会自己拉流播放：一律掐掉，只要聊天区
        cfg.userContentController.addUserScript(WKUserScript(source: Self.noMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
        Self.installLeanRules(on: web)
    }

    /// 评论区只读聊天文字：直播间页面的图片、字体、视频、音频一律不下载。
    /// 规则编译一次后缓存；编译完成前的第一次加载不受影响，之后的加载都带规则。
    private static let leanRules = """
    [{"trigger":{"url-filter":".*","resource-type":["image","font","media"]},"action":{"type":"block"}}]
    """
    private static func installLeanRules(on web: WKWebView) {
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "dd-live-chat-lean-v1", encodedContentRuleList: leanRules) { list, _ in
            guard let list else { return }
            DispatchQueue.main.async { web.configuration.userContentController.add(list) }
        }
    }

    /// 当前已加载（或正在加载）的直播间 webRid。预热过同一间时，进房不用再等一遍。
    var loadedRoom: String? { room }

    func open(_ webRid: String) {
        guard !webRid.isEmpty, webRid != room else { return }
        generation = UUID()
        room = webRid
        openedAt = ProcessInfo.processInfo.systemUptime
        composerLogged = false
        DYLiveModel.log("DDCHAT_OPEN room=\(webRid)")
        composerReady = false
        messages = []
        ticks = 0
        web.load(URLRequest(url: URL(string: "https://live.douyin.com/\(webRid)")!))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// 在官网编辑器提交，并等待 /webcast/room/chat/ 的真实业务确认；不自动重试。
    func send(_ text: String) async -> String? {
        guard let targetRoom = room else { return "评论区连接中，请稍后再试" }
        let token = generation
        do {
            let raw = try await web.callAsyncJavaScript(Self.sendJS, arguments: ["text": text], contentWorld: .page)
            guard room == targetRoom, generation == token else { return "直播间已切换，原发言结果未确认，请勿连续重发" }
            guard let string = raw as? String, let data = string.data(using: .utf8),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = result["state"] as? String else { return "未收到发言确认，请勿连续重发" }
            DYLiveModel.log("DDSEND live state=\(state) code=\(result["code"] ?? "-") messageID=\(result["messageID"] ?? "-")")
            if state == "sent" { return nil }
            return result["message"] as? String ?? "直播发言尚未确认，输入内容已保留，请勿连续重发"
        } catch {
            DYLiveModel.log("DDSEND live javascript-error")
            return "直播网页执行失败，发言结果未确认，请勿连续重发"
        }
    }

    static let composerReadyJS = #"""
    (() => {
      const box = document.querySelector('[data-e2e="live-chatting"] [contenteditable="true"], textarea, [contenteditable="true"]');
      return !!box && !box.disabled && !box.readOnly && box.getAttribute('aria-disabled') !== 'true';
    })()
    """#

    static let sendJS = #"""
    return await (async () => {
      const box = document.querySelector('[data-e2e="live-chatting"] [contenteditable="true"], textarea, [contenteditable="true"]');
      const fail = (state, message) => JSON.stringify({ state, message });
      if (!box) return fail('loading', '评论区连接中，请等待输入框加载完成');
      if (box.disabled || box.readOnly || box.getAttribute('aria-disabled') === 'true') return fail('disabled', '直播间暂不能发言，请查看官网限制提示');
      if (window.__ddLiveSending) return fail('busy', '上一条直播发言仍在确认中，请勿重复提交');
      window.__ddLiveSending = true;
      let resolveAck, finished = false;
      const ack = new Promise(resolve => { resolveAck = resolve; });
      const finish = result => { if (!finished) { finished = true; resolveAck(result); } };
      const isChat = url => { try { return new URL(url, location.href).pathname.replace(/\/$/, '') === '/webcast/room/chat'; } catch { return false; } };
      const capture = (url, http, body) => {
        if (!isChat(url)) return;
        let d; try { d = JSON.parse(body); } catch { return; }
        const data = d.data || {}, messageID = data.msg_id_str || data.msg_id || data.id;
        if (http === 200 && d.status_code === 0 && messageID) {
          finish({ state: 'sent', code: 0, messageID: String(messageID) });
        } else if (typeof d.status_code === 'number' && d.status_code !== 0) {
          finish({ state: 'rejected', code: d.status_code, message: data.prompts || data.message || d.status_msg || '直播平台拒绝了发言' });
        }
      };
      const oldSend = XMLHttpRequest.prototype.send, oldFetch = window.fetch;
      function observeSend(...args) {
        this.addEventListener('load', () => { try { capture(this.responseURL, this.status, this.responseText); } catch {} }, { once: true });
        return oldSend.apply(this, args);
      }
      async function observeFetch(...args) {
        const r = await oldFetch.apply(this, args);
        if (isChat(r.url)) { try { capture(r.url, r.status, await r.clone().text()); } catch {} }
        return r;
      }
      XMLHttpRequest.prototype.send = observeSend;
      window.fetch = observeFetch;
      const timer = setTimeout(() => finish({ state: 'unconfirmed', message: '未收到直播平台确认，请先查看聊天记录，勿连续重发' }), 10000);
      try {
        box.focus();
        if (box.tagName === 'TEXTAREA') {
          Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(box, text);
          box.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
          box.dispatchEvent(new Event('change', { bubbles: true }));
        } else {
          // Slate/EditorKit 必须走原生编辑事务；修改 innerText 不会同步官网编辑器模型。
          const range = document.createRange(); range.selectNodeContents(box);
          const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
          if (!document.execCommand('insertText', false, text)) return fail('compose-error', '官网编辑器未接受输入，内容已保留');
        }
        await new Promise(resolve => setTimeout(resolve, 300));
        const actual = (box.tagName === 'TEXTAREA' ? box.value : box.innerText) || '';
        if (actual.replace(/\u200b/g, '').trim() !== text.trim()) return fail('compose-error', '官网输入内容未同步，已取消提交');
        const button = [...document.querySelectorAll('[class*="send"], button')].find(b => /发送/.test(b.innerText || '') || /send-btn|sendBtn|send_btn/i.test(String(b.className)));
        if (button && box.getAttribute('data-slate-editor') !== 'true') {
          if (button.disabled || button.getAttribute('aria-disabled') === 'true') return fail('disabled', '直播间暂不能发言，请查看官网限制提示');
          button.click();
        } else {
          // 已在真实官网验证：该编辑器无发送按钮，Enter 会走官网签名与业务请求。
          for (const type of ['keydown', 'keypress', 'keyup']) box.dispatchEvent(new KeyboardEvent(type, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, charCode: 13, bubbles: true, cancelable: true, composed: true }));
        }
        return JSON.stringify(await ack);
      } finally {
        clearTimeout(timer);
        if (XMLHttpRequest.prototype.send === observeSend) XMLHttpRequest.prototype.send = oldSend;
        if (window.fetch === observeFetch) window.fetch = oldFetch;
        window.__ddLiveSending = false;
      }
    })();
    """#

    func close() {
        timer?.invalidate(); timer = nil
        generation = UUID()
        room = nil
        composerReady = false
        messages = []
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    private func poll() {
        ticks += 1
        let token = generation
        let script = "({items: \(Self.pollJS), ready: \(Self.composerReadyJS)})"
        web.evaluateJavaScript(script) { [weak self] r, _ in
            guard let self, self.generation == token, let payload = r as? [String: Any],
                  let arr = payload["items"] as? [[String]] else { return }
            let ready = payload["ready"] as? Bool ?? false
            if self.composerReady != ready { DYLiveModel.log("DDCHAT composerReady=\(ready)") }
            if ready, !self.composerLogged {
                self.composerLogged = true
                DYLiveModel.log("DDCHAT_COMPOSER_READY elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - self.openedAt))")
            }
            self.composerReady = ready
            if self.ticks % 10 == 1 {
                DYLiveModel.log("DDCHAT tick=\(self.ticks) new=\(arr.count) first=\(arr.first?.joined(separator: "：") ?? "-")")
                #if DEBUG
                if arr.isEmpty || ProcessInfo.processInfo.environment["DOUDUO_CHATPROBE"] == "1" {
                    self.web.evaluateJavaScript(Self.diagJS) { d, _ in DYLiveModel.log("DDCHAT diag \(String(describing: d ?? "nil").prefix(3200))") }
                }
                #endif
            }
            guard !arr.isEmpty else { return }
            var m = self.messages
            for p in arr where p.count == 2 {
                self.seq += 1
                m.append(DYLiveMsg(id: self.seq, name: p[0], text: p[1]))
            }
            self.messages = Array(m.suffix(40))
        }
    }

    private static let noMediaJS = """
    (() => {
      const P = HTMLMediaElement.prototype;
      P.play = function () { try { this.muted = true; this.pause(); } catch (e) {} return Promise.resolve(); };
      const kill = () => document.querySelectorAll('video,audio').forEach(v => { try { v.muted = true; v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {} });
      document.addEventListener('DOMContentLoaded', kill);
      new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    private static let diagJS = #"""
    (() => {
      const cls = {};
      document.querySelectorAll('[class]').forEach(e => String(e.className).split(/\s+/).forEach(c => { if (/chat|comment|msg|message|barrage|danmu/i.test(c)) cls[c] = (cls[c] || 0) + 1; }));
      const txt = (document.body && document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 300);
      const inputs = [...document.querySelectorAll('textarea,input,[contenteditable],[role="textbox"]')].map(e => ({tag:e.tagName,ce:e.getAttribute('contenteditable'),role:e.getAttribute('role'),cls:String(e.className).slice(0,100),disabled:!!e.disabled,editable:e.isContentEditable}));
      const buttons = [...document.querySelectorAll('[class*="send"],button')].filter(b => /发送/.test(b.innerText || '') || /send-btn|sendBtn|send_btn/i.test(String(b.className))).map(b => ({tag:b.tagName,cls:String(b.className),disabled:!!b.disabled,aria:b.getAttribute('aria-disabled')}));
      return 'url=' + location.origin + location.pathname + ' title=' + document.title + ' inputs=' + JSON.stringify(inputs).slice(0,650) + ' buttons=' + JSON.stringify(buttons).slice(0,450) + ' cls=' + JSON.stringify(cls).slice(0,100) + ' txt=' + txt.slice(0,80);
    })()
    """#

    /// 找聊天条目：优先 webcast-chatroom___item；类名混淆时退回「聊天区里的叶子行」。读过的打标记不重复
    private static let pollJS = #"""
    (() => {
      const items = [...document.querySelectorAll('[class*="chatroom___item"]')].filter(e => !e.parentElement.closest('[class*="chatroom___item"]'));
      const out = [];
      for (const it of items) {
        if (it.dataset.dd) continue;
        it.dataset.dd = '1';
        const t = (it.innerText || '').replace(/\s+/g, ' ').trim();
        if (!t || t.length > 120) continue;
        // 进场 / 点赞 / 关注这类系统消息：「xxx 来了」整句保留
        const i = t.search(/[：:]/);
        if (i > 0 && i < 24) out.push([t.slice(0, i).replace(/^.*?(\S+)$/, '$1').trim(), t.slice(i + 1).trim()]);
        else out.push(['', t]);
      }
      return out.slice(-30);
    })()
    """#
}

/// 挂进窗口，JS 定时器 / WebSocket 才不被系统节流
struct DYLiveChatHost: UIViewRepresentable {
    let chat: DYLiveChat
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.clipsToBounds = true
        v.isUserInteractionEnabled = false
        v.accessibilityElementsHidden = true
        chat.web.alpha = 0.01
        v.addSubview(chat.web)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 抖音直播同款：左下角滚动聊天列表，最新的在最下面
struct DYLiveChatOverlay: View {
    let messages: [DYLiveMsg]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(messages.suffix(7)) { m in
                (Text(m.name.isEmpty ? "" : m.name + "：").foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1.0))
                 + Text(m.text).foregroundStyle(.white))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.32)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: messages.last?.id)
        .allowsHitTesting(false)
        .accessibilityIdentifier("live.chat")
    }
}
