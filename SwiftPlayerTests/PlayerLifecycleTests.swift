import XCTest
import AVFoundation
import AppKit
import Combine
@testable import SwiftPlayer

@MainActor
final class PlayerLifecycleTests: XCTestCase {
    private var source: URL!

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960_000))
        buffer.frameLength = 960_000
        memset(try XCTUnwrap(buffer.floatChannelData?[0]), 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        source = nil
    }

    private func loadedPlayer() async throws -> PlayerModel {
        let model = PlayerModel()
        model.load(url: source)
        try await waitUntil { model.isPlaying && model.duration > 0 || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
        return model
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "PlayerLifecycleTestTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testChangingSpeedWhilePausedDoesNotResumePlayback() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.playbackRate = 2
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.playbackRequested)
        model.play()
        try await waitUntil { model.isPlaying }
        XCTAssertEqual(model.player.rate, 2)
        for invalid: Float in [.nan, .infinity, 0, -1, 100] {
            model.playbackRate = invalid
            XCTAssertEqual(model.playbackRate, 2)
        }
    }

    func testNativePlayerControlsUpdatePlaybackIntentAndSelectedRate() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.player.pause()
        try await waitUntil { !model.isPlaying }
        XCTAssertFalse(model.playbackRequested, "Native playback controls must update the shared play/pause intent.")
        model.playbackRate = 1.5
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.player.rate, 0, "Changing speed after a native pause must preserve pause.")
        model.player.rate = 2
        try await waitUntil { model.isPlaying }
        XCTAssertTrue(model.playbackRequested)
        XCTAssertEqual(model.playbackRate, 2)
        model.togglePlayPause()
        XCTAssertEqual(model.player.rate, 0)
        model.player.play()
        try await waitUntil { model.isPlaying }
        XCTAssertTrue(model.playbackRequested)
    }

    func testVolumeClampsInvalidValuesAndUnmutesOnIncrease() {
        let model = PlayerModel()
        model.volume = -1
        XCTAssertEqual(model.volume, 0)
        XCTAssertEqual(model.player.volume, 0)
        model.volume = 10
        XCTAssertEqual(model.volume, 1)
        model.volume = .nan
        XCTAssertEqual(model.volume, 1)
        model.volume = .infinity
        XCTAssertEqual(model.volume, 1)
        model.isMuted = true
        model.volumeDown()
        XCTAssertFalse(model.isMuted)
        XCTAssertFalse(model.player.isMuted)
        XCTAssertEqual(model.player.volume, 0.95, accuracy: 0.001)
    }

    func testInvalidVolumeChangesPreserveMuteAndTheLastValidVolume() {
        let model = PlayerModel()
        for volume: Float in [0.25, 0.5, 1] {
            for invalid: Float in [.nan, .infinity, -.infinity] {
                model.volume = volume
                model.isMuted = true
                model.volume = invalid
                XCTAssertEqual(model.volume, volume)
                XCTAssertEqual(model.player.volume, volume)
                XCTAssertTrue(model.isMuted)
                XCTAssertTrue(model.player.isMuted)
            }
        }
    }

    func testPausingDuringLoadingPreventsAutoplay() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        model.load(url: source)
        model.pause()
        model.playbackRate = 1.5
        try await waitUntil { !model.isLoading }
        XCTAssertEqual(model.player.currentItem?.status, .readyToPlay)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertFalse(model.playbackRequested)
        model.togglePlayPause()
        try await waitUntil { model.isPlaying }
        XCTAssertEqual(model.player.rate, 1.5)
    }

    func testPausedFastSeekingStaysPaused() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.beginFastSeeking(direction: 1)
        try await waitUntil { model.isFastSeeking }
        XCTAssertFalse(model.playbackRequested)
        XCTAssertEqual(model.player.rate, 0)
        model.endFastSeeking()
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testReverseScrubRestoresPriorPlayback() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.beginFastSeeking(direction: -1)
        try await waitUntil { model.isFastSeeking }
        XCTAssertTrue(model.playbackRequested)
        XCTAssertEqual(model.player.rate, 0)
        model.endFastSeeking()
        try await waitUntil { model.isPlaying }
        XCTAssertEqual(model.player.rate, model.playbackRate)
    }

    func testPlayCancelsAnActivePausedReverseHold() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.beginFastSeeking(direction: -1)
        try await waitUntil { model.isFastSeeking }
        model.togglePlayPause()
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertTrue(model.playbackRequested)
        try await waitUntil { model.isPlaying }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(model.player.currentTime().seconds, 0.1)
    }

    func testReleasingKeyBeforeHoldDoesNotStartFastSeeking() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.beginFastSeeking(direction: 1)
        model.endFastSeeking()
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertEqual(model.player.rate, model.playbackRate)
    }

    func testReverseHoldAtStartDoesNotKeepSeekingTheSameFrame() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.seek(to: 0)
        model.beginFastSeeking(direction: -1)
        try await waitUntil { model.isFastSeeking }
        try await Task.sleep(for: .milliseconds(250))
        var changes = 0
        let observer = model.$currentTime.dropFirst().sink { _ in changes += 1 }
        defer { observer.cancel() }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.01)
        XCTAssertEqual(changes, 0, "A held reverse key must stop decoding the same start frame repeatedly.")
    }

    func testHeldKeyDoesNotRetainModelAfterClose() async throws {
        var model: PlayerModel? = try await loadedPlayer()
        let player = try XCTUnwrap(model).player
        let released = { [weak model] in model == nil }
        model?.beginFastSeeking(direction: -1)
        try await waitUntil { model?.isFastSeeking == true }
        model = nil
        try await waitUntil(released)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
    }

    func testRapidSeeksUseLatestTargetAndClampInvalidValues() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.seek(to: -100)
        XCTAssertEqual(model.currentTime, 0)
        model.seek(to: model.duration + 100)
        XCTAssertEqual(model.currentTime, model.duration)
        model.seek(to: .nan)
        model.seek(to: .infinity)
        XCTAssertEqual(model.currentTime, model.duration)
        for time in [2.0, 7.0, 1.0, 9.0, 3.0] { model.seek(to: time) }
        try await waitUntil { abs(model.player.currentTime().seconds - 3) < 0.1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.currentTime, 3, accuracy: 0.1)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testReplacementIgnoresPendingSeekAndOldNotifications() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        let oldItem = try XCTUnwrap(model.player.currentItem)
        model.seek(to: 17)
        model.load(url: source)
        try await waitUntil { model.isPlaying && model.duration > 0 || model.playbackFailed }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: "OldItem", code: 1)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.playbackFailed)
        XCTAssertFalse(model.playbackFinished)
        XCTAssertLessThan(model.currentTime, 3)
    }

    func testQueuedEndNotificationDoesNotOverrideANewerSeek() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        let item = try XCTUnwrap(model.player.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        model.seek(to: 3)
        model.play()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.playbackFinished)
        XCTAssertTrue(model.playbackRequested)
        XCTAssertLessThan(model.currentTime, 5)
    }

    func testNaturalEndStopsPlaybackAndPlayRestartsFromBeginning() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.seek(to: model.duration - 0.2)
        try await waitUntil { model.playbackFinished }
        XCTAssertFalse(model.playbackRequested)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentTime, model.duration, accuracy: 0.1)
        model.play()
        try await waitUntil { model.isPlaying && model.player.currentTime().seconds < 2 }
        XCTAssertFalse(model.playbackFinished)
        XCTAssertTrue(model.playbackRequested)
    }

    func testTeardownReleasesStateAndCancelsSubtitles() async throws {
        let model = try await loadedPlayer()
        let subtitles = source.deletingPathExtension().appendingPathExtension("srt")
        defer { try? FileManager.default.removeItem(at: subtitles) }
        try "1\n00:00:01,000 --> 00:00:02,000\nCaption".write(to: subtitles, atomically: true, encoding: .utf8)
        model.subtitleCues = [SubtitleCue(start: 0, end: 20, text: "Old caption")]
        model.subtitlesEnabled = true
        model.isScrubbing = true
        model.beginFastSeeking(direction: 1)
        model.loadSubtitles(url: subtitles)
        model.teardown()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.player.currentItem)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isScrubbing)
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertTrue(model.subtitleCues.isEmpty)
        XCTAssertFalse(model.subtitlesEnabled)
        XCTAssertEqual(model.currentSubtitleText, "")
        XCTAssertEqual(model.currentTime, 0)
        XCTAssertEqual(model.duration, 0)
    }

    func testSubtitleLookupHandlesOffsetsOverlapsAndBackwardSeeks() {
        let model = PlayerModel()
        model.subtitleCues = [SubtitleCue(start: 10, end: 12, text: "Later"),
                              SubtitleCue(start: 2, end: 3, text: "Overlap"),
                              SubtitleCue(start: 0, end: 8, text: "Earlier")]
        model.currentTime = 2.5
        model.subtitlesEnabled = true
        XCTAssertEqual(model.currentSubtitleText, "Earlier")
        model.currentTime = 10.5
        model.updateSubtitleDisplay()
        XCTAssertEqual(model.currentSubtitleText, "Later")
        model.subtitleOffset = 2
        XCTAssertEqual(model.currentSubtitleText, "")
        model.currentTime = 4
        model.updateSubtitleDisplay()
        XCTAssertEqual(model.currentSubtitleText, "Earlier")
        model.subtitlesEnabled = false
        XCTAssertEqual(model.currentSubtitleText, "")
    }

    func testInactiveSubtitlesDoNotPublishUnchangedTextEveryTick() {
        let model = PlayerModel()
        var changes: [String] = []
        let observer = model.$currentSubtitleText.dropFirst().sink { changes.append($0) }
        defer { observer.cancel() }
        for _ in 0..<100 { model.updateSubtitleDisplay() }
        XCTAssertTrue(changes.isEmpty)
        model.subtitleCues = [SubtitleCue(start: 0, end: 20, text: "Caption")]
        model.subtitlesEnabled = true
        XCTAssertEqual(changes, ["Caption"])
        model.subtitlesEnabled = false
        for _ in 0..<100 { model.updateSubtitleDisplay() }
        XCTAssertEqual(changes, ["Caption", ""])
        model.subtitlesEnabled = true
        model.subtitleCues = []
        for _ in 0..<100 { model.updateSubtitleDisplay() }
        XCTAssertEqual(changes, ["Caption", "", "Caption", ""])
    }

    func testCaptionTransitionsExcludeThePreviousCueEndTime() {
        let model = PlayerModel()
        model.subtitleCues = [SubtitleCue(start: 0, end: 1, text: "First"),
                              SubtitleCue(start: 1, end: 2, text: "Second")]
        model.subtitlesEnabled = true
        model.currentTime = 1
        model.updateSubtitleDisplay()
        XCTAssertEqual(model.currentSubtitleText, "Second")
        model.currentTime = 2
        model.updateSubtitleDisplay()
        XCTAssertEqual(model.currentSubtitleText, "")
        model.currentTime = 0.5
        model.updateSubtitleDisplay()
        XCTAssertEqual(model.currentSubtitleText, "First")
    }

    func testLoadingNewMediaClearsOldSubtitlesAndErrors() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        model.load(url: source.appendingPathExtension("missing.mp4"))
        try await waitUntil { model.playbackFailed }
        model.subtitleCues = [SubtitleCue(start: 0, end: 10, text: "Previous")]
        model.subtitlesEnabled = true
        model.load(url: source)
        try await waitUntil { model.isPlaying || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
        XCTAssertEqual(model.playbackErrorMessage, "")
        XCTAssertTrue(model.subtitleCues.isEmpty)
        XCTAssertEqual(model.currentSubtitleText, "")
    }

    func testVideoViewDismantlingReleasesPlayerAndCallback() {
        var model: PlayerModel? = PlayerModel()
        let released = { [weak model] in model == nil }
        let view = PlayerLayerNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        view.playerLayer.player = model?.player
        view.onLayerReady = { [retainedModel = model] _ in _ = retainedModel?.player }
        model = nil
        XCTAssertFalse(released())
        PlayerLayerView.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.playerLayer.player)
        XCTAssertNil(view.onLayerReady)
        XCTAssertTrue(released())
    }

    func testKeyboardDismantlingReleasesHandlersAndStopsSeeking() {
        let view = KeyEventHandlingView.KeyCatcherView()
        var releases = 0
        view.onArrowUp = { releases += 1 }
        view.onSpace = {}
        KeyEventHandlingView.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(releases, 1)
        XCTAssertNil(view.onArrowUp)
        XCTAssertNil(view.onSpace)
    }

    func testPiPDetachClearsAvailability() {
        let pip = PiPController()
        pip.isActive = true
        pip.isPossible = true
        pip.detach()
        XCTAssertFalse(pip.isActive)
        XCTAssertFalse(pip.isPossible)
    }

    func testForwardHoldRestoresSelectedRateAndPauseCancelsIt() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.playbackRate = 1.5
        model.beginFastSeeking(direction: 1)
        try await waitUntil { model.isFastSeeking }
        XCTAssertEqual(model.player.rate, 6)
        model.endFastSeeking()
        XCTAssertEqual(model.player.rate, 1.5)
        model.beginFastSeeking(direction: 1)
        try await waitUntil { model.isFastSeeking }
        model.pause()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertFalse(model.playbackRequested)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testChangingHoldDirectionCancelsPreviousLoop() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.seek(to: 10)
        try await waitUntil { abs(model.player.currentTime().seconds - 10) < 0.1 }
        model.beginFastSeeking(direction: -1)
        try await waitUntil { model.isFastSeeking }
        model.beginFastSeeking(direction: 1)
        XCTAssertFalse(model.isFastSeeking)
        try await waitUntil { model.isFastSeeking }
        let time = model.currentTime
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertGreaterThan(model.currentTime, time)
        model.endFastSeeking()
        XCTAssertEqual(model.player.rate, 0)
    }

    func testForwardHoldAtEndDoesNotRepeatSeeks() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.seek(to: model.duration)
        model.beginFastSeeking(direction: 1)
        try await waitUntil { model.isFastSeeking }
        try await Task.sleep(for: .milliseconds(250))
        var changes = 0
        let observer = model.$currentTime.dropFirst().sink { _ in changes += 1 }
        defer { observer.cancel() }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(model.currentTime, model.duration, accuracy: 0.01)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testUnloadedAndInvalidInputsDoNotStartPlaybackOrSeeking() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        model.play()
        model.seek(to: 5)
        model.beginFastSeeking(direction: 1)
        XCTAssertFalse(model.playbackRequested)
        XCTAssertNil(model.player.currentItem)
        model.load(url: source)
        try await waitUntil { model.isPlaying }
        model.pause()
        model.seek(to: 3)
        try await waitUntil { abs(model.player.currentTime().seconds - 3) < 0.1 }
        for direction in [Int.min, -2, 0, 2, Int.max] { model.beginFastSeeking(direction: direction) }
        for time in [Double.nan, .infinity, -.infinity] { model.seek(to: time) }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertEqual(model.currentTime, 3, accuracy: 0.1)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testReplacingMediaDuringHoldCancelsPreviousSeeking() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        model.pause()
        model.seek(to: 12)
        model.beginFastSeeking(direction: -1)
        try await waitUntil { model.isFastSeeking }
        model.load(url: source)
        try await waitUntil { model.isPlaying && model.duration > 0 }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertTrue(model.playbackRequested)
        XCTAssertLessThan(model.currentTime, 3)
        XCTAssertEqual(model.player.rate, model.playbackRate)
    }

    func testTwentyLoadCloseCyclesReleaseEachModelAndItem() async throws {
        for _ in 0..<20 {
            var model: PlayerModel? = PlayerModel()
            let released = { [weak model] in model == nil }
            model?.load(url: source)
            try await waitUntil { model?.player.currentItem?.status == .readyToPlay }
            let player = try XCTUnwrap(model).player
            weak var item = player.currentItem
            model?.seek(to: 8)
            model?.teardown()
            model = nil
            try await waitUntil { released() && item == nil }
            XCTAssertNil(player.currentItem)
            XCTAssertEqual(player.rate, 0)
        }
    }

    func testTenFailedLoadsRecoverWithoutStaleErrors() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        for _ in 0..<10 {
            model.load(url: source.appendingPathExtension("missing.mp4"))
            try await waitUntil { model.playbackFailed }
            XCTAssertNil(model.player.currentItem)
            XCTAssertFalse(model.isLoading)
            model.load(url: source)
            try await waitUntil { model.isPlaying || model.playbackFailed }
            XCTAssertFalse(model.playbackFailed)
            XCTAssertTrue(model.playbackErrorMessage.isEmpty)
        }
    }

    func testEndNotificationFromBackgroundQueueIsHandledOnMain() async throws {
        let model = try await loadedPlayer()
        defer { model.teardown() }
        let item = try XCTUnwrap(model.player.currentItem)
        await Task.detached {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        }.value
        XCTAssertTrue(model.playbackFinished)
        XCTAssertFalse(model.playbackRequested)
    }

    func testLatestSubtitleLoadWinsAndOldCuesAreReleased() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        let first = source.deletingPathExtension().appendingPathExtension("srt")
        let second = source.deletingPathExtension().appendingPathExtension("vtt")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try String(repeating: "1\n00:00:00,000 --> 00:00:02,000\nPrevious\n\n", count: 10_000)
            .write(to: first, atomically: true, encoding: .utf8)
        try "WEBVTT\n\n00:00.000 --> 00:02.000\nLatest".write(to: second, atomically: true, encoding: .utf8)
        model.loadSubtitles(url: first)
        await Task.yield()
        model.loadSubtitles(url: second)
        try await waitUntil { model.currentSubtitleText == "Latest" }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.subtitleCues.count, 1)
        XCTAssertEqual(model.currentSubtitleText, "Latest")
        model.teardown()
        XCTAssertTrue(model.subtitleCues.isEmpty)
    }

    func testLargeSubtitleIndexMatchesLinearLookupAfterBackwardSeeks() {
        let model = PlayerModel()
        let cues = (0..<10_000).map { index in
            SubtitleCue(start: Double(index), end: Double(index) + (index % 11 == 0 ? 20 : 0.5), text: "Cue \(index)")
        }
        model.subtitleCues = cues.reversed()
        model.subtitlesEnabled = true
        for time in [9_999.25, 5_000.75, 2.25, 999.5, 0, 10_030, 100.2] {
            model.currentTime = time
            model.updateSubtitleDisplay()
            XCTAssertEqual(model.currentSubtitleText, cues.first { $0.start <= time && $0.end > time }?.text ?? "")
        }
    }

    func testKeyboardRepeatsAndFocusLossDoNotLeaveAnActiveHold() throws {
        let view = KeyEventHandlingView.KeyCatcherView()
        var plays = 0
        var directions: [Int] = []
        var releases = 0
        view.onSpace = { plays += 1 }
        view.onArrowDown = { directions.append($0) }
        view.onArrowUp = { releases += 1 }
        func event(_ code: UInt16, repeated: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code))
        }
        view.keyDown(with: try event(49))
        view.keyDown(with: try event(49, repeated: true))
        XCTAssertEqual(plays, 1)
        view.keyDown(with: try event(123))
        view.keyDown(with: try event(124))
        XCTAssertEqual(directions, [-1, 1])
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(releases, 1)
        KeyEventHandlingView.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(releases, 2)
        XCTAssertNil(view.onArrowDown)
    }

    func testVideoLayerResizesWithoutRepeatingReadyCallback() {
        let view = PlayerLayerNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        var callbacks = 0
        view.onLayerReady = { _ in callbacks += 1 }
        view.layout()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.layout()
        XCTAssertEqual(view.playerLayer.frame, view.bounds)
        XCTAssertEqual(callbacks, 1)
        PlayerLayerView.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.onLayerReady)
    }
}
