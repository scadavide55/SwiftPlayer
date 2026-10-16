import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class NavigationReliabilityTests: DebugMatrixTestCase {
    private var output: AVPlayerItemVideoOutput?
    private func localPlayer(playing: Bool) async throws -> PlayerModel {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_NAVIGATION_MEDIA"] else {
            throw XCTSkip("Provide local long-GOP video to check repeated navigation.")
        }
        let model = PlayerModel()
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
}
