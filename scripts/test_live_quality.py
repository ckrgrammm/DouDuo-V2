#!/usr/bin/env python3
"""上游 v1.3.10 的直播清晰度选择必须留在这次集成里。

私人仓库的 DYLiveSourcePlan 不进入公开贡献。本测试锁住仍在使用的
FLV 优先顺序、全局清晰度偏好和菜单绑定。不连网，也不创建播放器。

Run: python3 scripts/test_live_quality.py -v
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()


class UpstreamLiveQualityTests(unittest.TestCase):
    def test_upstream_quality_selection_stays(self):
        self.assertNotIn("enum DYLiveSourcePlan", SOURCE)
        self.assertNotIn("func selectQuality", SOURCE)
        self.assertIn('UserDefaults.standard.string(forKey: "douyin_live_quality_v1")', SOURCE)
        self.assertIn('UserDefaults.standard.set(q, forKey: "douyin_live_quality_v1")', SOURCE)
        self.assertIn("func setQuality(_ q: String?)", SOURCE)
        self.assertIn('["ORIGION": "原画", "FULL_HD1": "蓝光", "HD1": "超清", "SD1": "高清", "SD2": "标清"]', SOURCE)
        self.assertIn("for isFLV in [true, false]", SOURCE)
        self.assertIn('let keys = ["HD1", def ?? "", "FULL_HD1", "SD1", "SD2"]', SOURCE)
        menu = SOURCE.split('Menu("清晰度"', 1)[1].split(".accessibilityIdentifier(\"live.room.quality\")", 1)[0]
        self.assertIn("model.setQuality", menu)
        self.assertIn("model.qualityOptions", menu)
        self.assertIn("DYLiveModel.qualityName", menu)
        playback = SOURCE.split("func suspendForBackground()", 1)[1].split("func backToFeatured", 1)[0]
        self.assertNotIn("setQuality", playback)
        self.assertNotIn("qualityOptions", playback)

    def test_short_video_background_setting_is_separate(self):
        feed = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
        self.assertIn('Label("后台播放（听书）"', feed)
        live = SOURCE.split("private struct DYLiveRoomPage", 1)[1].split("private struct DYLiveCategories", 1)[0]
        self.assertIn('Toggle("后台播放"', live)
        self.assertNotIn("听书", live)
        self.assertIn("douyin_live_background_sound_v1", SOURCE)


if __name__ == "__main__":
    unittest.main()
