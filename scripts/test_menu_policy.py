#!/usr/bin/env python3
"""Read-only menu checks + execute the real Swift feed policy in isolation.

No network, UIKit, simulator, account writes or send callbacks are executed.
SwiftUI wrappers and DYAweme below are test adapters, not API responses.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FEED = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
EXTRAS = (ROOT / "DouDuo/DouyinExtras.swift").read_text()
# 顶栏已抽到 Navbar.swift
NAVBAR = (ROOT / "DouDuo/Navbar.swift").read_text()


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def menu_content(source, title):
    for match in re.finditer(r"\bMenu \{", source):
        candidate = block(source[match.start():], "Menu")
        tail = source[match.start() + len(candidate):]
        if re.match(r'\s*label:\s*\{\s*Label\("' + re.escape(title) + r'",', tail):
            return candidate
    raise AssertionError("Menu not found: " + title)


class MenuPolicyTests(unittest.TestCase):
    def test_legacy_direction_state_removed(self):
        for token in ("douyin_portrait_ratio_v1", "douyin_portrait_only_v2",
                      "portraitRatio", "mixLabel", "竖屏占比", "douyin.mix"):
            self.assertNotIn(token, FEED)

    def test_top_bar_icons_and_hit_targets(self):
        top = block(NAVBAR, "private func topBarRow")
        self.assertIn("ForEach(DYTab.allCases", top)
        tabs = block(FEED, "enum DYTab:")
        for title in ("关注", "推荐", "直播"):
            self.assertIn('"' + title + '"', tabs)
        self.assertNotIn('Text("信息")', top)
        self.assertNotIn("myUser?.name", top)
        self.assertNotIn("showName", top)
        self.assertIn('Image(systemName: "bubble.left.and.bubble.right")', top)
        self.assertIn("model.noticeUnread > 0", top)
        self.assertIn("theme.status.danger", top)
        self.assertEqual(top.count(".frame(minWidth: 44, minHeight: 44)"), 2)

    def test_current_item_menu(self):
        menu = block(FEED, "private func moreMenu")
        quick = block(menu, "ControlGroup")
        self.assertIn("DYForwardMenu(item: item, bridge: bridge, foreground: fg)", quick)
        self.assertIn('"下载"', quick)
        self.assertNotIn("ShareLink", menu)
        self.assertNotIn("danmaku", quick.lower())
        self.assertLess(menu.index('"不感兴趣"'), menu.index("DYDanmakuOptions"))
        self.assertLess(menu.index("DYDanmakuOptions"), menu.index("moreExtras"))
        self.assertIn("onSend: bridge == nil ? nil", menu)
        self.assertIn("showDanmakuInput = true", menu)
        self.assertIn("danmakuFocused = true", menu)

    def test_danmaku_single_entry_and_defaults(self):
        options = block(EXTRAS, "struct DYDanmakuOptions:")
        for token in ('Label("弹幕', 'Button("发弹幕",', 'Toggle("显示弹幕",',
                      'Picker("弹幕密度",', 'Toggle("10秒内重复去重",',
                      'private var deduplicate = true', 'Density.standard.rawValue'):
            self.assertIn(token, options)
        self.assertIn("if let onSend", options)
        self.assertNotIn("弹幕设置 ·", options)

    def test_settings_paths_and_duration_preferences(self):
        menu = block(FEED, "private func moreExtrasMenu")
        settings = menu_content(menu, "设置")
        playback = menu_content(settings, "播放设置")
        for binding in ("$autoNext", "$muted", "$feed.autoFit"):
            self.assertIn(binding, playback)
            self.assertEqual(menu.count(binding), 1)
        self.assertIn('Label("播放设置",', settings)
        for title in ("内容偏好", "高级筛选", "缓存管理", "账号与登录", "关于", "开源仓库"):
            self.assertIn('Label("' + title + '"', settings)
        for token in ("$feed.shortRatioPortrait", "$feed.shortRatioLandscape",
                      "$feed.landscapeWhenWide", "$cacheCount", "DYVideoCache.shared.clear()",
                      "DouyinWeb.home", "DDUpdateChecker.repoURL"):
            self.assertIn(token, settings)
        content = menu_content(settings, "内容偏好")
        advanced = menu_content(content, "高级筛选")
        self.assertIn("$feed.landscapeWhenWide", content)
        for token in ("$feed.shortRatioPortrait", "$feed.shortRatioLandscape"):
            self.assertIn(token, advanced)
            self.assertNotIn(token, playback)
        cache = menu_content(settings, "缓存管理")
        self.assertIn("$cacheCount", cache)
        self.assertIn("DYVideoCache.shared.clear()", cache)
        self.assertIn("DouyinWeb.home", menu_content(settings, "账号与登录"))
        self.assertIn("DDUpdateChecker.repoURL", menu_content(settings, "关于"))
        self.assertIn('"刷新推荐"', menu[:menu.index('            Menu {')])
        self.assertNotIn("@State", menu)
        load = block(FEED, "func loadMore(_ bridge:")
        self.assertIn("if added == 0, let r = targetRatio, r > 0, r < 1", load)
        self.assertIn("fill(want, relaxed: true)", load)

    def test_execute_extracted_swift_model(self):
        # Compile production properties + policy/fill/pick/remix/trim, excluding all network code.
        model = FEED[FEED.index("final class DYFeedModel:"):FEED.index("    func loadMore(_ bridge:")]
        model += "}\n"
        clamp = block(FEED, "private extension Double")
        adapters = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
}
let suiteName = "DouDuo.MenuPolicyRegression." + UUID().uuidString
let preferences = UserDefaults(suiteName: suiteName)!
@propertyWrapper struct AppStorage<Value> {
    let key: String
    let fallback: Value
    init(wrappedValue: Value, _ key: String) { self.key = key; fallback = wrappedValue }
    var wrappedValue: Value {
        get { preferences.object(forKey: key) as? Value ?? fallback }
        nonmutating set { preferences.set(newValue, forKey: key) }
    }
}
// Explicit in-memory policy fixtures, not captured or synthesized platform responses.
struct DYAweme {
    let id: String
    var images: [String] = []
    var isTallFrame: Bool = false
    var duration: Double = 60
}
'''
        checks = r'''
defer { preferences.removePersistentDomain(forName: suiteName) }
var scenarios = 0
let legacy: [Int?] = [nil, -1, 0, 30, 50, 70, 100, 999]
for old in legacy {
    for only in [false, true] {
        for wide in [false, true] {
            for override in [false, true] {
                preferences.removePersistentDomain(forName: suiteName)
                if let old { preferences.set(old, forKey: "douyin_portrait_ratio_v1") }
                preferences.set(only, forKey: "douyin_portrait_only_v2")
                preferences.set(override, forKey: "douyin_wide_landscape_v1")
                let feed = DYFeedModel()
                feed.screenWide = wide
                precondition(feed.targetRatio == (wide && override ? 0 : 0.7))
                precondition(preferences.object(forKey: "douyin_portrait_ratio_v1") as? Int == old)
                scenarios += 1
            }
        }
    }
}
preferences.removePersistentDomain(forName: suiteName)
let feed = DYFeedModel()
feed.shortRatioPortrait = -1
feed.pool = (0..<2000).map { DYAweme(id: "mixed-\($0)", isTallFrame: $0 % 2 == 0) }
precondition(feed.fill(1000) == 1000)
let portraits = feed.items.filter(DYFeedModel.isPortrait).count
precondition(abs(Double(portraits) / 1000 - 0.7) <= 0.0011)
precondition(Set(feed.items.map(\.id)).count == 1000 && feed.pool.count == 1000)
print("PASS balanced pool: \(portraits)/1000 portrait, candidates retained")
let scarce = DYFeedModel()
scarce.pool = (0..<10).map { DYAweme(id: "portrait-\($0)", isTallFrame: true) }
precondition(scarce.fill(6) == 0)
precondition(scarce.fill(6, relaxed: true) == 6)
precondition(scarce.pool.count == 4)
let wide = DYFeedModel()
wide.screenWide = true
wide.landscapeWhenWide = true
wide.pool = (0..<20).map { DYAweme(id: "wide-\($0)", isTallFrame: $0 % 2 == 0) }
precondition(wide.fill(20, relaxed: true) == 10)
precondition(wide.items.allSatisfy { !DYFeedModel.isPortrait($0) })
precondition(wide.pool.allSatisfy(DYFeedModel.isPortrait))
wide.landscapeWhenWide = false
precondition(wide.targetRatio == 0.7)
let duration = DYFeedModel()
duration.screenWide = true
duration.landscapeWhenWide = true
duration.shortRatioLandscape = 100
duration.shortRatioPortrait = 0
duration.pool = [DYAweme(id: "long", duration: 300), DYAweme(id: "short", duration: 60)]
precondition(duration.fill(1) == 1 && duration.items[0].id == "short")
precondition(duration.shortRatioPortrait == 0 && duration.shortRatioLandscape == 100)
let remix = DYFeedModel()
remix.items = [DYAweme(id: "current", isTallFrame: true), DYAweme(id: "upcoming-tall", isTallFrame: true), DYAweme(id: "upcoming-wide")]
remix.screenWide = true
remix.landscapeWhenWide = true
remix.remix(after: 0)
precondition(remix.items.map(\.id) == ["current", "upcoming-wide"])
precondition(remix.pool.map(\.id) == ["upcoming-tall"])
precondition(DYFeedModel.isPortrait(DYAweme(id: "gallery", images: ["fixture"])))
print("PASS \(scenarios) legacy/orientation combinations; scarcity fallback; strict wide override; independent durations; remix; gallery classification")
'''
        scratch = Path(os.environ.get("TMPDIR", Path.home() / ".hermes/profiles/shayu/cache/scratch"))
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="menu-policy-", dir=scratch) as folder:
            source = Path(folder) / "Policy.swift"
            source.write_text(adapters + model + clamp + checks)
            result = subprocess.run(["swift", str(source)], text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
