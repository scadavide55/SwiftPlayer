import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class LoadingDebugMatrixTests: DebugMatrixTestCase {
    func test100LoadingAndCancellationRounds() async throws {
        let names = ["pause-during-load", "pause-play-during-load", "replacement", "missing-then-valid",
                     "valid-then-missing", "close-during-load", "close-then-reopen", "release-during-load",
                     "old-notifications", "three-replacements"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("loading", family * 10 + variant, "\(names[family]); schedule=\(variant)") {
                    var model: PlayerModel? = PlayerModel()
                    let released: @MainActor @Sendable () -> Bool = { [weak model] in model == nil }
                    defer { model?.teardown() }
                    let missing = directory.appendingPathComponent("missing.mp4")
                    model?.load(url: family == 3 ? missing : audio[0])
                    try await settle(variant)
                    switch family {
                    case 0:
                        model?.pause()
                    case 1:
                        model?.pause()
                        model?.play()
                    case 2, 3:
                        model?.load(url: audio[1])
                    case 4:
                        model?.load(url: missing)
                        try await waitUntilCondition { model?.playbackFailed == true }
                        assertClosed(try XCTUnwrap(model))
                        return
                    case 5:
                        model?.teardown()
                        try await settle(9 - variant)
                        assertClosed(try XCTUnwrap(model))
                        return
                    case 6:
                        model?.teardown()
                        model?.load(url: audio[1])
                    case 7:
                        let player = try XCTUnwrap(model).player
                        model = nil
                        try await waitUntilCondition(released)
                        XCTAssertNil(player.currentItem)
                        XCTAssertEqual(player.rate, 0)
                        return
                    case 8:
                        try await waitUntilCondition { model?.player.currentItem?.status == .readyToPlay }
                        let old = try XCTUnwrap(model?.player.currentItem)
                        model?.load(url: audio[1])
                        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: old)
                        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: old)
                    default:
                        model?.load(url: audio[1])
                        try await settle(9 - variant)
                        model?.load(url: audio[0])
                    }
                    let current = try XCTUnwrap(model)
                    try await waitUntilCondition { !current.isLoading }
                    XCTAssertFalse(current.playbackFailed)
                    XCTAssertEqual(current.player.currentItem?.status, .readyToPlay)
                    let expected = [2, 3, 6, 8].contains(family) ? audio[1] : audio[0]
                    XCTAssertEqual((current.player.currentItem?.asset as? AVURLAsset)?.url, expected)
                    XCTAssertEqual(current.playbackRequested, family != 0)
                    if family == 0 { XCTAssertEqual(current.player.rate, 0) }
                    current.teardown()
                    assertClosed(current)
                }
            }
        }
    }
}
