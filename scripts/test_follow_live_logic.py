#!/usr/bin/env python3
"""编译关注直播的纯逻辑，覆盖去重、15 秒缓存、账号代际和取消。

Run: python3 scripts/test_follow_live_logic.py -v
不联网，也不启动模拟器。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo/FollowLiveLogic.swift"


class FollowLiveLogicTests(unittest.TestCase):
    def test_logic_suite(self):
        with tempfile.TemporaryDirectory(prefix="doudou-follow-logic-") as tmp:
            binary = Path(tmp) / "follow-logic"
            completed = subprocess.run(
                ["swiftc", "-parse-as-library", "-D", "FOLLOW_LIVE_LOGIC_MAIN", str(SOURCE), "-o", str(binary)],
                check=False,
                capture_output=True,
                text=True,
            )
            if completed.returncode != 0:
                self.fail(completed.stdout + completed.stderr)
            ran = subprocess.run([str(binary)], check=False, capture_output=True, text=True)
        if ran.returncode != 0:
            self.fail(ran.stdout + ran.stderr)
        self.assertIn("DYFollowLiveLogicTests passed", ran.stdout)

    def test_cache_holds_metadata_only(self):
        meta = SOURCE.read_text().split("struct DYFollowMetadata", 1)[1].split("struct DYFollowMetadataCache", 1)[0]
        self.assertNotIn("hls", meta)
        self.assertNotIn("flv", meta)
        self.assertNotIn("cookie", meta.lower())


if __name__ == "__main__":
    unittest.main()
