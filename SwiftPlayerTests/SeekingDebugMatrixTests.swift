import XCTest
import AVFoundation
import Combine
@testable import SwiftPlayer

@MainActor
final class SeekingDebugMatrixTests: DebugMatrixTestCase {
    func test100SeekingAndScrubbingRounds() async throws {
        let names = ["clamp-start", "clamp-end", "rapid-latest", "scrub-holds-ui", "quick-key-release",
                     "paused-forward", "reverse-resume", "direction-switch", "pause-hold", "boundary-no-repeat"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("seeking", family * 10 + variant, "\(names[family]); input=\(variant)") {
                    let model = PlayerModel()
                    defer { model.teardown() }
                    try await ready(model)
                    let target = Double(variant + 1)
                    switch family {
                    case 0:
                        model.seek(to: -target * 100)
                        try await waitUntilCondition { model.player.currentTime().seconds < 0.05 }
                        XCTAssertEqual(model.currentTime, 0, accuracy: 0.05)
                    case 1:
                        model.seek(to: model.duration + target * 100)
                        try await waitUntilCondition { abs(model.player.currentTime().seconds - model.duration) < 0.05 }
                        XCTAssertEqual(model.currentTime, model.duration, accuracy: 0.05)
                    case 2:
                        for index in 0..<20 { model.seek(to: Double((index * (variant + 1)) % 19)) }
                        model.seek(to: target)
                        try await waitUntilCondition { abs(model.player.currentTime().seconds - target) < 0.05 }
                        try await settle(variant)
                        XCTAssertEqual(model.currentTime, target, accuracy: 0.05)
                    case 3:
                        model.isScrubbing = true
                        model.currentTime = target
                        try await Task.sleep(for: .milliseconds(120))
                        XCTAssertEqual(model.currentTime, target)
                        model.seek(to: target)
                        model.isScrubbing = false
                        try await waitUntilCondition { abs(model.player.currentTime().seconds - target) < 0.05 }
                    case 4:
                        model.beginFastSeeking(direction: variant % 2 == 0 ? 1 : -1)
                        try await settle(variant)
                        model.endFastSeeking()
                        try await Task.sleep(for: .milliseconds(810))
                        XCTAssertFalse(model.isFastSeeking)
                        XCTAssertEqual(model.player.rate, 0)
                    case 5:
                        model.seek(to: target)
                        model.beginFastSeeking(direction: 1)
                        try await waitUntilCondition { model.isFastSeeking }
                        XCTAssertFalse(model.playbackRequested)
                        XCTAssertEqual(model.player.rate, 0)
                        model.endFastSeeking()
                    case 6:
                        model.seek(to: 10 + target / 2)
                        model.playbackRate = Float(variant + 1) / 4
                        model.play()
                        model.beginFastSeeking(direction: -1)
                        try await waitUntilCondition { model.isFastSeeking }
                        XCTAssertEqual(model.player.rate, 0)
                        model.endFastSeeking()
                        try await waitUntilCondition { model.isPlaying }
                        XCTAssertEqual(model.player.rate, model.playbackRate)
                    case 7:
                        model.seek(to: 10)
                        model.beginFastSeeking(direction: -1)
                        try await waitUntilCondition { model.isFastSeeking }
                        model.beginFastSeeking(direction: 1)
                        try await waitUntilCondition { model.isFastSeeking }
                        let before = model.currentTime
                        try await Task.sleep(for: .milliseconds(220 + variant * 5))
                        XCTAssertGreaterThan(model.currentTime, before)
                    case 8:
                        model.play()
                        model.beginFastSeeking(direction: variant % 2 == 0 ? -1 : 1)
                        try await waitUntilCondition { model.isFastSeeking }
                        model.pause()
                        try await settle(variant)
                        XCTAssertFalse(model.isFastSeeking)
                        XCTAssertEqual(model.player.rate, 0)
                        XCTAssertFalse(model.playbackRequested)
                    default:
                        let direction = variant % 2 == 0 ? -1 : 1
                        let endpoint = direction == -1 ? 0 : model.duration
                        model.seek(to: endpoint)
                        model.beginFastSeeking(direction: direction)
                        try await waitUntilCondition { model.isFastSeeking }
                        try await Task.sleep(for: .milliseconds(100))
                        var changes = 0
                        let token = model.$currentTime.dropFirst().sink { _ in changes += 1 }
                        try await Task.sleep(for: .milliseconds(220 + variant * 5))
                        token.cancel()
                        XCTAssertEqual(changes, 0)
                        XCTAssertEqual(model.currentTime, endpoint, accuracy: 0.05)
                    }
                }
            }
        }
    }
}
