import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class PlaybackDebugMatrixTests: DebugMatrixTestCase {
    func test100PlaybackStateRounds() async throws {
        let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4]
        let names = ["paused-rate", "resume-rate", "toggle-parity", "invalid-rate", "mute-volume",
                     "volume-boundaries", "end-replay", "end-seek-paused", "failure-recovery", "natural-end"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("playback", family * 10 + variant, "\(names[family]); rate=\(rates[variant])") {
                    let model = PlayerModel()
                    defer { model.teardown() }
                    try await ready(model)
                    model.playbackRate = rates[variant]
                    switch family {
                    case 0:
                        XCTAssertEqual(model.player.rate, 0)
                        XCTAssertFalse(model.playbackRequested)
                    case 1:
                        model.play()
                        try await waitUntilCondition { model.isPlaying }
                        XCTAssertEqual(model.player.rate, rates[variant])
                        model.pause()
                        XCTAssertEqual(model.player.rate, 0)
                    case 2:
                        for _ in 0...variant { model.togglePlayPause() }
                        XCTAssertEqual(model.playbackRequested, variant % 2 == 0)
                        XCTAssertEqual(model.player.rate, variant % 2 == 0 ? rates[variant] : 0)
                    case 3:
                        for invalid: Float in [.nan, .infinity, -.infinity, -1, 0, 5, 100] {
                            model.playbackRate = invalid
                            XCTAssertEqual(model.playbackRate, rates[variant])
                        }
                        XCTAssertEqual(model.player.rate, 0)
                    case 4:
                        model.volume = Float(variant) / 10
                        model.isMuted = true
                        XCTAssertTrue(model.player.isMuted)
                        model.volumeUp()
                        XCTAssertFalse(model.player.isMuted)
                        XCTAssertEqual(model.player.volume, min(Float(variant) / 10 + 0.05, 1), accuracy: 0.001)
                    case 5:
                        model.volume = Float(variant) / 10
                        model.volume = -Float(variant + 1)
                        XCTAssertEqual(model.player.volume, 0)
                        model.volume = Float(variant + 2)
                        XCTAssertEqual(model.player.volume, 1)
                        model.volume = .nan
                        XCTAssertEqual(model.volume, model.maximumVolume)
                        XCTAssertEqual(model.player.volume, 1)
                    case 6:
                        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: model.player.currentItem)
                        XCTAssertTrue(model.playbackFinished)
                        model.play()
                        try await waitUntilCondition { model.isPlaying && model.player.currentTime().seconds < 2 }
                        XCTAssertFalse(model.playbackFinished)
                    case 7:
                        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: model.player.currentItem)
                        model.seek(to: Double(variant + 1))
                        try await waitUntilCondition { abs(model.player.currentTime().seconds - Double(variant + 1)) < 0.1 }
                        XCTAssertFalse(model.playbackFinished)
                        XCTAssertFalse(model.playbackRequested)
                        XCTAssertEqual(model.player.rate, 0)
                    case 8:
                        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,
                            object: model.player.currentItem,
                            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: "FixtureFailure", code: variant)])
                        try await waitUntilCondition { model.playbackFailed }
                        assertClosed(model)
                        try await ready(model)
                        XCTAssertEqual(model.playbackRate, rates[variant])
                        XCTAssertFalse(model.playbackFailed)
                    default:
                        model.seek(to: model.duration - 0.1 - Double(variant) / 100)
                        model.play()
                        try await waitUntilCondition { model.playbackFinished }
                        XCTAssertFalse(model.playbackRequested)
                        XCTAssertFalse(model.isPlaying)
                        model.play()
                        try await waitUntilCondition { model.isPlaying && model.currentTime < 2 }
                        XCTAssertEqual(model.player.rate, rates[variant])
                    }
                }
            }
        }
    }
}
