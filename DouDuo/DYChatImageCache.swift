import CryptoKit
import Foundation
import UIKit
import WebKit

/// 信息（群/私聊）里的图片本地缓存。
/// 抖音的图片地址是带签名的：同一个头像/同一张聊天图，每次进页面签名都会变（?x-expires=…&x-signature=…），
/// 所以系统的 URLCache 永远不命中，每次进聊天都要重新拉一遍。
/// 这里把网页里 `<img>` 的地址改写成自定义 scheme（ddimg://），由 App 接管：
///   - 缓存键 = 去掉签名参数后的 Host+Path（同一张图永远是同一个键）
///   - 命中磁盘直接返回，不再联网；未命中才下载并落盘
///   - 下载失败就 404，网页里的 JS 会把地址还原成原始 URL 兜底
@MainActor
final class DYChatImageCache {
    static let shared = DYChatImageCache()
    static let scheme = "ddimg"
    /// 磁盘预算
    private let limit: Int = 300 * 1024 * 1024

    private let dir: URL
    private let io = DispatchQueue(label: "chat-image-cache", qos: .utility)
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("dd-chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        trim()
    }

    /// 缓存键：图片本身的 ID。
    /// 实测抖音同一张图每次进页面都会换：主机 p3-sign/p9-sign 会变、桶名 tos-cn-i-**** 会变、
    /// 签名 query 也会变，只有路径最后那段 ID（`o8RYgkDW…`，后面 `~tplv-…` 是尺寸模板）是稳定的。
    /// 所以键取 `最后一段 ~ 之前的部分`，主机和 query 一律不进键。
    nonisolated static func key(for raw: String) -> String? {
        guard let u = URL(string: raw) else { return nil }
        let last = u.lastPathComponent
        guard !last.isEmpty else { return nil }
        let id = String(last.split(separator: "~").first ?? Substring(last))
        guard id.count >= 16 else { return nil }   // 太短的不当图片 id，避免误撞
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return hash
    }

    private func file(_ key: String) -> URL { dir.appendingPathComponent(key) }

    /// ddimg://img/?u=<原地址> → 原地址；不是 ddimg 的原样返回
    nonisolated static func originalURL(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix(scheme + ":") else { return raw }
        return URLComponents(string: raw)?.queryItems?.first(where: { $0.name == "u" })?.value ?? raw
    }

    func cachedData(for raw: String) -> Data? {
        guard let k = Self.key(for: raw) else { return nil }
        let f = file(k)
        guard let data = try? Data(contentsOf: f), !data.isEmpty else { return nil }
        // LRU：读到就更新修改时间，清理时先删最久没用的
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return data
    }

    func store(_ data: Data, for raw: String) {
        guard let k = Self.key(for: raw), data.count > 512 else { return }
        let f = file(k)
        io.async { [dir, limit] in
            try? data.write(to: f, options: .atomic)
            Self.trim(dir: dir, limit: limit, queue: nil)
        }
    }

    private func trim() {
        let d = dir, l = limit
        io.async { Self.trim(dir: d, limit: l, queue: nil) }
    }

    nonisolated private static func trim(dir: URL, limit: Int, queue: DispatchQueue?) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return }
        var rows: [(URL, Int, Date)] = []
        var total = 0
        for f in files {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), let size = v.fileSize else { continue }
            total += size
            rows.append((f, size, v.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return }
        rows.sort { $0.2 < $1.2 }
        var target = total
        for (f, size, _) in rows {
            guard target > limit * 8 / 10 else { break }
            try? fm.removeItem(at: f)
            target -= size
        }
    }
}

/// 网页里 ddimg:// 的响应者
final class DYChatImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private nonisolated(unsafe) static var hits = 0
    private nonisolated(unsafe) static var misses = 0
    private let queue = DispatchQueue(label: "chat-image-loader", qos: .utility)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let original = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              original.hasPrefix("http")
        else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        if let data = DYChatImageCache.shared.cachedData(for: original) {
            Self.hits += 1
            if Self.hits % 20 == 0 { DYLiveModel.log("DDCHATIMG hit=\(Self.hits) miss=\(Self.misses)") }
            respond(task, url: url, data: data, fromCache: true)
            return
        }
        Self.misses += 1
        var req = URLRequest(url: URL(string: original) ?? url)
        req.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        let key = original
        let session = URLSession.shared
        queue.async {
            let sem = DispatchSemaphore(value: 0)
            var payload: Data?
            var code = 404
            session.dataTask(with: req) { data, resp, _ in
                if let http = resp as? HTTPURLResponse { code = http.statusCode }
                payload = data
                sem.signal()
            }.resume()
            sem.wait()
            DispatchQueue.main.async {
                guard let data = payload, code == 200, !data.isEmpty else {
                    task.didFailWithError(URLError(.resourceUnavailable))
                    return
                }
                DYChatImageCache.shared.store(data, for: key)
                self.respond(task, url: url, data: data, fromCache: false)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, fromCache: Bool) {
        let mime: String
        switch data.prefix(4) {
        case let d where d.starts(with: [0xFF, 0xD8, 0xFF, 0xDB]): mime = "image/jpeg"
        case let d where d.starts(with: [0x89, 0x50, 0x4E, 0x47]): mime = "image/png"
        case let d where d.prefix(4) == Data("GIF8".utf8): mime = "image/gif"
        case let d where d.starts(with: [0x52, 0x49, 0x46, 0x46]): mime = "image/webp"
        default: mime = "image/jpeg"
        }
        let resp = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
        if !fromCache { DYLiveModel.log("DDCHATIMG download \(data.count / 1024)KB") }
    }
}

/// 把网页里的图片地址改写成 ddimg://（缓存键只看路径，签名变了也能命中）
enum DYChatImageRewrite {
    static let script = #"""
    (() => {
      if (window.__ddImgRewrite) return; window.__ddImgRewrite = 1;
      const OK = /^https:\/\/([a-z0-9-]+\.)*(douyinpic\.com|byteimg\.com|douyin\.com)\//i;
      // 读 img.src 的地方（会话列表扫描、转发联系人、打开会话时比对头像）必须拿到原始 https 地址：
      // 以前改写后它们读到的是 ddimg://img/?u=…，原生列表拿去显示 → 好友头像空白。
      // 只改「读」：浏览器实际加载用的是 src 属性（ddimg），读 .src 时还原 data-dd-orig。
      try {
        const desc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
        if (desc && desc.get && !HTMLImageElement.prototype.__ddSrcPatched) {
          Object.defineProperty(HTMLImageElement.prototype, 'src', {
            configurable: true, enumerable: desc.enumerable,
            get() { const o = this.dataset && this.dataset.ddOrig; const v = desc.get.call(this); return (o && String(v).startsWith('ddimg:')) ? o : v; },
            set(v) { desc.set.call(this, v); }
          });
          HTMLImageElement.prototype.__ddSrcPatched = true;
        }
      } catch (e) {}
      const fix = img => {
        try {
          if (img.dataset.ddFailed) return;
          const src = img.getAttribute('src') || '';
          if (!src || src.startsWith('ddimg:') || !OK.test(src)) return;
          img.dataset.ddOrig = src;
          if (!img.dataset.ddBound) {
            img.dataset.ddBound = '1';
            img.addEventListener('error', () => {
              // 我们这边取不到（过期/跨域）：标记后还原原始地址，让网页自己加载
              img.dataset.ddFailed = '1';
              const o = img.dataset.ddOrig;
              if (o && String(img.getAttribute('src') || '').startsWith('ddimg:')) img.setAttribute('src', o);
            });
          }
          img.setAttribute('src', 'ddimg://img/?u=' + encodeURIComponent(src));
        } catch (e) {}
      };
      const scan = root => {
        if (!root) return;
        if (root.tagName === 'IMG') fix(root);
        if (root.querySelectorAll) root.querySelectorAll('img').forEach(fix);
      };
      new MutationObserver(ms => {
        for (const m of ms) {
          if (m.type === 'attributes') fix(m.target);
          else if (m.addedNodes) m.addedNodes.forEach(scan);
        }
      }).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['src'] });
      scan(document.documentElement);
    })();
    """#
}
