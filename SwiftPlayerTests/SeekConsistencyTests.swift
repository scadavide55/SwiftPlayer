import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class SeekConsistencyTests: DebugMatrixTestCase {
    func testEightySettledTapsKeepFiveSecondTargetsAndRefreshFramesWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_CONSISTENCY_MEDIA"] else {
            throw XCTSkip("Provide a local video longer than 450 seconds for repeated tap measurements.")
        }
        let model = PlayerModel()
        model.player.isMuted = true
        defer { model.teardown() }
        try await ready(model, url: URL(fileURLWithPath: path))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        model.player.currentItem?.add(output)
        model.play()
        try await waitUntilCondition { output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil) != nil }
        model.pause()
        var endpoints: [Double] = []
        for _ in 0..<3 {
            model.seek(to: 20, tolerance: 0)
            try await waitUntilCondition { !model.isSeeking }
            let start = model.player.currentTime().seconds
            var lastRequested = start
            for direction in [1, -1] {
                let sequenceStart = lastRequested
                for index in 1...80 {
                    model.beginFastSeeking(direction: direction)
                    lastRequested = model.currentTime
                    XCTAssertEqual(lastRequested, sequenceStart + Double(direction * index) * 5, accuracy: 0.00001)
                    model.endFastSeeking()
                    try await waitUntilCondition { !model.isSeeking }
                    var displayed = CMTime.invalid
                    try await waitUntilCondition {
                        output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: &displayed) != nil
                            && abs(displayed.seconds - model.player.currentTime().seconds) < 0.05
                    }
                    XCTAssertEqual(displayed.seconds, model.player.currentTime().seconds, accuracy: 0.05)
                    XCTAssertEqual(model.player.rate, 0)
                }
                let expected = direction > 0 ? start + 400 : start
                XCTAssertEqual(lastRequested, expected, accuracy: 0.00001)
                XCTAssertEqual(model.player.currentTime().seconds, expected, accuracy: 0.12501)
                if direction > 0 { endpoints.append(model.player.currentTime().seconds) }
            }
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(endpoints.max()) - XCTUnwrap(endpoints.min()), 0.25001)
    }

    func testTightTapsRefreshLocal8KFramesWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_MEDIA"] else {
            throw XCTSkip("Provide local 8K video for tap consistency checks.")
        }
        let model = PlayerModel()
        model.player.isMuted = true
        defer { model.teardown() }
        try await ready(model, url: URL(fileURLWithPath: path))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        model.player.currentItem?.add(output)
        model.play()
        try await waitUntilCondition { output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil) != nil }
        model.pause()
        model.seek(to: 20, tolerance: 0.05)
        try await waitUntilCondition { !model.isSeeking }
        let start = model.player.currentTime().seconds
        for direction in [1, -1] {
            for index in 1...10 {
                let expected = start + Double(direction > 0 ? index : 10 - index) * 5
                model.beginFastSeeking(direction: direction)
                XCTAssertEqual(model.currentTime, expected, accuracy: 0.00001)
                model.endFastSeeking()
                try await waitUntilCondition { !model.isSeeking }
                XCTAssertEqual(model.player.currentTime().seconds, expected, accuracy: 0.12501)
                var displayed = CMTime.invalid
                try await waitUntilCondition {
                    output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: &displayed) != nil
                        && abs(displayed.seconds - model.player.currentTime().seconds) < 0.05
                }
                XCTAssertEqual(model.player.rate, 0)
            }
        }
    }

    func testScrubbingRebasesNavigationOnThePendingSliderPosition() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        model.skip(by: 5)
        try await waitUntilCondition { !model.isSeeking }
        model.isScrubbing = true
        model.currentTime = 10
        model.skip(by: 5)
        model.isScrubbing = false
        try await waitUntilCondition { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 15, accuracy: 0.00001)
    }

    func testExplicitAndNativeSeeksRebaseThePausedTapSequence() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        model.skip(by: 5)
        try await waitUntilCondition { !model.isSeeking }
        model.seek(to: 2)
        try await waitUntilCondition { !model.isSeeking }
        model.skip(by: 5)
        try await waitUntilCondition { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 7, accuracy: 0.00001)
        _ = await model.player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        model.skip(by: 5)
        try await waitUntilCondition { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 8, accuracy: 0.00001)
        model.skip(by: -5)
        try await waitUntilCondition { !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, 3, accuracy: 0.00001)
    }
}
