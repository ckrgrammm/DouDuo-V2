#!/usr/bin/env python3
"""量 SwiftUI 里交互区背景的实际边界。不连接直播，也不读取房间信息。

Run: python3 scripts/test_live_pane_bounds.py -v
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
import SwiftUI
import AppKit

struct BoundsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    func report(_ name: String) -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: BoundsKey.self, value: [name: geo.frame(in: .named("root"))])
            }
        }
    }
    func placed(in pane: CGRect) -> some View {
        frame(width: pane.width, height: pane.height)
            .position(x: pane.midX, y: pane.midY)
    }
}

final class Box { var values: [String: CGRect] = [:] }

func bitmap(width: Int, height: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemYellow.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.unlockFocus()
    return image
}

struct Controls: View {
    var body: some View { VStack { Spacer(); Text("chat") }.padding(12) }
}

func artwork(_ image: NSImage?) -> some View {
    Group {
        if let image {
            Color.clear
                .overlay { Image(nsImage: image).resizable().scaledToFill() }
                .clipped()
        } else {
            Color.gray
        }
    }
    .allowsHitTesting(false)
}

func stage(video: CGRect, interaction: CGRect, image: NSImage?) -> some View {
    ZStack {
        Color.black
            .frame(width: video.width, height: video.height)
            .report("video")
            .position(x: video.midX, y: video.midY)
        Controls()
            .background { artwork(image).report("ambient") }
            .frame(width: interaction.width, height: interaction.height)
            .report("interaction")
            .position(x: interaction.midX, y: interaction.midY)
    }
    .frame(width: 400, height: 400)
    .coordinateSpace(name: "root")
}

func measure(video: CGRect, interaction: CGRect, image: NSImage?) -> [String: CGRect] {
    let box = Box()
    let root = stage(video: video, interaction: interaction, image: image)
        .onPreferenceChange(BoundsKey.self) { box.values = $0 }
    let hosting = NSHostingView(rootView: root)
    hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    return box.values
}

func inside(_ inner: CGRect, _ outer: CGRect) -> Bool {
    inner.minX >= outer.minX - 0.5 && inner.minY >= outer.minY - 0.5
        && inner.maxX <= outer.maxX + 0.5 && inner.maxY <= outer.maxY + 0.5
}

let bookVideo = CGRect(x: 0, y: 0, width: 180, height: 400)
let bookInteraction = CGRect(x: 220, y: 0, width: 180, height: 400)
let tableVideo = CGRect(x: 0, y: 0, width: 400, height: 180)
let tableInteraction = CGRect(x: 0, y: 220, width: 400, height: 180)
let wide = bitmap(width: 640, height: 80)
let tall = bitmap(width: 80, height: 640)
var failures: [String] = []

func check(_ name: String, video: CGRect, interaction: CGRect, image: NSImage?) {
    let values = measure(video: video, interaction: interaction, image: image)
    guard let pane = values["interaction"], let shownVideo = values["video"], let ambient = values["ambient"] else {
        failures.append("\(name) did not report bounds")
        return
    }
    if abs(pane.minX - interaction.minX) > 0.5 || abs(pane.minY - interaction.minY) > 0.5
        || abs(pane.width - interaction.width) > 0.5 || abs(pane.height - interaction.height) > 0.5 {
        failures.append("\(name) interaction moved to \(pane)")
    }
    if abs(shownVideo.minX - video.minX) > 0.5 || abs(shownVideo.width - video.width) > 0.5
        || abs(shownVideo.height - video.height) > 0.5 {
        failures.append("\(name) video moved to \(shownVideo)")
    }
    if !inside(ambient, interaction) {
        failures.append("\(name) ambient left the interaction pane: \(ambient)")
    }
    if pane.insetBy(dx: 0.5, dy: 0.5).intersects(video) {
        failures.append("\(name) interaction overlaps the video pane")
    }
}

check("layout B missing", video: bookVideo, interaction: bookInteraction, image: nil)
check("layout B wide", video: bookVideo, interaction: bookInteraction, image: wide)
check("layout B tall", video: bookVideo, interaction: bookInteraction, image: tall)
check("layout A missing", video: tableVideo, interaction: tableInteraction, image: nil)
check("layout A wide", video: tableVideo, interaction: tableInteraction, image: wide)
check("layout A tall", video: tableVideo, interaction: tableInteraction, image: tall)

let plain = measure(video: bookVideo, interaction: bookInteraction, image: nil)
let filled = measure(video: bookVideo, interaction: bookInteraction, image: wide)
if plain["interaction"] != filled["interaction"] || plain["video"] != filled["video"] {
    failures.append("artwork availability changed the pane frames")
}

if failures.isEmpty {
    print("DYLivePaneBounds passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class LivePaneBoundsTests(unittest.TestCase):
    def test_ambient_stays_inside_the_allocated_pane(self):
        with tempfile.TemporaryDirectory(prefix="doudou-pane-bounds-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(PROBE)
            completed = subprocess.run(
                ["swift", "-module-cache-path", str(Path(tmp) / "cache"), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYLivePaneBounds passed", completed.stdout)

    def test_room_page_keeps_ambient_out_of_the_control_stack(self):
        room = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
        page = room.split("private struct DYLiveRoomPage", 1)[1].split("// MARK: - live-close-placement", 1)[0]
        background = page.split(".background {", 1)[1].split(".placed(in: interaction)", 1)[0]
        self.assertIn("DouyinLiveAmbientBackground(", background)
        self.assertNotIn("VLCPlayerSurface(", page)
        self.assertNotIn("vlc.", page)
        field = (ROOT / "DouDuo/DouyinLiveAmbientBackground.swift").read_text()
        self.assertNotIn(".scaledToFill()", field)
        self.assertIn(".clipped()", field)
        self.assertIn(".allowsHitTesting(false)", field)


if __name__ == "__main__":
    unittest.main()
