#!/usr/bin/env python3
"""Compile the live playback gate and check foreground, room, and callback decisions.

Run: python3 scripts/test_live_playback_gate.py -v
No network, simulator, or player. The Swift is the app source between the gate markers.
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
START = "// MARK: - live-playback-gate\n"
END = "// MARK: - live-playback-gate-end\n"


def gate_source() -> str:
    start = SOURCE.index(START)
    end = SOURCE.index(END, start)
    return SOURCE[start:end]


HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

check(DYLivePlaybackGate.sceneCommand(.inactive) == .none, "inactive must not pause or resume")
        check(DYLivePlaybackGate.sceneCommand(.background) == .pause, "background pauses once")
        check(DYLivePlaybackGate.sceneCommand(.active) == .resume, "active resumes once")

        var active = true
        let foregroundReturn: [DYLiveSceneSignal] = [.inactive, .active, .inactive, .active]
        var runs: [String] = []
        for signal in [DYLiveSceneSignal.inactive, .background, .inactive] + foregroundReturn {
            let command = DYLivePlaybackGate.sceneCommand(signal)
            if DYLivePlaybackGate.apply(appIsActive: active, command: command) {
                runs.append(command == .pause ? "pause" : "resume")
                active = command == .resume
            }
        }
        check(runs == ["pause", "resume"], "background then foreground runs one pause and one resume")
        check(active, "app is active after returning")
        check(!DYLivePlaybackGate.apply(appIsActive: true, command: .resume), "second resume is a no-op")
        check(!DYLivePlaybackGate.apply(appIsActive: false, command: .pause), "second pause is a no-op")

        check(DYLivePlaybackGate.mask(isCurrent: true, ready: true, failed: false) == .showVideo, "current ready room shows the shared player")
        check(DYLivePlaybackGate.mask(isCurrent: true, ready: false, failed: false) == .coverPrevious, "current loading room covers the previous frame")
        check(DYLivePlaybackGate.mask(isCurrent: false, ready: true, failed: false) == .coverPrevious, "the other page covers the shared player while swiping")
        check(DYLivePlaybackGate.mask(isCurrent: true, ready: true, failed: true) == .coverPrevious, "a failed room does not keep the last frame behind the error")

        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .paused, backgroundDuration: 1, lastAdvanceAge: 0.2) == .reconnect, "a paused buffer is not resumed")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 1, lastAdvanceAge: 0.2) == .continueExisting, "a fresh playing session is reused")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing) == .reconnect, "playing without a fresh callback does not prove continuity")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .stopped, backgroundDuration: 1, lastAdvanceAge: 0.2) == .reconnect, "stopped stream reconnects once")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .failed, backgroundDuration: 1, lastAdvanceAge: 0.2, inputAdvanced: true) == .reconnect, "failed stream reconnects once")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: false, hasMedia: true, state: .playing, backgroundDuration: 1, lastAdvanceAge: 0.2, inputAdvanced: true) == .reconnect, "a different room does not continue")
        check(DYLivePlaybackGate.resume(suspended: false, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 1, lastAdvanceAge: 0.2) == .ignore, "a duplicate foreground does nothing")
        check(DYLivePlaybackGate.resume(suspended: true, visible: false, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 1, lastAdvanceAge: 0.2) == .ignore, "a hidden live tab does not resume")

        check(DYLivePlaybackGate.continuityWindow == 3, "callback freshness stays within a few seconds")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 1, lastAdvanceAge: 0.4, inputAdvanced: false) == .continueExisting, "background sound on reuses a stream whose player thread is still ticking")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 8, lastAdvanceAge: 0.4, inputAdvanced: false) == .continueExisting, "a stuck readBytes counter does not veto audible playback")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 8, lastAdvanceAge: 0.4, inputAdvanced: true) == .continueExisting, "new input and a fresh callback keep the same session")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 15, lastAdvanceAge: 12, inputAdvanced: true) == .reconnect, "bytes that moved earlier still go stale when callbacks stop")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 300, lastAdvanceAge: 0.5, inputAdvanced: true) == .continueExisting, "five minutes can reuse a session whose callbacks never stopped")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .paused, backgroundDuration: 15, lastAdvanceAge: 12, inputAdvanced: false) == .reconnect, "background sound off reconnects after the player thread stops")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .buffering, backgroundDuration: 1, lastAdvanceAge: 0.2, inputAdvanced: true) == .continueExisting, "a foreground return can be buffering while the same session is alive")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .buffering, backgroundDuration: 15, lastAdvanceAge: 12) == .reconnect, "stale buffering is reconnected")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .opening, backgroundDuration: 1, lastAdvanceAge: 0.2) == .reconnect, "an opening session is reconnected")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 1, lastAdvanceAge: 0.2, inputAdvanced: true, interrupted: true) == .reconnect, "an interruption discards the old buffer")
        check(DYLivePlaybackGate.resume(suspended: false, visible: true, sameRoom: true, hasMedia: true, state: .playing, lastAdvanceAge: 0.2, interrupted: true) == .reconnect, "a foreground interruption uses the same recovery")
        check(DYLivePlaybackGate.resume(suspended: false, visible: true, sameRoom: true, hasMedia: true, state: .paused, backgroundDuration: 300) == .ignore, "a duplicate foreground event does not reconnect again")

        let continued = DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 20, lastAdvanceAge: 0.3, inputAdvanced: true)
        check(continued == .continueExisting, "background sound does not choose a second recovery path")
        check(DYLivePlaybackGate.backgroundOutputMuted(userMuted: false, backgroundSound: true) == false, "background sound on keeps live audio audible")
        check(DYLivePlaybackGate.backgroundOutputMuted(userMuted: false, backgroundSound: false) == true, "background sound off mutes without a second player")
        check(DYLivePlaybackGate.backgroundOutputMuted(userMuted: true, backgroundSound: true) == true, "room mute still wins while background sound is on")
        check(DYLivePlaybackGate.foregroundOutputMuted(userMuted: false) == false, "foreground restores an unmuted room")
        check(DYLivePlaybackGate.foregroundOutputMuted(userMuted: true) == true, "foreground restores a muted room")
        check(DYLivePlaybackGate.retainsAudioSession(visible: true, hasMedia: true, userMuted: false, backgroundSound: true, interrupted: false), "audible live playback may keep the audio session")
        check(!DYLivePlaybackGate.retainsAudioSession(visible: true, hasMedia: true, userMuted: false, backgroundSound: false, interrupted: false), "muted background playback does not hold the audio session")
        check(!DYLivePlaybackGate.retainsAudioSession(visible: true, hasMedia: true, userMuted: true, backgroundSound: true, interrupted: false), "a muted room does not use silent playback as a keepalive")
        check(!DYLivePlaybackGate.retainsAudioSession(visible: true, hasMedia: true, userMuted: false, backgroundSound: true, interrupted: true), "an interruption releases the audio session")
        check(!DYLivePlaybackGate.retainsAudioSession(visible: false, hasMedia: true, userMuted: false, backgroundSound: true, interrupted: false), "a hidden live tab does not keep the audio session")
        check(DYLiveBackgroundSound.storageKey == "douyin_live_background_sound_v1", "background sound has its own preference key")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 2, lastAdvanceAge: 3, inputAdvanced: false) == .continueExisting, "a callback at the freshness window is still current")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 2.1, lastAdvanceAge: 0.2, inputAdvanced: false) == .continueExisting, "fresh callbacks are reused without requiring readBytes")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 1, lastAdvanceAge: 3.1, inputAdvanced: true) == .reconnect, "a callback older than the window is stale")
        let reuse = DYLivePlaybackGate.recovery(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, backgroundDuration: 20, lastAdvanceAge: 0.2, inputAdvanced: false, interrupted: false)
        check(reuse.action == .continueExisting && reuse.reason == "callbacks-fresh", "continuous playback is an explicit reuse")
        let forced = DYLivePlaybackGate.recovery(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .playing, lastAdvanceAge: 0.2, interrupted: true)
        check(forced.action == .reconnect && forced.reason == "interrupted", "an interruption forces reconnect")
        check(DYLivePlaybackGate.mediaReplacement(state: .playing, stopInFlight: false) == .waitUntilStopped, "an active stream waits until stop finishes")
        check(DYLivePlaybackGate.mediaReplacement(state: .stopped, stopInFlight: false) == .assignNow, "a stopped player can take new media immediately")
        check(DYLivePlaybackGate.mediaReplacement(state: .failed, stopInFlight: false) == .assignNow, "a failed player can take new media immediately")
        check(DYLivePlaybackGate.mediaReplacement(state: .stopped, stopInFlight: true) == .waitUntilStopped, "a stopped reading does not prove the in-flight stop has returned")
        check(DYLivePlaybackGate.mediaReplacement(state: .failed, stopInFlight: true) == .waitUntilStopped, "a failed reading still waits while stop is in flight")
        check(DYLivePlaybackGate.mediaReplacement(state: .empty, stopInFlight: true) == .waitUntilStopped, "an empty player waits while stop is in flight")
        check(DYLivePlaybackGate.mediaReplacement(state: .playing, stopInFlight: true) == .waitUntilStopped, "a second replace waits while the current stream is still playing")
        check(DYLivePlaybackGate.acceptsLateReplay(replayToken: 1, currentToken: 3, kind: .stopped) == false, "room A cannot replay after room C")
        check(DYLivePlaybackGate.acceptsLateReplay(replayToken: 2, currentToken: 2, kind: .stopped), "the current replacement may recover one late stop")
        check(DYLivePlaybackGate.acceptsLateReplay(replayToken: 2, currentToken: 2, kind: .error), "the current replacement may recover one late error")
        check(DYLivePlaybackGate.acceptsLateReplay(replayToken: 2, currentToken: 2, kind: .ended) == false, "ended media is not restarted as a live replay")
        check(DYLivePlaybackGate.acceptsLateReplay(replayToken: nil, currentToken: 2, kind: .stopped) == false, "a direct play has no stale replay")
        check(DYLivePlaybackGate.acceptsLateReplay(replayToken: 4, currentToken: 5, kind: .error) == false, "a quality change or manual reconnect cancels the previous replay")
        check(DYLivePlaybackGate.surfaceMayStart(stopInFlight: true, ownedStartPending: false, waitingForSurface: true, playingIntent: true, state: .stopped) == false, "attaching the surface during stop does not play")
        check(DYLivePlaybackGate.surfaceMayStart(stopInFlight: false, ownedStartPending: true, waitingForSurface: false, playingIntent: true, state: .stopped) == false, "attaching the surface does not race an owned start")
        check(DYLivePlaybackGate.surfaceMayStart(stopInFlight: false, ownedStartPending: false, waitingForSurface: true, playingIntent: true, state: .stopped), "the first surface still starts playback")
        check(DYLivePlaybackGate.surfaceMayStart(stopInFlight: false, ownedStartPending: false, waitingForSurface: false, playingIntent: true, state: .paused), "a visible reattach can resume a paused picture")
        check(DYLivePlaybackGate.surfaceMayStart(stopInFlight: false, ownedStartPending: false, waitingForSurface: false, playingIntent: true, state: .opening) == false, "an opening stream is not restarted by a surface attach")
        check(DYLivePlaybackGate.stopsMediaOnBackground(backgroundSound: false), "background sound off stops live media")
        check(DYLivePlaybackGate.stopsMediaOnBackground(backgroundSound: true) == false, "background sound on does not force a stop")
        check(DYLivePlaybackGate.silenceResume(visible: true, hasRoom: true, coverHold: false, pending: true) == DYLivePlaybackGate.DYLiveSilenceResume.reconnect, "off foreground reconnects the same room once")
        check(DYLivePlaybackGate.silenceResume(visible: true, hasRoom: true, coverHold: false, pending: false) == DYLivePlaybackGate.DYLiveSilenceResume.ignore, "a repeated foreground callback does not reconnect again")
        check(DYLivePlaybackGate.silenceResume(visible: false, hasRoom: true, coverHold: false, pending: true) == DYLivePlaybackGate.DYLiveSilenceResume.ignore, "leaving the room does not resurrect it")
        check(DYLivePlaybackGate.silenceResume(visible: true, hasRoom: false, coverHold: false, pending: true) == DYLivePlaybackGate.DYLiveSilenceResume.ignore, "no room means there is nothing to reconnect")
        check(DYLivePlaybackGate.silenceResume(visible: true, hasRoom: true, coverHold: true, pending: true) == DYLivePlaybackGate.DYLiveSilenceResume.ignore, "an overlay keeps playback paused")
        check(DYLivePlaybackGate.foregroundOutputMuted(userMuted: true), "mute intent survives a silence reconnect")
        check(DYLivePlaybackGate.sceneCommand(.inactive) == .none, "inactive still does not stop or resume")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: true, interrupted: true, action: .reconnect, coverHold: false, visible: true, hasRoom: true), "one confirmed interruption reconnect replaces the unusable player")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: true, interrupted: false, action: .reconnect, coverHold: false, visible: true, hasRoom: true) == false, "a second callback after the interruption flag is cleared does not rebuild again")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: true, interrupted: false, action: .continueExisting, coverHold: false, visible: true, hasRoom: true) == false, "healthy on reuse does not rebuild the player")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: false, interrupted: true, action: .reconnect, coverHold: false, visible: true, hasRoom: true), "a foreground interruption rebuilds when background sound is off")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: false, interrupted: false, action: .reconnect, coverHold: false, visible: true, hasRoom: true) == false, "returning from background without an interruption does not rebuild")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: true, interrupted: true, action: .reconnect, coverHold: true, visible: true, hasRoom: true) == false, "an overlay blocks player reconstruction")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: true, interrupted: true, action: .reconnect, coverHold: false, visible: false, hasRoom: true) == false, "an exited room is not rebuilt")
        check(DYLivePlaybackGate.shouldRebuildPlayer(backgroundSound: true, interrupted: true, action: .ignore, coverHold: false, visible: true, hasRoom: true) == false, "an ignored lifecycle event does not rebuild")
        check(DYLivePlaybackGate.foregroundOutputMuted(userMuted: true), "user mute is unchanged by a player rebuild")
        check(DYLivePlaybackGate.shouldRestartSameRoom(state: .playing, ready: true, hasMedia: true) == false, "a playing room is not replaced again")
        check(DYLivePlaybackGate.shouldRestartSameRoom(state: .failed, ready: false, hasMedia: true) == true, "a failed room can be selected again")
        check(DYLivePlaybackGate.shouldRestartSameRoom(state: .stopped, ready: false, hasMedia: true) == true, "a stopped room can be selected again")
        check(DYLivePlaybackGate.canShowExistingPicture(state: .playing, hasVideoOut: true), "an existing picture leaves the loading state")
        check(DYLivePlaybackGate.canShowExistingPicture(state: .playing, hasVideoOut: false) == false, "audio without a picture stays loading")
        let audible = DYLivePlaybackGate.foregroundAudio(userMuted: false, sessionReleased: true)
        check(audible.muted == false && audible.reopenTrack, "background mute is undone by reopening the audio track")
        let kept = DYLivePlaybackGate.foregroundAudio(userMuted: false, sessionReleased: false)
        check(kept.muted == false && kept.reopenTrack == false, "a session that stayed active does not restart the audio track")
        let userMuted = DYLivePlaybackGate.foregroundAudio(userMuted: true, sessionReleased: true)
        check(userMuted.muted && userMuted.reopenTrack == false, "an intentional room mute stays muted")
        check(DYLivePlaybackGate.shouldForceAssign(stopInFlight: true, hasPending: true, waited: 2), "a missing stop completion can assign the pending media once")
        check(DYLivePlaybackGate.shouldForceAssign(stopInFlight: true, hasPending: true, waited: 1) == false, "a stop that is still within the limit is not forced")
        check(DYLivePlaybackGate.shouldForceAssign(stopInFlight: false, hasPending: true, waited: 2) == false, "a finished stop is not assigned again")
        check(DYLivePlaybackGate.shouldForceAssign(stopInFlight: true, hasPending: false, waited: 2) == false, "a stop with no pending room does not start playback")
        check(DYLivePlaybackGate.acceptsRoomChange(playbackRegisteredActive: false, applicationActive: true, visible: true), "a stale background latch does not block a room change")
        check(DYLivePlaybackGate.acceptsRoomChange(playbackRegisteredActive: false, applicationActive: false, visible: true) == false, "a real background does not start another room")
        check(DYLivePlaybackGate.shouldRestartSameRoom(state: .paused, ready: true, hasMedia: true), "a paused room can be retried")
        check(DYLivePlaybackGate.resume(suspended: false, visible: true, sameRoom: true, hasMedia: true, state: .playing, lastAdvanceAge: 0.2) == .ignore, "a duplicate foreground callback does not recover twice")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: false, state: .playing, backgroundDuration: 1, lastAdvanceAge: 0.2, inputAdvanced: true) == .reconnect, "a player without media reconnects")
        check(DYLivePlaybackGate.resume(suspended: true, visible: true, sameRoom: true, hasMedia: true, state: .empty, backgroundDuration: 1, lastAdvanceAge: 0.2) == .reconnect, "an empty player reconnects")

        let recovery = UUID()
        let superseded = UUID()
        check(!DYLivePlaybackGate.acceptEvent(currentGeneration: superseded, eventGeneration: recovery, ownerRoomID: "room", eventRoomID: "room"), "a callback from the pre-recovery session is dropped")
        check(!DYLivePlaybackGate.acceptEvent(currentGeneration: superseded, eventGeneration: superseded, ownerRoomID: "next", eventRoomID: "room"), "switching rooms during recovery drops the old room")

        let generation = UUID()
        check(DYLivePlaybackGate.acceptEvent(currentGeneration: generation, eventGeneration: generation, ownerRoomID: "B", eventRoomID: "B"), "current room accepts its own event")
        check(!DYLivePlaybackGate.acceptEvent(currentGeneration: generation, eventGeneration: UUID(), ownerRoomID: "B", eventRoomID: "B"), "stale generation is dropped")
        check(!DYLivePlaybackGate.acceptEvent(currentGeneration: generation, eventGeneration: generation, ownerRoomID: "B", eventRoomID: "A"), "room A cannot complete room B")
        check(!DYLivePlaybackGate.acceptEvent(currentGeneration: generation, eventGeneration: generation, ownerRoomID: nil, eventRoomID: nil), "a stopped player has no owner")

if failures.isEmpty {
    print("DYLivePlaybackGate passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class LivePlaybackGateTests(unittest.TestCase):
    def test_gate_matches_foreground_and_room_rules(self):
        swift = "import Foundation\n" + gate_source() + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix=".test-live-playback-", dir=ROOT) as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYLivePlaybackGate passed", completed.stdout)

    def test_app_and_page_use_the_gate(self):
        app = (ROOT / "DouDuo/DouDuoApp.swift").read_text()
        page = SOURCE
        player = (ROOT / "DouDuo/ShortVideoPlayer.swift").read_text()
        self.assertIn("DYLivePlaybackGate.sceneCommand", app)
        self.assertNotIn("default: DDPlayback.shared.pauseAll()", app)
        self.assertIn("DYLivePlaybackGate.mask", page)
        self.assertIn("DYLivePlaybackGate.apply", player)
        self.assertIn("DYLivePlaybackGate.recovery", page)
        self.assertIn("static func resume(", page)
        self.assertIn("backgroundDuration:", page)
        self.assertIn("suspendedAt", page)
        self.assertIn("lastAdvanceAge:", page)
        self.assertIn("inputAdvanced:", page)
        self.assertIn("interrupted:", page)
        self.assertIn("后台播放", page)
        self.assertIn("live.room.backgroundSound", page)
        self.assertNotIn("liveEdgeResumeLimit", page)
        resume = page.split("func resumeFromBackground", 1)[1].split("private func playbackState", 1)[0]
        self.assertIn("play(room)", resume)
        self.assertIn("applyForegroundAudio", resume)
        self.assertIn("foregroundAudio", page)
        self.assertNotIn("vlc.current", resume)
        self.assertNotIn("vlc.resume()", resume)
        self.assertNotIn("qualityChoice", resume)
        self.assertIn("shouldRebuildPlayer", page)
        self.assertIn("rebuildPlayerAfterInterruption()", page)
        silence = page.split("if stoppedForBackground", 1)[1].split("let away", 1)[0]
        self.assertNotIn("rebuildPlayerAfterInterruption", silence)
        suspend = page.split("private func suspendForBackground()", 1)[1].split("private func resumeFromBackground()", 1)[0]
        self.assertNotIn("rebuildPlayerAfterInterruption", suspend)
        self.assertEqual(suspend.count("vlc.pause()"), 1)
        self.assertEqual(suspend.count("vlc.stop()"), 1)
        self.assertIn("stopsMediaOnBackground", suspend)
        self.assertIn("reason == .cover", suspend)
        self.assertIn("reason == .inactive", suspend)
        self.assertIn("backgroundOutputMuted", suspend)
        self.assertIn("statistics.readBytes", page)
        self.assertNotIn("demuxReadBytes", page)
        self.assertIn("vlc.lastAdvanceAge", page)
        self.assertIn("vlc.replace(", page)
        self.assertIn("shouldRestartSameRoom", page)
        self.assertIn("activatePlaybackSession", page)
        bridge = (ROOT / "DouDuo/VLCPlayerBridge.swift").read_text()
        time_changed = bridge.split("func mediaPlayerTimeChanged", 1)[1].split("func mediaPlayerStateChanged", 1)[0]
        self.assertLess(time_changed.find("advanceClock.stamp()"), time_changed.find("Task { @MainActor"))
        self.assertIn("stopInFlight", bridge)
        self.assertIn("finishStopAndReplace", bridge)
        self.assertIn("armStopDeadline", bridge)
        self.assertIn("reopenAudioOutput", bridge)
        self.assertIn("replacementOwner:", bridge)
        self.assertIn("pendingStartEpoch", bridge)
        self.assertIn("acceptsLateReplay", bridge)
        self.assertIn("surfaceMayStart", bridge)
        self.assertIn("func rebuildPlayerAfterInterruption()", bridge)
        self.assertIn("retired.delegate = nil", bridge)
        self.assertIn("activePlayer.accepts", bridge)
        self.assertIn("func installFreshPlayer()", bridge)
        install = bridge.split("func installFreshPlayer()", 1)[1].split("func completeHandoff", 1)[0]
        self.assertNotIn(".stop()", install)
        self.assertIn("retired.drawable = nil", install)
        self.assertIn("player.delegate = self", install)
        self.assertNotIn("player.drawable", install)
        self.assertNotIn("ready?()", install)
        self.assertIn("DispatchQueue.global", install)
        release = install.split("DispatchQueue.global", 1)[1].split("Task { @MainActor in", 1)[0]
        self.assertIn("release.player = nil", release)
        self.assertNotIn("completeHandoff", release)
        handoff = bridge.split("func completeHandoff", 1)[1].split("private static func makePlayer", 1)[0]
        self.assertNotIn(".stop()", handoff)
        self.assertIn("player.drawable = surface", handoff)
        self.assertIn("Task { @MainActor in", handoff)
        self.assertLess(handoff.find("player.drawable = surface"), handoff.find("ready?()"))
        self.assertIn("blocksSurfaceAttachment", bridge)
        surface = bridge.split("struct VLCPlayerSurface", 1)[1].split("final class VLCPlayerUIView", 1)[0]
        self.assertEqual(surface.count("blocksSurfaceAttachment"), 2)
        self.assertIn("if handoffInFlight || interruptionRebuild { return }", bridge)
        self.assertIn("PLAYER-REBUILD-FAILED", bridge)
        self.assertIn("STALE-CALLBACK rejected", bridge)
        self.assertIn("stopCompletionLimit", page)
        self.assertEqual(page.count("VLCPlayerController()"), 1)
        stop = page.split("func stop()", 1)[1].split("func reset()", 1)[0]
        self.assertIn("suspended = false", stop)
        self.assertIn("vlc.stop()", stop)
        self.assertIn("placeholder: { Color.black }", page)
        self.assertIn("sessionRetainers", player)
        self.assertIn("pauseAll(reason:", player)
        background_pause = player.split("func pauseForBackground()", 1)[1].split("func resumeAfterBackground()", 1)[0]
        self.assertIn(".pause()", background_pause)
        self.assertNotIn("setActive(false", background_pause)
        messages = (ROOT / "DouDuo/DouyinMessages.swift").read_text()
        self.assertEqual(messages.count("pauseAll(reason: .cover)"), 2)
        self.assertNotIn("DDPlayback.shared.pauseAll()", messages)
        plist = (ROOT / "DouDuo/Info.plist").read_text()
        self.assertIn("UIBackgroundModes", plist)
        self.assertIn("foregroundOutputMuted(userMuted: muted)", page)
        self.assertIn("stoppedForBackground = false", page)
        resign = app.split("func applicationWillResignActive", 1)[1].split("func applicationDidEnterBackground", 1)[0]
        self.assertIn("pauseForInactivity()", resign)
        self.assertNotIn("pauseAll()", resign)
        self.assertIn("func pauseForInactivity()", player)
        self.assertIn("func releaseCover()", player)
        self.assertIn("coverHold", player)
        self.assertEqual(messages.count("releaseCover()"), 2)
        self.assertIn("<string>audio</string>", plist)
        project = (ROOT / "project.yml").read_text()
        self.assertIn("UIBackgroundModes:", project)
        self.assertIn("UIBackgroundModes: [audio]", project)


if __name__ == "__main__":
    unittest.main()
