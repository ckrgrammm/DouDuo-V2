#!/usr/bin/env python3
"""编译直播间键盘布局计算，并确认分页视口忽略键盘安全区。

Run: python3 scripts/test_live_keyboard_layout.py -v
不启动模拟器，也不连接直播。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
START = "// MARK: - live-keyboard-layout\n"
END = "// MARK: - live-keyboard-layout-end\n"

HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

check(DYLiveKeyboardLayout.overlap(viewportMinY: 0, viewportMaxY: 800, keyboardMinY: 500, keyboardMaxY: 800) == 300, "docked keyboard overlap")
check(DYLiveKeyboardLayout.overlap(viewportMinY: 0, viewportMaxY: 800, keyboardMinY: 800, keyboardMaxY: 1100) == 0, "hidden keyboard")
check(DYLiveKeyboardLayout.overlap(viewportMinY: 0, viewportMaxY: 800, keyboardMinY: 400, keyboardMaxY: 700) == 0, "floating keyboard does not move the page")
check(DYLiveKeyboardLayout.overlap(viewportMinY: 100, viewportMaxY: 900, keyboardMinY: 600, keyboardMaxY: 980) == 300, "offset window")
check(DYLiveKeyboardLayout.bottomPadding(safeBottom: 34, keyboardOverlap: 0) == 46, "resting home-indicator padding")
check(DYLiveKeyboardLayout.bottomPadding(safeBottom: 0, keyboardOverlap: 0) == 24, "resting minimum padding")
check(DYLiveKeyboardLayout.bottomPadding(safeBottom: 34, keyboardOverlap: 336) == 348, "keyboard padding replaces the safe area")

if failures.isEmpty {
    print("DYLiveKeyboardLayout passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


def layout_source() -> str:
    start = SOURCE.index(START)
    end = SOURCE.index(END, start)
    body = SOURCE[start:end]
    enum_end = body.index("private struct DYLivePagingKeyboardLock")
    return body[:enum_end]


class LiveKeyboardLayoutTests(unittest.TestCase):
    def test_overlap_and_composer_padding(self):
        swift = "import Foundation\n" + layout_source() + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-live-keyboard-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYLiveKeyboardLayout passed", completed.stdout)

    def test_paging_ignores_keyboard_and_keeps_composer(self):
        pages = SOURCE.split("private func pages(", 1)[1].split("private func syncViewport", 1)[0]
        room = SOURCE.split("private struct DYLiveRoomPage", 1)[1].split("// MARK: - live-close-placement", 1)[0]
        self.assertIn(".ignoresSafeArea(.keyboard)", pages)
        self.assertIn(".scrollDismissesKeyboard(.interactively)", pages)
        self.assertIn("keyboardLocksPaging", pages)
        self.assertIn("DYLivePagingKeyboardLock(locked:", pages)
        self.assertIn("DYLiveKeyboardLayout.bottomPadding", room)
        self.assertIn('accessibilityIdentifier("live.chat.input")', SOURCE)
        self.assertIn('accessibilityIdentifier("live.chat.send")', SOURCE)
        self.assertIn('accessibilityIdentifier("live.room.more")', room)
        self.assertNotIn("vlc.", room)


if __name__ == "__main__":
    unittest.main()
