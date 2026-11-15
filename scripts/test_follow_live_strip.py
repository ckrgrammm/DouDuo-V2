#!/usr/bin/env python3
"""我的关注选择器的竖向列表尺寸；关注开播只走直播页「我的关注」一处入口：直播页不挂头像条，关注页不挂直播头像。

Run: python3 scripts/test_follow_live_strip.py -v
不联网、不开模拟器。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIVE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
EXTRAS = (ROOT / "DouDuo/DouyinExtras.swift").read_text()
START = "// MARK: - follow-live-sheet-layout\n"
END = "// MARK: - follow-live-sheet-layout-end\n"

HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

check(DYFollowLiveSheetLayout.minimumTap == 44, "minimum tap target")
check(DYFollowLiveSheetLayout.ringWidth == 2, "thin live ring")
check(DYFollowLiveSheetLayout.avatarSide(regularWidth: false) == 56, "compact avatar")
check(DYFollowLiveSheetLayout.avatarSide(regularWidth: true) == 64, "expanded avatar")
check(DYFollowLiveSheetLayout.rowSpacing(regularWidth: true) > DYFollowLiveSheetLayout.rowSpacing(regularWidth: false), "expanded rows have more space")
check(DYFollowLiveSheetLayout.contentMaxWidth(regularWidth: true) == 520, "expanded list has a maximum width")
check(DYFollowLiveSheetLayout.contentMaxWidth(regularWidth: false) == .infinity, "compact list uses the available width")

let one = DYFollowLiveSheetLayout.sheetHeight(rowCount: 1, regularWidth: false, showsMessage: false)
let three = DYFollowLiveSheetLayout.sheetHeight(rowCount: 3, regularWidth: false, showsMessage: false)
let many = DYFollowLiveSheetLayout.sheetHeight(rowCount: 40, regularWidth: false, showsMessage: false)
let expandedMany = DYFollowLiveSheetLayout.sheetHeight(rowCount: 40, regularWidth: true, showsMessage: false)
let cap = DYFollowLiveSheetLayout.maximumSheetHeight(regularWidth: false)
check(one < three, "a few rows stay shorter than three rows")
check(three < cap, "three rows do not fill the compact cap")
check(many == cap, "many rows stop at the compact cap")
check(expandedMany == DYFollowLiveSheetLayout.maximumSheetHeight(regularWidth: true), "many expanded rows stop at the expanded cap")
check(one < DYFollowLiveSheetLayout.maximumSheetHeight(regularWidth: false), "one row does not use the full cap")
check(DYFollowLiveSheetLayout.sheetHeight(rowCount: 2, regularWidth: false, showsMessage: true) > DYFollowLiveSheetLayout.sheetHeight(rowCount: 2, regularWidth: false, showsMessage: false), "a selection message adds height")

if failures.isEmpty {
    print("DYFollowLiveSheetLayout passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class FollowLivePickerTests(unittest.TestCase):
    def test_sheet_layout(self):
        start = LIVE.index(START)
        end = LIVE.index(END, start)
        swift = "import Foundation\n" + LIVE[start:end] + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-follow-sheet-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYFollowLiveSheetLayout passed", completed.stdout)

    def test_live_discovery_has_one_followed_entry(self):
        feed = LIVE.split("struct DYLiveFeed", 1)[1].split("private struct DYLiveRoomPage", 1)[0]
        sheet = LIVE.split("private struct DYFollowLiveSheet", 1)[1].split("#if DEBUG", 1)[0]
        self.assertNotIn("DYFollowLiveStrip", LIVE)
        self.assertNotIn("DYFollowLiveStrip", EXTRAS)
        # 2026-11-12 老板定：直播页「我的关注」按钮换成「N 位正在直播」胶囊 + 可展开头像条（PR #11 的关注头像条移到直播页）
        self.assertIn('位正在直播', feed)
        self.assertIn("followStripExpanded", feed)
        self.assertNotIn('Label("我的关注"', feed)
        self.assertNotIn('Label("关注直播"', feed)
        self.assertIn('.navigationTitle("我的关注")', sheet)
        self.assertNotIn('.navigationTitle("关注直播")', sheet)
        self.assertNotIn("ScrollView(.horizontal)", sheet)
        self.assertIn("ScrollView {", sheet)
        self.assertIn('Text("直播中")', sheet)
        self.assertIn('Text("\\(room.viewers) 在看")', sheet)
        self.assertIn("CachedAsyncImage", sheet)
        self.assertIn("chevron.right", sheet)
        self.assertIn("DYFollowLiveSheetLayout.ringWidth", sheet)
        self.assertIn("DYFollowLiveSheetLayout.minimumTap", sheet)
        self.assertIn('accessibilityIdentifier("live.follow.room.\\(room.id)")', sheet)
        self.assertIn("model.pick(room, bridge: bridge, open: onPick)", sheet)
        self.assertIn("placeholder:", sheet)
        self.assertIn(".presentationDetents([.height(sheetDetent)])", sheet)
        self.assertIn("struct DYFollowFeed", EXTRAS)

    def test_follow_feed_has_no_live_row(self):
        """老板定：关注页只放关注作品，不再挂一排直播头像（PR #8 曾加回，1.3.11(88) 再次去掉；直播页已有「我的关注」，89 起直播页也不挂头像条）。"""
        follow = EXTRAS.split("struct DYFollowFeed", 1)[1]
        follow = follow.split("\nstruct ", 1)[0]
        for banned in ("liveRow", "loadLiveNow", "followLiveResult", "DYFollowLiveStrip", 'Text("直播中")', "onLive"):
            self.assertNotIn(banned, follow, f"关注页不应出现 {banned}")


if __name__ == "__main__":
    unittest.main()
