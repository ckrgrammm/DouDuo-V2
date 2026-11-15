#!/usr/bin/env python3
"""编译直播自适应布局的纯计算。不启动模拟器，也不连接直播。

Run: python3 scripts/test_live_adaptive_layout.py -v
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo/DouyinLiveAdaptiveLayout.swift"

HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let tableBounds = CGRect(x: 0, y: 0, width: 400, height: 800)
let tableHinge = DYLiveDivision(frame: CGRect(x: 0, y: 360, width: 400, height: 80), isActive: true)
let bookBounds = CGRect(x: 0, y: 0, width: 800, height: 400)
let bookHinge = DYLiveDivision(frame: CGRect(x: 360, y: 0, width: 80, height: 400), isActive: true)
let landscape = CGSize(width: 1920, height: 1080)
let portrait = CGSize(width: 1080, height: 1920)

func decide(_ bounds: CGRect, _ status: DYLiveHingeStatus, _ divisions: [DYLiveDivision], _ video: CGSize?) -> DYLiveAdaptiveDecision {
    DYLiveAdaptiveLayoutEngine.decide(bounds: bounds, status: status, divisions: divisions, videoSize: video)
}
func overlaps(_ a: CGRect, _ b: CGRect) -> Bool { !a.intersection(b).isEmpty }

let tableLandscape = decide(tableBounds, .partiallyOpen, [tableHinge], landscape)
check(tableLandscape.layout == .layoutA, "tabletop landscape uses layout A")
check(tableLandscape.video == CGRect(x: 0, y: 0, width: 400, height: 360), "layout A video is the upper pane")
check(tableLandscape.interaction == CGRect(x: 0, y: 440, width: 400, height: 360), "layout A interaction is the lower pane")
check(!overlaps(tableLandscape.video, tableHinge.frame), "layout A video excludes the hinge")
check(!overlaps(tableLandscape.interaction, tableHinge.frame), "layout A interaction excludes the hinge")
check(!overlaps(tableLandscape.video, tableLandscape.interaction), "layout A panes do not overlap")

let tablePortrait = decide(tableBounds, .partiallyOpen, [tableHinge], portrait)
check(tablePortrait.layout == .existing, "tabletop portrait keeps the existing layout")
check(tablePortrait.video == tableBounds && tablePortrait.interaction == tableBounds, "existing layout fills the bounds")

let tableMissing = decide(tableBounds, .partiallyOpen, [tableHinge], nil)
check(tableMissing.layout == .existing, "tabletop unknown dimensions keep the existing layout")
check(tableMissing.video == tableBounds, "unknown tabletop video stays full bleed")

let bookLandscape = decide(bookBounds, .partiallyOpen, [bookHinge], landscape)
check(bookLandscape.layout == .layoutB, "book landscape uses layout B")
check(bookLandscape.video == CGRect(x: 0, y: 0, width: 360, height: 400), "layout B video is the leading pane")
check(bookLandscape.interaction == CGRect(x: 440, y: 0, width: 360, height: 400), "layout B interaction is the trailing pane")
check(!overlaps(bookLandscape.video, bookHinge.frame), "layout B video excludes the hinge")
check(!overlaps(bookLandscape.interaction, bookHinge.frame), "layout B interaction excludes the hinge")

let bookPortrait = decide(bookBounds, .partiallyOpen, [bookHinge], portrait)
check(bookPortrait.layout == .layoutB, "book portrait uses layout B")
check(bookPortrait.video == bookLandscape.video && bookPortrait.interaction == bookLandscape.interaction, "book portrait uses the same panes")

let bookMissing = decide(bookBounds, .partiallyOpen, [bookHinge], nil)
check(bookMissing.layout == .layoutB, "book unknown dimensions use layout B")

for status: DYLiveHingeStatus in [.fullyOpen, .closed, .unsupported] {
    let decision = decide(tableBounds, status, [tableHinge], landscape)
    check(decision.layout == .existing, "\(status) keeps the existing layout")
    check(decision.video == tableBounds && decision.interaction == tableBounds, "\(status) fills the bounds")
}

let squareBand = DYLiveDivision(frame: CGRect(x: 100, y: 300, width: 200, height: 200), isActive: true)
let outside = DYLiveDivision(frame: CGRect(x: 0, y: -500, width: 400, height: 40), isActive: true)
let corner = DYLiveDivision(frame: CGRect(x: 0, y: 360, width: 80, height: 40), isActive: true)
let thick = DYLiveDivision(frame: CGRect(x: 0, y: 200, width: 400, height: 400), isActive: true)
let inactive = DYLiveDivision(frame: tableHinge.frame, isActive: false)
let zeroBand = DYLiveDivision(frame: CGRect(x: 0, y: 360, width: 400, height: 0), isActive: true)
let second = DYLiveDivision(frame: CGRect(x: 0, y: 100, width: 400, height: 40), isActive: true)
for (name, divisions) in [
    ("square", [squareBand]),
    ("outside", [outside]),
    ("short", [corner]),
    ("thick", [thick]),
    ("inactive", [inactive]),
    ("zero", [zeroBand]),
    ("two", [tableHinge, second]),
    ("none", [] as [DYLiveDivision]),
] {
    let decision = decide(tableBounds, .partiallyOpen, divisions, landscape)
    check(decision.layout == .existing, "invalid hinge \(name) keeps the existing layout")
    check(decision.video == tableBounds, "invalid hinge \(name) does not move the video")
}

check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: 1080, height: 1080)) == .unknown, "square video is unknown")
check(decide(tableBounds, .partiallyOpen, [tableHinge], CGSize(width: 1080, height: 1080)).layout == .existing, "square video in tabletop stays existing")
check(decide(bookBounds, .partiallyOpen, [bookHinge], CGSize(width: 1080, height: 1080)).layout == .layoutB, "square video in book still uses layout B")
check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: 1100, height: 1000)) == .unknown, "near-square video is unknown")
check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: 1200, height: 1000)) == .landscape, "1.2 ratio is landscape")
check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: 1000, height: 1200)) == .portrait, "1.2 ratio is portrait")
check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: 0, height: 1080)) == .unknown, "zero width is unknown")
check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: -10, height: 1080)) == .unknown, "negative size is unknown")
check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: CGFloat.nan, height: 1080)) == .unknown, "NaN size is unknown")
check(DYLiveAdaptiveLayoutEngine.orientation(videoSize: CGSize(width: CGFloat.infinity, height: 1080)) == .unknown, "infinite size is unknown")
check(decide(tableBounds, .partiallyOpen, [tableHinge], CGSize(width: 0, height: 1080)).layout == .existing, "zero size in tabletop stays existing")
check(decide(bookBounds, .partiallyOpen, [bookHinge], CGSize(width: CGFloat.nan, height: CGFloat.nan)).layout == .layoutB, "invalid size in book still uses layout B")

let empty = decide(.zero, .partiallyOpen, [tableHinge], landscape)
check(empty.layout == .existing && empty.video == .zero && empty.interaction == .zero, "zero bounds produce an empty existing layout")
let nanBounds = decide(CGRect(x: CGFloat.nan, y: 0, width: 400, height: 800), .partiallyOpen, [tableHinge], landscape)
check(nanBounds.video == .zero && nanBounds.layout == .existing, "non-finite bounds produce an empty existing layout")

let shifted = CGRect(x: 10, y: 20, width: 400, height: 800)
let shiftedHinge = DYLiveDivision(frame: CGRect(x: -20, y: 380, width: 500, height: 80), isActive: true)
let shiftedDecision = decide(shifted, .partiallyOpen, [shiftedHinge], landscape)
check(shiftedDecision.layout == .layoutA, "hinge clipped to shifted bounds still splits")
check(shiftedDecision.video == CGRect(x: 10, y: 20, width: 400, height: 360), "upper pane respects bounds origin")
check(shiftedDecision.interaction == CGRect(x: 10, y: 460, width: 400, height: 360), "lower pane starts after the clipped hinge")
check(!overlaps(shiftedDecision.video, shiftedHinge.frame.intersection(shifted)), "clipped hinge stays out of the video")

let edge = DYLiveDivision(frame: CGRect(x: 0, y: 0, width: 400, height: 80), isActive: true)
check(decide(tableBounds, .partiallyOpen, [edge], landscape).layout == .existing, "a pane thinner than 20 percent stays existing")

let again = decide(tableBounds, .partiallyOpen, [tableHinge], landscape)
check(again == tableLandscape, "the same input decides the same rectangles")

check(DYLiveAdaptiveLayoutEngine.presentationSize(ready: false, videoSize: landscape) == nil, "a room that is not ready does not reuse the previous size")
check(DYLiveAdaptiveLayoutEngine.presentationSize(ready: true, videoSize: CGSize(width: 0, height: 1080)) == nil, "a ready room with an invalid size stays unknown")
check(DYLiveAdaptiveLayoutEngine.presentationSize(ready: true, videoSize: landscape) == landscape, "a ready landscape size is usable")
check(DYLiveAdaptiveLayoutEngine.presentationSize(ready: true, videoSize: CGSize(width: 1080, height: 1080)) == CGSize(width: 1080, height: 1080), "a square size is kept so orientation can reject it")

let held = DYLiveAdaptiveMemory(decision: tableLandscape, bounds: tableBounds)
let blip = DYLiveAdaptiveLayoutEngine.stabilize(previous: held, proposed: decide(tableBounds, .partiallyOpen, [], landscape), status: .partiallyOpen, bounds: tableBounds, divisions: [])
check(blip.decision == tableLandscape, "a one-frame missing hinge keeps the current split")
let portraitProposed = decide(tableBounds, .partiallyOpen, [tableHinge], portrait)
let turned = DYLiveAdaptiveLayoutEngine.stabilize(previous: held, proposed: portraitProposed, status: .partiallyOpen, bounds: tableBounds, divisions: [tableHinge])
check(turned.decision.layout == .existing, "portrait on tabletop leaves the split immediately")
let opened = DYLiveAdaptiveLayoutEngine.stabilize(previous: held, proposed: decide(tableBounds, .fullyOpen, [tableHinge], landscape), status: .fullyOpen, bounds: tableBounds, divisions: [tableHinge])
check(opened.decision.layout == .existing, "fully open drops the held split")
let resized = tableBounds.insetBy(dx: 0, dy: 20)
let moved = DYLiveAdaptiveLayoutEngine.stabilize(previous: held, proposed: decide(resized, .partiallyOpen, [], landscape), status: .partiallyOpen, bounds: resized, divisions: [])
check(moved.decision.layout == .existing, "a bounds change does not reuse the old panes")
check(DYLiveAdaptiveLayoutEngine.hingeIsTransient(bounds: tableBounds, status: .partiallyOpen, divisions: [squareBand]), "an unusable band is transient")
check(!DYLiveAdaptiveLayoutEngine.hingeIsTransient(bounds: tableBounds, status: .fullyOpen, divisions: []), "fully open is not a transient hinge")

let immediate = decide(tableBounds, .partiallyOpen, [tableHinge], landscape)
check(immediate.layout == .layoutA, "tabletop uses layout A when landscape size is already known")
let waiting = decide(tableBounds, .partiallyOpen, [tableHinge], nil)
check(waiting.layout == .existing, "tabletop stays immersive while the size is still unknown")
let delayedLandscape = decide(tableBounds, .partiallyOpen, [tableHinge], landscape)
let remembered = DYLiveAdaptiveMemory(decision: waiting, bounds: tableBounds)
let adopted = DYLiveAdaptiveLayoutEngine.stabilize(previous: remembered, proposed: delayedLandscape, status: .partiallyOpen, bounds: tableBounds, divisions: [tableHinge])
check(adopted.decision.layout == .layoutA, "a late landscape size replaces the immersive hold")
let delayedPortrait = decide(tableBounds, .partiallyOpen, [tableHinge], portrait)
let portraitMemory = DYLiveAdaptiveLayoutEngine.stabilize(previous: remembered, proposed: delayedPortrait, status: .partiallyOpen, bounds: tableBounds, divisions: [tableHinge])
check(portraitMemory.decision.layout == .existing, "a late portrait size stays immersive on tabletop")
check(decide(bookBounds, .partiallyOpen, [bookHinge], nil).layout == .layoutB, "layout B does not wait for a video size")

func accept(_ current: CGSize, _ sample: CGSize, _ generation: Int, _ callback: Int, _ playerIsCurrent: Bool = true) -> CGSize? {
    DYLiveAdaptiveLayoutEngine.acceptedSize(current: current, sample: sample, generation: generation, callbackGeneration: callback, playerIsCurrent: playerIsCurrent)
}
check(accept(.zero, landscape, 1, 1) == landscape, "the first landscape sample is published")
check(accept(landscape, landscape, 1, 1) == nil, "an unchanged landscape size is not published again")
check(accept(.zero, portrait, 2, 2) == portrait, "the first portrait sample is published")
check(accept(.zero, .zero, 2, 2) == nil, "a zero sample stays unpublished")
check(accept(.zero, CGSize(width: 1, height: 1), 2, 2) == nil, "a one-pixel sample stays unpublished")
check(accept(.zero, landscape, 1, 2) == nil, "a callback from the previous room is ignored")
check(accept(.zero, landscape, 2, 2, false) == nil, "an inactive player does not publish")

var published = CGSize.zero
if let next = accept(published, landscape, 1, 1) { published = next }
check(published == landscape, "room 1 keeps its landscape size")
published = .zero
check(accept(published, landscape, 1, 2) == nil, "room 1 cannot publish after the generation changes")
if let next = accept(published, portrait, 2, 2) { published = next }
check(published == portrait, "room 2 publishes portrait after the switch")
published = .zero
if let next = accept(published, landscape, 3, 3) { published = next }
check(published == landscape, "room 3 publishes landscape after leaving the portrait room")
check(decide(tableBounds, .partiallyOpen, [tableHinge], published).layout == .layoutA, "the published landscape size selects layout A")
check(decide(tableBounds, .partiallyOpen, [tableHinge], portrait).layout == .existing, "decoded portrait stays immersive when other metadata might disagree")

func aspectFit(_ pane: CGRect, _ aspect: CGFloat) -> CGRect {
    if pane.width / pane.height > aspect {
        let width = pane.height * aspect
        return CGRect(x: pane.midX - width / 2, y: pane.minY, width: width, height: pane.height)
    }
    let height = pane.width / aspect
    return CGRect(x: pane.minX, y: pane.midY - height / 2, width: pane.width, height: height)
}
let wide = CGFloat(16) / 9
let tall = CGFloat(9) / 16
let fittedA = aspectFit(tableLandscape.video, wide)
check(abs(fittedA.width - tableLandscape.video.width) < 0.05, "layout A 16:9 uses the full upper-pane width")
check(fittedA.height < tableLandscape.video.height, "layout A keeps the 16:9 height inside the taller pane")
check(tableLandscape.video.contains(fittedA), "layout A picture stays inside the upper pane")
check(!overlaps(fittedA, tableHinge.frame), "layout A picture stays clear of the hinge")
let fittedB = aspectFit(bookLandscape.video, wide)
check(abs(fittedB.width - bookLandscape.video.width) < 0.05, "layout B 16:9 uses the full leading-pane width")
check(fittedB.height < bookLandscape.video.height * 0.7, "layout B 16:9 stays a strip inside the tall pane")
check(bookLandscape.video.contains(fittedB), "layout B picture stays inside the leading pane")
check(!overlaps(fittedB, bookHinge.frame), "layout B picture stays clear of the hinge")
let fittedPortrait = aspectFit(bookPortrait.video, tall)
check(abs(fittedPortrait.height - bookPortrait.video.height) < 0.05, "portrait video fills the leading pane height")
check(fittedPortrait.width < bookPortrait.video.width, "portrait video is not stretched across the leading pane")

let safeTop: CGFloat = 59
let wide21 = CGFloat(2)
let lowered = DYLiveLayoutAVideo.frame(in: tableLandscape.video, aspect: wide, safeTop: safeTop)
let clearance = safeTop + DYLiveLayoutAVideo.statusMargin
check(abs(lowered.width - tableLandscape.video.width) < 0.05, "16:9 keeps the full upper-pane width")
check(abs(lowered.height - tableLandscape.video.width / wide) < 0.05, "16:9 keeps its height while moving down")
check(lowered.minY >= clearance - 0.05, "16:9 starts below the status bar and its margin")
check(abs(lowered.maxY - tableLandscape.video.maxY) < 0.05, "16:9 sits on the bottom of the upper pane")
check(abs(lowered.midX - tableLandscape.video.midX) < 0.05, "16:9 stays horizontally centered")
check(!overlaps(lowered, tableHinge.frame), "the lowered picture stays clear of the hinge")
check(!overlaps(lowered, tableLandscape.interaction), "the lowered picture stays out of the interaction pane")
let wider = DYLiveLayoutAVideo.frame(in: tableLandscape.video, aspect: wide21, safeTop: safeTop)
check(abs(wider.width / wider.height - wide21) < 0.002, "a 2:1 stream keeps its aspect")
check(abs(wider.width - tableLandscape.video.width) < 0.05, "a wider stream still uses the pane width when it fits")
check(abs(wider.maxY - tableLandscape.video.maxY) < 0.05, "a wider stream also sits on the pane bottom")
let shortPane = CGRect(x: 0, y: 0, width: 400, height: 200)
let reduced = DYLiveLayoutAVideo.frame(in: shortPane, aspect: wide, safeTop: safeTop)
check(abs(reduced.width / reduced.height - wide) < 0.002, "a short pane scales 16:9 instead of cropping it")
check(reduced.width < shortPane.width - 1, "a short pane gives up width rather than crossing the status bar")
check(reduced.minY >= clearance - 0.05 && abs(reduced.maxY - shortPane.maxY) < 0.05, "the reduced picture fills the space under the status bar")
let unknownFrame = DYLiveLayoutAVideo.frame(in: tableLandscape.video, aspect: 0, safeTop: safeTop)
check(abs(unknownFrame.minY - clearance) < 0.05 && abs(unknownFrame.maxY - tableLandscape.video.maxY) < 0.05, "an unknown size stays below the status bar")
check(abs(unknownFrame.width - tableLandscape.video.width) < 0.05, "an unknown size still uses the pane width")
let arrived = DYLiveLayoutAVideo.frame(in: tableLandscape.video, aspect: DYLiveLayoutAVideo.aspect(of: landscape), safeTop: safeTop)
check(abs(arrived.width / arrived.height - (1920.0 / 1080.0)) < 0.002, "a late landscape size uses the decoded aspect")
check(arrived.minY >= clearance - 0.05, "a late landscape size still clears the status bar")
let alreadyBelow = CGRect(x: 0, y: 80, width: 400, height: 280)
let once = DYLiveLayoutAVideo.frame(in: alreadyBelow, aspect: wide, safeTop: safeTop)
check(abs(once.minY - (alreadyBelow.maxY - alreadyBelow.width / wide)) < 0.05, "a pane that already starts below the status bar is not inset again")
check(DYLiveLayoutAVideo.aspect(of: .zero) == 0, "a missing size does not invent an aspect")

if failures.isEmpty {
    print("DYLiveAdaptiveLayout passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


TOGGLE_HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}
func overlaps(_ a: CGRect, _ b: CGRect) -> Bool { !a.intersection(b).isEmpty }

let full = CGRect(x: 0, y: 0, width: 400, height: 800)
let wide = CGRect(x: 0, y: 0, width: 800, height: 400)
let tableHinge = DYLiveDivision(frame: CGRect(x: 0, y: 360, width: 400, height: 80), isActive: true)
let bookHinge = DYLiveDivision(frame: CGRect(x: 360, y: 0, width: 80, height: 400), isActive: true)
let landscape = CGSize(width: 1920, height: 1080)
let portrait = CGSize(width: 1080, height: 1920)
func decide(_ bounds: CGRect, _ status: DYLiveHingeStatus, _ divisions: [DYLiveDivision], _ video: CGSize?) -> DYLiveAdaptiveDecision {
    DYLiveAdaptiveLayoutEngine.decide(bounds: bounds, status: status, divisions: divisions, videoSize: video)
}
let tableLandscape = decide(full, .partiallyOpen, [tableHinge], landscape)
let tablePortrait = decide(full, .partiallyOpen, [tableHinge], portrait)
let tableMissing = decide(full, .partiallyOpen, [tableHinge], nil)
let bookLandscape = decide(wide, .partiallyOpen, [bookHinge], landscape)
let lower = tableLandscape.interaction
let right = bookLandscape.interaction

func placed(_ eligible: DYLiveAdaptiveLayout, _ manual: Bool, _ bounds: CGRect, _ interaction: CGRect, _ compact: Bool = false, _ safeBottom: CGFloat = 34, _ safeTrailing: CGFloat = 0, _ keyboard: CGFloat = 0, _ entered: Bool = true) -> DYLiveLayoutTogglePlacement {
    DYLiveLayoutToggle.place(eligible: eligible, manual: manual, bounds: bounds, interaction: interaction, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing, keyboardOverlap: keyboard, entered: entered)
}

let splitA = placed(.layoutA, false, full, lower)
check(splitA.role == .enterImmersive, "layout A shows 整屏")
check(splitA.frame == CGRect(x: 310, y: 452, width: 72, height: 36), "layout A toggle sits in the upper-right of the lower pane")
check(lower.contains(splitA.frame), "layout A toggle stays inside the interaction pane")
check(!overlaps(splitA.frame, tableLandscape.video), "layout A toggle stays off the video")
let returnA = CGRect(x: lower.minX + 18, y: lower.minY + 12, width: 96, height: 40)
let composerA = CGRect(x: 18, y: 710, width: 364, height: 44)
check(!overlaps(splitA.frame, returnA), "layout A toggle stays clear of 返回")
check(!overlaps(splitA.frame, composerA), "layout A toggle stays clear of the comment row")

let immersiveA = placed(.layoutA, true, full, lower)
check(immersiveA.role == .restoreSplit, "layout A immersive shows 分屏")
check(immersiveA.frame == CGRect(x: 310, y: 662, width: 72, height: 36), "narrow immersive 分屏 moves above the comment row")
check(!overlaps(immersiveA.frame, composerA), "分屏 stays clear of the comment row and More button")
check(immersiveA.frame.maxY <= full.maxY - 34, "分屏 stays above the bottom safe area")
check(!overlaps(immersiveA.frame, returnA), "分屏 stays clear of the top exit button")

let backA = placed(.layoutA, false, full, lower)
check(backA.role == .enterImmersive && backA.frame == splitA.frame, "tapping 分屏 restores layout A placement")

let splitB = placed(.layoutB, false, wide, right)
check(splitB.role == .enterImmersive, "layout B shows 整屏")
check(splitB.frame.minX == right.minX + 18, "layout B toggle aligns with 返回")
check(splitB.frame.minY == right.minY + 70 + 40 + 12, "layout B toggle sits 12pt below 返回")
let returnB = CGRect(x: right.minX + 18, y: right.minY + 70, width: 96, height: 40)
let pillB = CGRect(x: returnB.maxX + 10, y: returnB.minY, width: 140, height: 40)
check(!overlaps(splitB.frame, returnB), "layout B toggle does not cover 返回")
check(!overlaps(splitB.frame, pillB), "layout B toggle leaves the streamer pill clear")
check(!overlaps(splitB.frame, bookLandscape.video), "layout B toggle stays off the video")
let composerB = CGRect(x: right.minX + 18, y: right.maxY - 46 - 44, width: min(420, right.width - 36), height: 44)
check(!overlaps(splitB.frame, composerB), "layout B toggle stays clear of the comment row")

let compactB = placed(.layoutB, false, wide, right, true)
check(compactB.frame.minY == right.minY + 64 + 40 + 12, "compact layout B uses the compact return inset")

let immersiveB = placed(.layoutB, true, wide, right)
check(immersiveB.role == .restoreSplit, "layout B immersive shows 分屏")
check(immersiveB.frame == CGRect(x: 710, y: 318, width: 72, height: 36), "wide immersive 分屏 sits in the lower-right")
check(immersiveB.frame.minY > splitB.frame.maxY, "immersive 分屏 leaves the position under 返回")
let composerWide = CGRect(x: 18, y: 310, width: 420, height: 44)
check(!overlaps(immersiveB.frame, composerWide), "wide 分屏 stays clear of the comment row")
check(immersiveB.frame.maxY <= wide.maxY - 34, "wide 分屏 stays above the bottom safe area")

let backB = placed(.layoutB, false, wide, right)
check(backB == splitB, "tapping 分屏 restores layout B placement")

let previewB = placed(.layoutB, false, wide, right, false, 34, 0, 0, false)
check(previewB.role == .enterImmersive, "layout B preview shows 整屏")
check(previewB.frame == CGRect(x: 710, y: 318, width: 72, height: 36), "layout B preview sits in the lower-right of the right pane")
check(right.contains(previewB.frame), "layout B preview stays inside the interaction pane")
check(previewB.frame.maxX == right.maxX - 18, "layout B preview uses the pane trailing edge")
check(previewB.frame.maxY <= right.maxY - 34, "layout B preview stays above the bottom safe area")
check(!overlaps(previewB.frame, returnB), "layout B preview stays off 返回")
let previewEntry = CGRect(x: right.minX + 20, y: right.maxY - 58 - 44, width: 168, height: 44)
check(!overlaps(previewB.frame, previewEntry), "layout B preview stays off the enter button")
check(placed(.layoutA, false, full, lower, false, 34, 0, 0, false) == splitA, "layout A preview keeps the lower-pane placement")
let previewImmersive = placed(.layoutB, true, wide, right, false, 34, 0, 0, false)
check(previewImmersive == immersiveB, "layout B preview immersive uses the full-display 分屏")
check(placed(.layoutB, false, wide, right, false, 34, 0, 0, false) == previewB, "leaving preview immersive restores the pane corner")
check(placed(.layoutB, false, wide, right, false, 34, 0, 0, true) == splitB, "an entered room keeps the placement under 返回 while loading")
let trailedPreview = placed(.layoutB, false, wide, right, false, 34, 40, 0, false)
check(trailedPreview.frame.maxX == right.maxX - 40, "layout B preview respects the trailing safe area")
let narrow = CGRect(x: right.minX, y: right.minY, width: 220, height: right.height)
let narrowPreview = placed(.layoutB, false, wide, narrow, false, 34, 0, 0, false)
let narrowEntry = CGRect(x: narrow.minX + 20, y: narrow.maxY - 58 - 44, width: 168, height: 44)
check(!overlaps(narrowPreview.frame, narrowEntry), "a narrow preview pane lifts 整屏 off the enter button")
check(narrow.contains(narrowPreview.frame), "the lifted preview toggle stays inside the right pane")

for status: DYLiveHingeStatus in [.fullyOpen, .closed, .unsupported] {
    let decision = decide(full, status, [tableHinge], landscape)
    let hidden = placed(decision.layout, true, full, decision.interaction)
    check(decision.layout == .existing && hidden.role == .hidden && hidden.frame == .zero, "\(status) hides the toggle")
}
let portraitHidden = placed(tablePortrait.layout, true, full, tablePortrait.interaction)
check(portraitHidden.role == .hidden, "tabletop portrait hides 分屏 because no split can be restored")
let unknownHidden = placed(tableMissing.layout, false, full, tableMissing.interaction)
check(unknownHidden.role == .hidden, "tabletop unknown stream hides the toggle")

check(DYLiveLayoutToggle.manualApplies(active: true, anchored: .layoutA, eligible: .layoutA), "the same split keeps manual immersive across a room change")
check(!DYLiveLayoutToggle.manualApplies(active: true, anchored: .layoutA, eligible: tablePortrait.layout), "portrait clears an invalid override")
check(!DYLiveLayoutToggle.manualApplies(active: true, anchored: .layoutA, eligible: tableMissing.layout), "unknown orientation clears manual immersive until a split exists")
check(!DYLiveLayoutToggle.manualApplies(active: true, anchored: .layoutA, eligible: .layoutB), "tabletop to book drops the override and adopts the new split")
check(!DYLiveLayoutToggle.manualApplies(active: true, anchored: .layoutB, eligible: .layoutA), "book to tabletop drops the override")
check(!DYLiveLayoutToggle.manualApplies(active: true, anchored: .layoutB, eligible: .existing), "fully opening clears the override")
check(DYLiveLayoutToggle.manualApplies(active: true, anchored: .layoutB, eligible: .layoutB), "book layout keeps immersive when the next room is still book-eligible")
check(!DYLiveLayoutToggle.manualApplies(active: false, anchored: .layoutA, eligible: .layoutA), "automatic split is not a manual override")

let trailed = placed(.layoutA, false, full, lower, false, 34, 40)
check(trailed.frame.maxX == lower.maxX - 40, "trailing safe area insets the layout A toggle")
let keyboard = placed(.layoutA, true, full, lower, false, 34, 0, 300)
let keyboardComposer = CGRect(x: 18, y: 444, width: 364, height: 44)
check(keyboard.frame == CGRect(x: 310, y: 396, width: 72, height: 36), "keyboard lifts 分屏 above the comment row")
check(!overlaps(keyboard.frame, keyboardComposer), "keyboard 分屏 does not cover the composer")
check(keyboard.frame.maxY <= full.maxY - 300, "keyboard 分屏 stays above the keyboard")

let heldToggle = DYLiveAdaptiveLayoutEngine.stabilize(previous: DYLiveAdaptiveMemory(decision: tableLandscape, bounds: full), proposed: decide(full, .partiallyOpen, [], landscape), status: .partiallyOpen, bounds: full, divisions: [])
let during = placed(heldToggle.decision.layout, false, full, heldToggle.decision.interaction)
check(during == splitA, "a transient hinge keeps the single current toggle")

let moduleButton = CGSize(width: 54, height: 50)
let moduleA = DYLiveLayoutToggle.layoutAModuleFrame(interaction: lower, button: moduleButton, compact: false, safeBottom: 34, safeTrailing: 0)
check(moduleA == CGRect(x: 334, y: 704, width: 54, height: 50), "layout A module button sits in the lower-right of the interaction pane")
check(lower.contains(moduleA), "layout A module button stays inside the interaction pane")
check(moduleA.maxX == lower.maxX - 12, "layout A module button keeps the 12pt trailing margin")
check(moduleA.maxY == lower.maxY - 34 - 12, "layout A module button sits above the bottom safe area")
check(!overlaps(moduleA, splitA.frame), "layout A module button does not cover 整屏")
let entryA = CGRect(x: lower.minX + 20, y: lower.maxY - 58 - 44, width: min(168, lower.width - 40), height: 44)
check(!overlaps(moduleA, entryA), "layout A module button does not cover 进入直播间")
let trailedModule = DYLiveLayoutToggle.layoutAModuleFrame(interaction: lower, button: moduleButton, compact: false, safeBottom: 34, safeTrailing: 40)
check(trailedModule.maxX == lower.maxX - 40 - 12, "layout A module button respects the trailing safe area")
check(!overlaps(trailedModule, trailed.frame), "an inset module button still clears 整屏")
let shiftedPane = lower.offsetBy(dx: 30, dy: 15)
let shiftedModule = DYLiveLayoutToggle.layoutAModuleFrame(interaction: shiftedPane, button: moduleButton, compact: false, safeBottom: 34, safeTrailing: 0)
check(shiftedModule == moduleA.offsetBy(dx: 30, dy: 15), "layout A module button follows the pane origin")
let shortPane = CGRect(x: 0, y: 0, width: 400, height: 120)
let cramped = DYLiveLayoutToggle.layoutAModuleFrame(interaction: shortPane, button: moduleButton, compact: false, safeBottom: 34, safeTrailing: 0)
let crampedToggle = placed(.layoutA, false, shortPane, shortPane).frame
check(shortPane.contains(cramped), "a short pane keeps the module button inside")
check(!overlaps(cramped, crampedToggle), "a short pane moves the module button off 整屏")

if failures.isEmpty {
    print("DYLiveLayoutToggle passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class LiveAdaptiveLayoutTests(unittest.TestCase):
    def test_layout_decisions(self):
        swift = SOURCE.read_text() + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-live-adaptive-") as tmp:
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
        self.assertIn("DYLiveAdaptiveLayout passed", completed.stdout)

    def test_live_feed_keeps_one_surface(self):
        room = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
        feed = room.split("struct DYLiveFeed: View", 1)[1].split("private struct DYLiveRoomPage", 1)[0]
        self.assertEqual(feed.count("VLCPlayerSurface("), 1)
        self.assertIn("DYLiveAdaptiveLayoutEngine.decide", feed)
        self.assertIn("DYLiveAdaptiveLayoutEngine.stabilize", feed)
        self.assertIn("presentationSize", feed)
        self.assertIn("onLiveHingeChange", feed)
        self.assertIn("forceImmersive", feed)
        self.assertNotIn("vlc.play(", feed)
        self.assertNotIn("vlc.replace(", feed)
        self.assertNotIn("flatArrangement", feed)
        self.assertIn("DYLiveAmbientTreatment.axis(for: shown.layout)", feed)
        self.assertNotIn("DouyinLiveAmbientBackground", feed)
        self.assertNotIn("DYLiveVideoFit", feed)
        self.assertIn("shown.layout == .layoutA", feed)
        self.assertEqual(feed.count("DYLiveLayoutAVideo.frame"), 1)
        self.assertIn(": shown.video", feed)
        self.assertIn("pages(video: shown.video, interaction: shown.interaction", feed)
        self.assertIn("shown.layout == .existing && currentRoom?.portrait == true", feed)
        self.assertIn(".frame(width: videoFrame.width, height: videoFrame.height)", feed)
        self.assertIn(".position(x: videoFrame.midX, y: videoFrame.midY)", feed)
        self.assertNotIn(".frame(width: shown.video.width, height: shown.video.height)", feed)
        surface = feed.split("VLCPlayerSurface(", 1)[1].split("if model.rooms.isEmpty", 1)[0]
        self.assertNotIn("mediaPlayer.drawable", surface)
        self.assertNotIn(".play(", surface)
        self.assertNotIn(".replace(", surface)
        page = room.split("private struct DYLiveRoomPage", 1)[1].split("// MARK: - live-close-placement", 1)[0]
        self.assertEqual(page.count("DouyinLiveAmbientBackground("), 1)
        self.assertIn("if isCurrent, let axis = ambientAxis", page)
        self.assertNotIn("VLCPlayerSurface(", page)
        self.assertNotIn("vlc.", page)

    def test_late_video_size_does_not_restart_playback(self):
        bridge = (ROOT / "DouDuo/VLCPlayerBridge.swift").read_text()
        time_changed = bridge.split("func mediaPlayerTimeChanged", 1)[1].split("private func publishAcceptedVideoSize", 1)[0]
        publish = bridge.split("private func publishAcceptedVideoSize", 1)[1].split("func mediaPlayerStateChanged", 1)[0]
        state_changed = bridge.split("func mediaPlayerStateChanged", 1)[1]
        playing = state_changed.split("case .playing:", 1)[1].split("case .paused:", 1)[0]
        added = state_changed.split("case .esAdded:", 1)[1].split("default:", 1)[0]
        self.assertIn("publishAcceptedVideoSize(epoch: epoch)", time_changed)
        self.assertLess(time_changed.find("publishAcceptedVideoSize"), time_changed.find("seekTarget"))
        self.assertIn("acceptedSize", publish)
        self.assertNotIn(".play(", publish)
        self.assertNotIn(".replace(", publish)
        self.assertNotIn("mediaPlayer.play()", time_changed)
        self.assertIn("publishAcceptedVideoSize(epoch: epoch)", playing)
        self.assertIn("publishAcceptedVideoSize(epoch: epoch)", added)
        room = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
        layout = room.split("private func resolvedLayout", 1)[1].split("private func layoutTogglePlacement", 1)[0]
        self.assertIn("presentationSize(ready: model.ready, videoSize: model.playbackVideoSize)", layout)
        self.assertNotIn("model.vlc.videoSize", layout)
        self.assertNotIn("portrait", layout)
        self.assertNotIn(".play(", layout)
        self.assertNotIn(".replace(", layout)
        self.assertIn("vlc.onVideoSize", room)
        self.assertIn("playbackVideoSize = .zero", room)
        self.assertIn("onVideoSize?(next)", bridge)

    def test_toggle_placement_and_override(self):
        room = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
        start = "// MARK: - live-layout-toggle\n"
        end = "// MARK: - live-layout-toggle-end\n"
        if start not in room or end not in room:
            self.fail("live layout toggle calculation is missing")
        toggle = room[room.index(start):room.index(end)]
        keyboard_start = room.index("// MARK: - live-keyboard-layout\n")
        keyboard = room[keyboard_start:room.index("private struct DYLivePagingKeyboardLock")]
        swift = SOURCE.read_text() + "\n" + keyboard + "\n" + toggle + "\n" + TOGGLE_HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-live-toggle-") as tmp:
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
        self.assertIn("DYLiveLayoutToggle passed", completed.stdout)

        feed = room.split("struct DYLiveFeed: View", 1)[1].split("private struct DYLiveRoomPage", 1)[0]
        pages = feed.split("private func pages(", 1)[1].split("private func syncViewport", 1)[0]
        active = feed.split(".onChange(of: active)", 1)[1].split(".task", 1)[0]
        self.assertEqual(feed.count("layoutToggle(placement"), 1, "one toggle overlay")
        self.assertNotIn("layoutToggle(", pages)
        self.assertNotIn("forceImmersive", active)
        toggle_view = feed.split("private func layoutToggle", 1)[1].split("private func previewChrome", 1)[0]
        self.assertNotIn("vlc.", toggle_view)
        self.assertNotIn("clean", toggle_view)
        placement = feed.split("private func layoutTogglePlacement", 1)[1].split("private func liveDivisions", 1)[0]
        self.assertIn("entered: model.entered", placement)
        self.assertNotIn("model.ready", placement)
        anchor = feed.split("private func liveModuleAnchor", 1)[1].split("private func layoutTogglePlacement", 1)[0]
        self.assertIn("shown.layout == .layoutA", anchor)
        self.assertIn(".named(\"douduo.feed\")", anchor)
        self.assertIn("offsetBy(dx: origin.x, dy: origin.y)", anchor)
        screen = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
        button = screen.split("private var layoutAModuleButton", 1)[1].split("private var moduleCircleLabel", 1)[0]
        self.assertIn("layoutAModuleFrame", button)
        self.assertIn("place.midX - feedHost.minX", button)
        self.assertIn("opensUpward: true", button)
        self.assertIn("Color.clear.allowsHitTesting(false)", button)
        overlay = screen.split(".overlay {", 1)[1].split(".onPreferenceChange(DYTopChromeFrameKey", 1)[0]
        self.assertIn("layoutAModuleAnchor.active", overlay)
        self.assertIn("rootActionRail(nil, selector: true)", overlay)
        self.assertLess(overlay.index("layoutAModuleButton"), overlay.index("rootActionRail(nil, selector: true)"))
        self.assertNotIn("ready", toggle)
        self.assertIn("DYLiveLayoutToggle.returnTopInset", room.split("private struct DYLiveRoomPage", 1)[1])
        self.assertIn('accessibilityIdentifier("live.room.more")', room)
        self.assertIn("live.room.close", room)
        self.assertIn('accessibilityIdentifier("live.chat.input")', room)

    def test_engine_stays_independent_of_playback(self):
        source = SOURCE.read_text()
        self.assertIn("import CoreGraphics", source)
        self.assertNotIn("import SwiftUI", source)
        self.assertNotIn("import VLCKitSPM", source)
        self.assertNotIn("VLCMediaPlayer", source)
        self.assertNotIn("DYLiveFeed", source)
        self.assertNotIn("URLSession", source)


if __name__ == "__main__":
    unittest.main()
