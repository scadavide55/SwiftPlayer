import XCTest
import AVFoundation
import AppKit
import Combine
@testable import SwiftPlayer

@MainActor
final class MemoryDebugMatrixTests: DebugMatrixTestCase {
    func test100MemoryOwnershipRounds() async throws {
        let names = ["ready-model-release", "pending-load-release", "seek-close", "pending-key-close", "active-key-close",
                     "subtitle-close", "layer-callback-release", "keyboard-callback-release", "mouse-callback-release", "observer-removal"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("memory", family * 10 + variant, "\(names[family]); rate=\(Double(variant + 1) / 4); volume=\(Double(variant + 1) / 10)") {
                    var model: PlayerModel? = PlayerModel()
                    model?.playbackRate = Float(variant + 1) / 4
                    model?.volume = Float(variant + 1) / 10
                    model?.isMuted = variant % 2 == 0
                    let released: @MainActor @Sendable () -> Bool = { [weak model] in model == nil }
                    let player = try XCTUnwrap(model).player
                    switch family {
                    case 0:
                        try await ready(try XCTUnwrap(model), url: audio[variant % 2])
                    case 1:
                        model?.load(url: audio[variant % 2])
                        try await settle(variant)
                    case 2:
                        try await ready(try XCTUnwrap(model))
                        for index in 0...variant { model?.seek(to: Double(index + 1)) }
                    case 3, 4:
                        try await ready(try XCTUnwrap(model))
                        model?.beginFastSeeking(direction: variant % 2 == 0 ? -1 : 1)
                        if family == 4 { try await waitUntilCondition { model?.isFastSeeking == true } }
                    case 5:
                        let url = directory.appendingPathComponent("captions.srt")
                        try String(repeating: "1\n00:00:00,000 --> 00:00:02,000\nCaption\n\n", count: (variant + 1) * 1_000)
                            .write(to: url, atomically: true, encoding: .utf8)
                        model?.loadSubtitles(url: url)
                        try await settle(variant)
                    case 6:
                        let view = PlayerLayerNSView(frame: NSRect(x: 0, y: 0, width: 100 + variant, height: 60))
                        view.playerLayer.player = player
                        view.onLayerReady = { [retained = model] _ in _ = retained }
                        model = nil
                        XCTAssertFalse(released())
                        PlayerLayerView.dismantleNSView(view, coordinator: ())
                        XCTAssertNil(view.playerLayer.player)
                        XCTAssertNil(view.onLayerReady)
                        try await waitUntilCondition(released)
                        return
                    case 7:
                        let view = KeyEventHandlingView.KeyCatcherView()
                        view.onSpace = { [retained = model] in retained?.togglePlayPause() }
                        view.onArrowDown = { [retained = model] direction, mode in
                            retained?.beginFastSeeking(direction: direction, mode: mode)
                        }
                        model = nil
                        XCTAssertFalse(released())
                        KeyEventHandlingView.dismantleNSView(view, coordinator: ())
                        try await waitUntilCondition(released)
                        return
                    case 8:
                        let view = MouseActivityTracker.TrackingNSView()
                        view.onActivity = { [retained = model] in _ = retained?.isPlaying }
                        model = nil
                        XCTAssertFalse(released())
                        MouseActivityTracker.dismantleNSView(view, coordinator: ())
                        try await waitUntilCondition(released)
                        return
                    default:
                        try await ready(try XCTUnwrap(model))
                        let old = try XCTUnwrap(player.currentItem)
                        model?.teardown()
                        for _ in 0...variant {
                            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: old)
                            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: old)
                        }
                        try await settle(variant)
                        XCTAssertFalse(try XCTUnwrap(model).playbackFailed)
                        XCTAssertFalse(try XCTUnwrap(model).playbackFinished)
                    }
                    weak var item = player.currentItem
                    model = nil
                    try await waitUntilCondition { released() && item == nil }
                    XCTAssertNil(player.currentItem)
                    XCTAssertEqual(player.rate, 0)
                }
            }
        }
    }
}
