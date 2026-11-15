#!/usr/bin/env python3
"""关闭按钮只在完全展开的内屏改到右下。不启动模拟器，也不连接直播。

Run: python3 scripts/test_live_close_placement.py -v
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
START = "// MARK: - live-close-placement\n"
END = "// MARK: - live-close-placement-end\n"


def placement_source() -> str:
    start = SOURCE.index(START)
    end = SOURCE.index(END, start)
    return SOURCE[start:end]


HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

check(DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: true, foldActive: false), "fully expanded inner screen uses the bottom-trailing close button")
check(!DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: false, foldActive: false), "compact outer screen keeps the top-leading close button")
check(!DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: true, foldActive: true), "partially folded layout keeps the top-leading close button")
check(!DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: false, foldActive: true), "folded compact width keeps the top-leading close button")

if failures.isEmpty {
    print("DYLiveChromePlacement passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class LiveClosePlacementTests(unittest.TestCase):
    def test_only_expanded_inner_screen_moves_the_close_button(self):
        swift = "import Foundation\n" + placement_source() + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-live-close-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYLiveChromePlacement passed", completed.stdout)

    def test_room_page_uses_the_placement_and_keeps_the_other_controls(self):
        page = SOURCE.split("private struct DYLiveRoomPage", 1)[1].split("private struct DYLiveCategories", 1)[0]
        self.assertIn("DYLiveChromePlacement.closeOnBottomTrailing", page)
        self.assertIn("DYDuoMetrics.foldIsActive(geo)", page)
        self.assertIn("geo.safeAreaInsets.bottom", page)
        self.assertIn("DYRailReservedNudge()", page)
        self.assertIn('id: "live.room.close", minHeight: 44', page)
        self.assertIn('id: "live.room.restore"', page)
        self.assertIn('accessibilityIdentifier("live.room.more")', page)
        self.assertIn("input", page)
        self.assertEqual(page.count('id: "live.room.close"'), 2)
        self.assertNotIn("vlc.", page)


if __name__ == "__main__":
    unittest.main()
