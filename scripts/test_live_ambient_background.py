#!/usr/bin/env python3
"""编译直播环境光的纯计算，并检查视图不会在 body 里重做模糊。

Run: python3 scripts/test_live_ambient_background.py -v
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo/DouyinLiveAmbientBackground.swift"
LAYOUT = ROOT / "DouDuo/DouyinLiveAdaptiveLayout.swift"
ROOM = ROOT / "DouDuo/DouyinLiveRoom.swift"

HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let vertical = DYLiveAmbientTreatment.fade(for: .vertical)
check(vertical.start == .minY && vertical.end == .maxY, "layout A fades downward from the hinge")
let horizontal = DYLiveAmbientTreatment.fade(for: .horizontal)
check(horizontal.start == .minX && horizontal.end == .maxX, "layout B fades rightward from the hinge")
check(vertical != horizontal, "layout A and layout B use different fade directions")
check(DYLiveAmbientTreatment.axis(for: .layoutA) == .vertical, "layout A maps to the vertical ambient")
check(DYLiveAmbientTreatment.axis(for: .layoutB) == .horizontal, "layout B maps to the horizontal ambient")
check(DYLiveAmbientTreatment.axis(for: .existing) == nil, "the full-screen layout does not request an ambient pane")

let near = DYLiveAmbientTreatment.artworkOpacity(at: 0)
let far = DYLiveAmbientTreatment.artworkOpacity(at: 1)
check(near > far + 0.4, "the hinge keeps more cover color than the outer edge")
check(DYLiveAmbientTreatment.opacity(at: 1, stops: DYLiveAmbientTreatment.veilStops) >= DYLiveAmbientTreatment.opacity(at: 0, stops: DYLiveAmbientTreatment.veilStops), "the outer edge is at least as dark as the hinge")
check(DYLiveAmbientTreatment.plateOpacity >= 0.5 && DYLiveAmbientTreatment.plateOpacity <= 0.62, "the plate stays lighter than a flat 76 percent black")
check(DYLiveAmbientTreatment.opacity(at: 0, stops: DYLiveAmbientTreatment.plateStops) < DYLiveAmbientTreatment.plateOpacity, "the video edge keeps a lighter plate than the middle")
check(DYLiveAmbientTreatment.opacity(at: 1, stops: DYLiveAmbientTreatment.plateStops) > DYLiveAmbientTreatment.plateOpacity, "the comment side uses a heavier plate")
check(DYLiveAmbientTreatment.opacity(at: 0, stops: DYLiveAmbientTreatment.primaryGlowStops) > DYLiveAmbientTreatment.opacity(at: 1, stops: DYLiveAmbientTreatment.primaryGlowStops) + 0.4, "primary glow is strongest near the video")
check(DYLiveAmbientTreatment.opacity(at: 0.42, stops: DYLiveAmbientTreatment.secondaryGlowStops) > DYLiveAmbientTreatment.opacity(at: 0, stops: DYLiveAmbientTreatment.secondaryGlowStops), "secondary glow sits away from the video edge")
check(DYLiveAmbientTreatment.opacity(at: 0.42, stops: DYLiveAmbientTreatment.secondaryGlowStops) > DYLiveAmbientTreatment.opacity(at: 1, stops: DYLiveAmbientTreatment.secondaryGlowStops), "secondary glow fades before the outer edge")
check(DYLiveAmbientTreatment.opacity(at: 0, stops: DYLiveAmbientTreatment.spillStops) > DYLiveAmbientTreatment.opacity(at: 1, stops: DYLiveAmbientTreatment.spillStops) + 0.5, "edge spill fades toward the outer side")
check(DYLiveAmbientTreatment.sourceMaxPixel <= 96, "the blur source stays thumbnail sized")
check(DYLiveAmbientTreatment.transitionDuration > 0 && DYLiveAmbientTreatment.transitionDuration < 1, "artwork changes use one short fade")

let fallback = DYLiveAmbientTreatment.fallback
check(fallback.red < 0.12 && fallback.green < 0.12 && fallback.blue < 0.12, "missing artwork falls back to a dark field")
check(fallback.red > 0.02 && fallback.green > 0.02 && fallback.blue > 0.02, "the fallback is neutral dark rather than a pure hole")

let samples: [(String, DYLiveAmbientRGB?)] = [
    ("missing", nil),
    ("white", DYLiveAmbientRGB(red: 1, green: 1, blue: 1)),
    ("yellow", DYLiveAmbientRGB(red: 1, green: 1, blue: 0)),
    ("red", DYLiveAmbientRGB(red: 1, green: 0, blue: 0)),
    ("cyan", DYLiveAmbientRGB(red: 0, green: 1, blue: 1)),
    ("black", DYLiveAmbientRGB(red: 0, green: 0, blue: 0)),
    ("dark", DYLiveAmbientRGB(red: 0.04, green: 0.05, blue: 0.08)),
]
for (name, artwork) in samples {
    for location: CGFloat in [0, 0.5, 1] {
        let contrast = DYLiveAmbientTreatment.whiteTextContrast(artwork: artwork, location: location)
        check(contrast >= DYLiveAmbientTreatment.minimumTextContrast, "\(name) at \(location) keeps white text readable")
    }
}
let missing = DYLiveAmbientTreatment.backdrop(artwork: nil, location: 0.5)
check(missing.red < 0.08 && missing.green < 0.08 && missing.blue < 0.08, "a missing cover stays on the dark plate")
let glow = DYLiveAmbientRGB(red: 0.1, green: 0.35, blue: 0.85)
let hingeGlow = DYLiveAmbientTreatment.backdrop(artwork: glow, location: 0)
let outerGlow = DYLiveAmbientTreatment.backdrop(artwork: glow, location: 1)
check(hingeGlow.blue > outerGlow.blue + 0.08, "colored artwork stays visible at the video edge and fades outward")
check(hingeGlow.blue > hingeGlow.red, "the hinge glow follows the artwork instead of turning gray")
let whiteEdge = DYLiveAmbientTreatment.backdrop(artwork: DYLiveAmbientRGB(red: 1, green: 1, blue: 1), location: 0)
check(whiteEdge.red < 0.45 && whiteEdge.green < 0.45 && whiteEdge.blue < 0.45, "bright artwork is pulled down before it reaches the text")
let darkEdge = DYLiveAmbientTreatment.backdrop(artwork: DYLiveAmbientRGB(red: 0.04, green: 0.05, blue: 0.08), location: 0)
let missingEdge = DYLiveAmbientTreatment.backdrop(artwork: nil, location: 0)
check(darkEdge.blue > darkEdge.red + 0.01, "dark artwork keeps its blue instead of turning gray")
check(darkEdge.blue > missingEdge.blue, "dark artwork stays visible against the empty field")
let redEdge = DYLiveAmbientTreatment.backdrop(artwork: DYLiveAmbientRGB(red: 1, green: 0, blue: 0), location: 0)
check(redEdge.red > redEdge.green && redEdge.red > redEdge.blue, "saturated red keeps its hue")
check(redEdge.red < 0.55, "saturated red does not become neon")

var stripe = [UInt8](repeating: 0, count: 5 * 4)
stripe[8] = 255
stripe[9] = 255
stripe[10] = 255
stripe[11] = 255
let sharp = DYLiveAmbientBitmap(width: 5, height: 1, rgba: stripe)
let blurred = DYLiveAmbientBlur.boxBlur(sharp, radius: 1)
check(blurred.rgba[0] == 0 && blurred.rgba[4] == 85 && blurred.rgba[8] == 85 && blurred.rgba[12] == 85 && blurred.rgba[16] == 0, "a one-pixel spike spreads to its neighbors")
let soft = DYLiveAmbientBlur.soften(sharp)
check(soft.width == 5 && soft.height == 1, "soften keeps the bitmap size")
check(Int(soft.rgba[8]) < 255, "soften removes a hard edge")

let memo = DYLiveAmbientMemo<Int>(limit: 2)
var builds = 0
let first = memo.resolve(key: "room-a") { builds += 1; return 7 }
let second = memo.resolve(key: "room-a") { builds += 1; return 9 }
check(first == 7 && second == 7 && builds == 1 && memo.renders == 1, "the same artwork is blurred once")
check(memo.peek("room-a") == 7 && memo.renders == 1, "a cache hit does not render")
_ = memo.resolve(key: "room-b") { builds += 1; return 1 }
_ = memo.resolve(key: "room-c") { builds += 1; return 2 }
check(memo.peek("room-a") == nil, "the oldest room leaves the small cache")
_ = memo.resolve(key: "room-a") { builds += 1; return 7 }
check(memo.renders == 4 && builds == 4, "an evicted room can render again, and only then")

let roomA = DYLiveAmbientIdentity.token(isolationID: "account-a", artwork: "cover:room-a")
let roomB = DYLiveAmbientIdentity.token(isolationID: "account-a", artwork: "cover:room-b")
let accountB = DYLiveAmbientIdentity.token(isolationID: "account-b", artwork: "cover:room-a")
let noArtwork = DYLiveAmbientIdentity.token(isolationID: "account-a", artwork: "fallback")
check(roomA != roomB, "a room change gets a new artwork identity")
check(roomA != accountB, "an account change gets a new identity even for the same cover")
check(DYLiveAmbientIdentity.isFallback(noArtwork), "a room without artwork is the fallback identity")
check(!DYLiveAmbientIdentity.isFallback(roomA), "a cover URL is not treated as a missing cover")
check(DYLiveAmbientIdentity.shouldApply(requested: roomA, current: roomA, cancelled: false), "the current room accepts its own image")
check(!DYLiveAmbientIdentity.shouldApply(requested: roomA, current: roomB, cancelled: false), "a finished load does not paint the next room")
check(!DYLiveAmbientIdentity.shouldApply(requested: roomA, current: accountB, cancelled: false), "the previous account does not paint the same cover onto the new account")
check(!DYLiveAmbientIdentity.shouldApply(requested: roomA, current: roomA, cancelled: true), "a cancelled load does not paint")

func paint(_ width: Int, _ height: Int, _ color: DYLiveAmbientRGB, _ spots: [(Int, Int, Int, Int, DYLiveAmbientRGB)]) -> DYLiveAmbientBitmap {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    func write(_ x: Int, _ y: Int, _ sample: DYLiveAmbientRGB) {
        let index = (y * width + x) * 4
        rgba[index] = UInt8((min(1, max(0, sample.red)) * 255).rounded())
        rgba[index + 1] = UInt8((min(1, max(0, sample.green)) * 255).rounded())
        rgba[index + 2] = UInt8((min(1, max(0, sample.blue)) * 255).rounded())
        rgba[index + 3] = 255
    }
    for y in 0..<height {
        for x in 0..<width { write(x, y, color) }
    }
    for spot in spots {
        let x0 = spot.0, y0 = spot.1, w = spot.2, h = spot.3
        for y in y0..<(y0 + h) {
            for x in x0..<(x0 + w) where x >= 0 && y >= 0 && x < width && y < height {
                write(x, y, spot.4)
            }
        }
    }
    return DYLiveAmbientBitmap(width: width, height: height, rgba: rgba)
}

func hueGap(_ a: DYLiveAmbientRGB, _ b: DYLiveAmbientRGB) -> CGFloat {
    DYLiveAmbientTreatment.hueDistance(DYLiveAmbientTreatment.hsv(a).h, DYLiveAmbientTreatment.hsv(b).h)
}

let fieldBlue = DYLiveAmbientRGB(red: 0.12, green: 0.28, blue: 0.82)
let logoRed = DYLiveAmbientRGB(red: 0.9, green: 0.05, blue: 0.08)
let logo = paint(48, 48, fieldBlue, [(40, 4, 1, 1, logoRed)])
let logoPalette = DYLiveAmbientPalette.extract(from: logo)
check(logoPalette.primary.blue > logoPalette.primary.red, "a blue field stays blue beside a one-pixel logo")
check(hueGap(logoPalette.secondary, logoRed) > 0.12, "a one-pixel red logo is not chosen as the secondary color")
check(hueGap(logoPalette.primary, logoPalette.secondary) < 0.08, "a one-pixel accent stays on the dominant hue")

let orange = DYLiveAmbientRGB(red: 0.92, green: 0.42, blue: 0.12)
let yellowField = DYLiveAmbientRGB(red: 0.98, green: 0.9, blue: 0.25)
let warm = paint(40, 40, orange, [(0, 0, 16, 30, yellowField)])
let warmPalette = DYLiveAmbientPalette.extract(from: warm)
check(warmPalette.primary.red > warmPalette.primary.blue, "warm artwork keeps a warm primary")
check(warmPalette.secondary.green + 0.02 >= warmPalette.primary.green, "a large yellow region can lead the secondary color")

let cyan = DYLiveAmbientRGB(red: 0, green: 0.9, blue: 1)
let speck = paint(40, 40, orange, [(0, 0, 4, 4, cyan)])
let speckPalette = DYLiveAmbientPalette.extract(from: speck)
check(hueGap(speckPalette.secondary, cyan) > 0.12, "a one-percent cyan speck does not become the secondary color")

let mono = paint(24, 24, fieldBlue, [])
let monoPalette = DYLiveAmbientPalette.extract(from: mono)
check(hueGap(monoPalette.primary, monoPalette.secondary) < 0.05, "single-color artwork does not invent a rotated accent")

let grey = DYLiveAmbientRGB(red: 0.45, green: 0.45, blue: 0.45)
let greyArt = paint(24, 24, grey, [(2, 2, 1, 1, logoRed)])
let greyPalette = DYLiveAmbientPalette.extract(from: greyArt)
check(DYLiveAmbientTreatment.hsv(greyPalette.secondary).s < 0.25, "grey artwork with one saturated pixel stays low saturation")

let gameRed = DYLiveAmbientRGB(red: 0.82, green: 0.08, blue: 0.1)
let gameGreen = DYLiveAmbientRGB(red: 0.1, green: 0.75, blue: 0.2)
let game = paint(40, 40, fieldBlue, [(0, 0, 40, 14, gameRed), (0, 14, 40, 8, gameGreen)])
let gamePalette = DYLiveAmbientPalette.extract(from: game)
check(gamePalette.primary.blue > gamePalette.primary.red, "the largest region leads the primary color")
check(gamePalette.secondary.red > gamePalette.secondary.blue, "the second-largest region leads the secondary color")

let nearBlack = paint(16, 16, DYLiveAmbientRGB(red: 0.01, green: 0.01, blue: 0.015), [])
let blackPalette = DYLiveAmbientPalette.extract(from: nearBlack)
check(DYLiveAmbientTreatment.relativeLuminance(blackPalette.primary) < 0.08, "near-black artwork stays dark")

let pale = paint(16, 16, DYLiveAmbientRGB(red: 0.96, green: 0.94, blue: 0.82), [])
let palePalette = DYLiveAmbientPalette.extract(from: pale)
check(DYLiveAmbientTreatment.relativeLuminance(palePalette.primary) < 0.2, "bright artwork is compressed before it is used as a glow")
check(DYLiveAmbientTreatment.relativeLuminance(palePalette.primary) > DYLiveAmbientTreatment.relativeLuminance(blackPalette.primary), "bright artwork remains lighter than near-black artwork")

let saturatedRed = paint(16, 16, DYLiveAmbientRGB(red: 1, green: 0, blue: 0), [])
let saturatedBlue = paint(16, 16, DYLiveAmbientRGB(red: 0, green: 0.35, blue: 1), [])
let redPalette = DYLiveAmbientPalette.extract(from: saturatedRed)
let bluePalette = DYLiveAmbientPalette.extract(from: saturatedBlue)
check(redPalette.primary.red > redPalette.primary.blue, "saturated red keeps its hue")
check(bluePalette.primary.blue > bluePalette.primary.red, "saturated cyan-blue keeps its hue")
check(DYLiveAmbientTreatment.hsv(redPalette.primary).s < 0.85, "saturated red is kept below neon")

let fixtures = [logoPalette, warmPalette, speckPalette, monoPalette, greyPalette, gamePalette, blackPalette, palePalette, redPalette, bluePalette]
for fixture in fixtures {
    for location: CGFloat in [0, 0.5, 1] {
        let contrast = DYLiveAmbientTreatment.whiteTextContrast(on: DYLiveAmbientTreatment.composited(fixture, location: location))
        check(contrast >= DYLiveAmbientTreatment.minimumTextContrast, "fixture contrast at \(location) stays readable")
    }
}
check(DYLiveAmbientTreatment.composited(nil, location: 0.5).red < 0.08, "missing artwork still uses the dark plate")

let timingSample = paint(72, 72, fieldBlue, [(0, 0, 8, 8, logoRed)])
let rounds = 20
let blurStarted = Date()
for _ in 0..<rounds {
    _ = DYLiveAmbientPalette.extract(from: DYLiveAmbientBlur.soften(timingSample))
}
let blurSeconds = Date().timeIntervalSince(blurStarted)
let directStarted = Date()
for _ in 0..<rounds {
    _ = DYLiveAmbientPalette.extract(from: timingSample)
}
let directSeconds = Date().timeIntervalSince(directStarted)
print(String(format: "PALETTE_TIMING blur=%.3fms direct=%.3fms", blurSeconds / Double(rounds) * 1000, directSeconds / Double(rounds) * 1000))

if failures.isEmpty {
    print("DYLiveAmbient passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


def section(text: str, start: str, end: str) -> str:
    if start not in text or end not in text:
        raise AssertionError(f"missing marker {start}")
    return text[text.index(start) + len(start):text.index(end)]


class LiveAmbientBackgroundTests(unittest.TestCase):
    def test_treatment_and_blur_cache(self):
        source = SOURCE.read_text()
        treatment = section(source, "// MARK: - ambient-treatment\n", "// MARK: - ambient-treatment-end\n")
        swift = "import CoreGraphics\nimport Foundation\n" + LAYOUT.read_text() + "\n" + treatment + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-live-ambient-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(
                ["swift", "-module-cache-path", str(Path(tmp) / "cache"), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYLiveAmbient passed", completed.stdout)

    def test_view_does_not_reprocess_in_body(self):
        source = SOURCE.read_text()
        body = section(source, "// MARK: - ambient-body\n", "// MARK: - ambient-body-end\n")
        refresh = section(source, "// MARK: - ambient-refresh\n", "// MARK: - ambient-refresh-end\n")
        for banned in ("soften", "boxBlur", "UIGraphicsImageRenderer", "loadThumb", "scaled(from"):
            self.assertNotIn(banned, body)
        self.assertIn("DYLiveAmbientTreatment.fade", body)
        self.assertIn("DYLiveAmbientTreatment.plateStops", body)
        self.assertIn("glowField", body)
        self.assertIn("EllipticalGradient", source)
        self.assertNotIn("extract", body)
        self.assertNotIn("graded", body)
        self.assertIn("transitionDuration", body)
        self.assertIn("displayedKey == sourceToken", body)
        self.assertEqual(refresh.count("loadThumb("), 1)
        self.assertNotIn("ImageCache.shared.load(", refresh)
        self.assertIn("shouldApply", refresh)
        self.assertNotIn("soften", refresh)
        self.assertIn("DYLiveAmbientPalette.extract", refresh)
        self.assertNotIn("scaledToFill", source)
        self.assertNotIn("interpolation(.low)", source)
        self.assertNotIn("scaleEffect", source)
        self.assertIn("artworkStops", source)
        self.assertIn("peek", refresh)
        self.assertNotIn("URLSession", source)
        self.assertNotIn("VLC", source)
        self.assertNotIn("DYLiveFeed", source)
        self.assertNotIn("DouyinLiveRoom", source)
        self.assertNotIn("print(", source)
        self.assertNotIn("repeatForever", source)
        self.assertNotIn("TimelineView", source)
        room = ROOM.read_text()
        self.assertEqual(room.count("DouyinLiveAmbientBackground("), 1)
        self.assertIn('isolationID: "\\(bridge.followSession):\\(room.id)"', room)
        self.assertNotIn("isolationID: room.cover", room)
        self.assertNotIn("isolationID: room.avatar", room)


if __name__ == "__main__":
    unittest.main()
