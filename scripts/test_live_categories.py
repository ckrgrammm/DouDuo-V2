"""Compile the actual Swift category registry; do not invent network fixtures."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()


class LiveCategoryTests(unittest.TestCase):
    def test_real_categories_and_partition_mapping(self):
        start = SOURCE.index("private enum DYLiveCategoryKind")
        end = SOURCE.index("/// 预览和直播间共用", start)
        swift = "import Foundation\nstruct DYLiveZone { let id: String; let type: String; let name: String }\n"
        swift += SOURCE[start:end]
        swift += '''
let expected = ["精选", "游戏", "聊天", "音乐", "二次元", "舞蹈", "文化", "生活", "运动"]
precondition(ddLiveCategories.map(\\.name) == expected)
precondition(Set(ddLiveCategories.map(\\.id)).count == expected.count)
let ids = ["聊天": "101", "音乐": "102", "二次元": "104", "舞蹈": "105", "文化": "106", "生活": "107", "运动": "108"]
for category in ddLiveCategories {
    if let id = ids[category.name] {
        guard case .partition(let zone) = category.kind else { fatalError("Missing real source") }
        precondition(zone.id == id && zone.type == "4" && zone.name == category.name)
    }
}
print("Actual category registry passed")
'''
        with tempfile.TemporaryDirectory(prefix=".test-live-categories-", dir=ROOT) as tmp:
            p = Path(tmp) / "main.swift"
            p.write_text(swift)
            subprocess.run(["swift", str(p)], check=True, capture_output=True, text=True)

    def test_removed_standalone_game_entry(self):
        self.assertNotIn('Label("游戏专区"', SOURCE)
        self.assertNotIn('.accessibilityIdentifier("live.categories")', SOURCE)
        self.assertIn(".accessibilityIdentifier(\"live.discover\")", SOURCE)
        self.assertNotIn(".init(id: \"followed\", name: \"关注\"", SOURCE)
        self.assertNotIn("case .followed:", SOURCE)

    def test_no_placeholder_or_recommendation_fallback(self):
        self.assertNotIn("case .pending:", SOURCE)
        self.assertIn("case .partition(let zone):", SOURCE)
        self.assertIn("model.select(zone, bridge)", SOURCE)
        self.assertIn(".accessibilityValue(selectedCategory == c.id", SOURCE)


if __name__ == "__main__":
    unittest.main()
