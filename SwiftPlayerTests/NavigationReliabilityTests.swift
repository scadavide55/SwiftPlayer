import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class NavigationReliabilityTests: DebugMatrixTestCase {
    private var output: AVPlayerItemVideoOutput?
    private func localPlayer(playing: Bool, preferences: PlayerPreferences? = nil) async throws -> PlayerModel {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_NAVIGATION_MEDIA"] else {
            throw XCTSkip("Provide local long-GOP video to check repeated navigation.")
        }
        let model = PlayerModel(preferences: preferences)
        try await ready(model, url: URL(fileURLWithPath: path))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        self.output = output
        model.player.currentItem?.add(output)
        model.play()
        try await waitUntilCondition {
            output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil) != nil
        }
        model.pause()
        model.seek(to: 750)
        try await waitUntilCondition { !model.isSeeking }
        if playing {
            model.play()
            try await waitUntilCondition { model.player.timeControlStatus == .playing }
        }
        return model
    }

    private func consecutiveJumps(playing: Bool) async throws {
        let model = try await localPlayer(playing: playing)
        defer { model.teardown() }
        for direction in [1, -1, -1, 1] {
            for _ in 0..<10 {
                let expected = model.currentTime + Double(direction) * 5
                let start = model.player.currentTime().seconds
                model.beginFastSeeking(direction: direction)
                model.endFastSeeking()
                try await waitUntilCondition { !model.isSeeking }
                let actual = model.player.currentTime().seconds
                XCTAssertEqual(actual, expected, accuracy: 0.4)
                XCTAssertGreaterThan((actual - start) * Double(direction), 4)
                XCTAssertEqual(model.playbackRequested, playing)
                XCTAssertEqual(model.player.rate, playing ? model.playbackRate : 0)
                var display = CMTime.invalid
                try await waitUntilCondition {
                    self.output?.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: &display) != nil
                }
                XCTAssertEqual(display.seconds, expected, accuracy: 0.5)
            }
        }
    }

    func testConsecutiveLeftAndRightWhilePausedWhenProvided() async throws {
        try await consecutiveJumps(playing: false)
    }

    func testConsecutiveLeftAndRightWhilePlayingWhenProvided() async throws {
        try await consecutiveJumps(playing: true)
    }

    func testRapidConsecutiveTapsAccumulateWhilePlayingAndPausedWhenProvided() async throws {
        for playing in [false, true] {
            let model = try await localPlayer(playing: playing)
            defer { model.teardown() }
            for direction in [1, -1] {
                let expected = model.currentTime + Double(direction) * 50
                for _ in 0..<10 {
                    model.beginFastSeeking(direction: direction)
                    model.endFastSeeking()
                }
                try await waitUntilCondition { !model.isSeeking }
                XCTAssertEqual(model.player.currentTime().seconds, expected, accuracy: 0.4)
                XCTAssertEqual(model.playbackRequested, playing)
            }
        }
    }

    func testNormalConsecutiveTapsAndHoldsWhilePlayingAndPausedWhenProvided() async throws {
        let length = 5.0
        for playing in [false, true] {
            let model = try await localPlayer(playing: playing)
            defer { model.teardown() }
            for direction in [1, -1] {
                let start = model.player.currentTime().seconds
                for _ in 0..<10 {
                    model.beginFastSeeking(direction: direction, mode: .jump)
                    model.endFastSeeking()
                }
                try await waitUntilCondition { !model.isSeeking }
                XCTAssertEqual(model.player.currentTime().seconds, start + Double(direction) * length * 10, accuracy: 0.5)
                let beforeHold = model.player.currentTime().seconds
                model.beginFastSeeking(direction: direction, mode: .jump)
                // Native key-repeat events must neither restart the delay nor
                // introduce extra jumps alongside the player's repeat timer.
                for _ in 0..<10 {
                    try await Task.sleep(for: .milliseconds(100))
                    model.beginFastSeeking(direction: direction, mode: .jump)
                }
                model.endFastSeeking()
                try await waitUntilCondition { !model.isSeeking }
                let progress = (model.player.currentTime().seconds - beforeHold) * Double(direction)
                XCTAssertGreaterThan(progress, length * 4.5)
                XCTAssertLessThan(progress, length * 8.2)
                XCTAssertEqual(model.playbackRequested, playing)
                XCTAssertEqual(model.player.rate, playing ? model.playbackRate : 0)
                var display = CMTime.invalid
                try await waitUntilCondition {
                    self.output?.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: &display) != nil
                }
                XCTAssertEqual(display.seconds, model.player.currentTime().seconds, accuracy: 0.5)
            }
        }
    }

    func testPausedHeldArrowsMakeProgressBeyondKeyframesWhenProvided() async throws {
        let model = try await localPlayer(playing: false)
        defer { model.teardown() }
        for direction in [-1, 1] {
            model.beginFastSeeking(direction: direction)
            try await waitUntilCondition { model.isFastSeeking && !model.isSeeking }
            let start = model.player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(700))
            model.endFastSeeking()
            try await waitUntilCondition { !model.isSeeking }
            XCTAssertGreaterThan((model.player.currentTime().seconds - start) * Double(direction), 1.5)
            XCTAssertEqual(model.player.rate, 0)
            XCTAssertFalse(model.playbackRequested)
        }
    }

    func testNativeReverseReachingStartDoesNotCompleteOrCloseTheFileWhenProvided() async throws {
        let name = "ReverseBoundary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.afterPlayback = .repeatFile
        let model = try await localPlayer(playing: false, preferences: preferences)
        defer { model.teardown() }
        XCTAssertTrue(try XCTUnwrap(model.player.currentItem).canPlayFastReverse)
        model.seek(to: 0.8, tolerance: 0.05)
        try await waitUntilCondition { !model.isSeeking }
        model.player.rate = -4
        try await waitUntilCondition { model.player.rate == 0 && model.player.currentTime().seconds < 0.1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.playbackFinished)
        XCTAssertEqual(model.currentTime, 0, accuracy: 0.1)
        XCTAssertNotNil(model.player.currentItem)
    }

    func testShiftHoldsUseNativeFastForwardAndReverseAndRestoreStateWhenProvided() async throws {
        for playing in [false, true] {
            for direction in [-1, 1] {
                let model = try await localPlayer(playing: playing)
                defer { model.teardown() }
                model.playbackRate = 1.5
                let item = try XCTUnwrap(model.player.currentItem)
                XCTAssertTrue(direction > 0 ? item.canPlayFastForward : item.canPlayFastReverse)
                model.beginFastSeeking(direction: direction, mode: .shuttle)
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(model.isFastSeeking)
                model.beginFastSeeking(direction: direction, mode: .shuttle)
                try await waitUntilCondition { model.isFastSeeking }
                XCTAssertEqual(model.player.rate, Float(direction) * 4)
                XCTAssertEqual(model.playbackRequested, playing)
                XCTAssertEqual(model.playbackRate, 1.5)
                let start = model.player.currentTime().seconds
                try await waitUntilCondition {
                    (model.player.currentTime().seconds - start) * Double(direction) > 0.5
                }
                var display = CMTime.invalid
                try await waitUntilCondition {
                    self.output?.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: &display) != nil
                }
                XCTAssertEqual(display.seconds, model.player.currentTime().seconds, accuracy: 0.5)
                model.endFastSeeking()
                XCTAssertEqual(model.player.rate, playing ? 1.5 : 0)
                XCTAssertEqual(model.playbackRequested, playing)
                XCTAssertFalse(model.isFastSeeking)
                let timebase = try XCTUnwrap(item.timebase)
                try await waitUntilCondition {
                    abs(CMTimebaseGetEffectiveRate(timebase) - (playing ? 1.5 : 0)) < 0.01
                }
                let released = model.player.currentTime().seconds
                try await Task.sleep(for: .milliseconds(250))
                if playing {
                    XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, released)
                } else {
                    XCTAssertEqual(model.player.currentTime().seconds, released, accuracy: 0.05)
                }
            }
        }
    }

    func testHeldReverseAtStartPreservesReleaseIntentAndDoesNotCloseWhenProvided() async throws {
        let name = "HeldReverseBoundary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.afterPlayback = .repeatFile
        for playing in [false, true] {
            let model = try await localPlayer(playing: playing, preferences: preferences)
            defer { model.teardown() }
            model.seek(to: 6, tolerance: 0.05)
            try await waitUntilCondition { !model.isSeeking }
            model.beginFastSeeking(direction: -1, mode: .shuttle)
            try await waitUntilCondition { model.isFastSeeking && model.player.rate < 0 }
            try await waitUntilCondition { model.player.currentTime().seconds < 0.1 && model.player.rate == 0 }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(model.isFastSeeking)
            XCTAssertEqual(model.playbackRequested, playing)
            XCTAssertFalse(model.playbackFinished)
            XCTAssertNotNil(model.player.currentItem)
            model.endFastSeeking()
            XCTAssertEqual(model.player.rate, playing ? model.playbackRate : 0)
            XCTAssertFalse(model.isFastSeeking)
        }
    }

    func testSettledJumpsUseNativeClockAndRapidJumpsUsePendingTargets() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        let positioned = await model.player.seek(to: CMTime(seconds: 8, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(positioned)
        // A native seek can precede delivery of the periodic UI timestamp.
        model.currentTime = 0
        model.beginFastSeeking(direction: 1)
        model.endFastSeeking()
        try await waitUntilCondition { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 13, accuracy: 0.1)
        for _ in 0..<3 {
            model.beginFastSeeking(direction: -1)
            model.endFastSeeking()
        }
        try await waitUntilCondition { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertEqual(model.player.rate, 0)
    }
}
