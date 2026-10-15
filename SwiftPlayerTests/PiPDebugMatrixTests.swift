import XCTest
import AVFoundation
import AVKit
import AppKit
@testable import SwiftPlayer

@MainActor
final class PiPDebugMatrixTests: DebugMatrixTestCase {
    func test100PiPAndVideoLayerRounds() async throws {
        let names = ["attach-detach", "replace-layer", "repeated-detach", "stop", "foreign-start", "foreign-stop",
                     "foreign-failure", "resize-once", "view-owner-release", "pip-observer-release"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("pip", family * 10 + variant, "\(names[family]); input=\(variant)") {
                    var pip: PiPController? = PiPController()
                    let released: @MainActor @Sendable () -> Bool = { [weak pip] in pip == nil }
                    let model = PlayerModel()
                    defer { pip?.detach(); model.teardown() }
                    let hd = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"].map { URL(fileURLWithPath: $0) }
                    try await ready(model, url: hd ?? audio[variant % 2])
                    model.seek(to: Double(variant) * 0.1)
                    let layer = AVPlayerLayer(player: model.player)
                    layer.frame = NSRect(x: 0, y: 0, width: 320 + variant * 16, height: 180 + variant * 9)
                    switch family {
                    case 0:
                        pip?.attach(to: layer)
                        try await settle(variant)
                        pip?.detach()
                    case 1:
                        pip?.attach(to: layer)
                        for index in 0...variant {
                            let replacement = AVPlayerLayer(player: model.player)
                            replacement.frame = NSRect(x: 0, y: 0, width: 100 + index * 10, height: 100)
                            pip?.attach(to: replacement)
                        }
                        pip?.detach()
                    case 2:
                        pip?.attach(to: layer)
                        for _ in 0...variant { pip?.detach() }
                    case 3:
                        pip?.attach(to: layer)
                        for _ in 0...variant { pip?.stop() }
                        XCTAssertFalse(try XCTUnwrap(pip).isActive)
                        pip?.detach()
                    case 4, 5, 6:
                        pip?.attach(to: layer)
                        let foreign = AVPictureInPictureController(playerLayer: AVPlayerLayer(player: model.player))
                        if let foreign {
                            switch family {
                            case 4: pip?.pictureInPictureControllerDidStartPictureInPicture(foreign)
                            case 5: pip?.pictureInPictureControllerDidStopPictureInPicture(foreign)
                            default: pip?.pictureInPictureController(foreign, failedToStartPictureInPictureWithError: NSError(domain: "ForeignPiP", code: variant))
                            }
                        } else { XCTFail("Native PiP controller could not be constructed.") }
                        try await settle(variant)
                        XCTAssertFalse(try XCTUnwrap(pip).isActive)
                        pip?.detach()
                    case 7:
                        let view = PlayerLayerNSView(frame: layer.frame)
                        var callbacks = 0
                        view.playerLayer.player = model.player
                        view.onLayerReady = { _ in callbacks += 1 }
                        for index in 0...variant {
                            view.frame = NSRect(x: 0, y: 0, width: 320 + index * 16, height: 180 + variant * 9)
                            view.layout()
                            XCTAssertEqual(view.playerLayer.frame, view.bounds)
                        }
                        XCTAssertEqual(callbacks, 1)
                        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspect)
                        PlayerLayerView.dismantleNSView(view, coordinator: ())
                        XCTAssertNil(view.playerLayer.player)
                    case 8:
                        let view = PlayerLayerNSView(frame: layer.frame)
                        view.onLayerReady = { [owner = pip] playerLayer in owner?.attach(to: playerLayer) }
                        view.playerLayer.player = model.player
                        view.layout()
                        pip = nil
                        XCTAssertFalse(released())
                        PlayerLayerView.dismantleNSView(view, coordinator: ())
                        try await waitUntilCondition(released)
                        return
                    default:
                        pip?.attach(to: layer)
                        try await settle(variant)
                        pip = nil
                        try await waitUntilCondition(released)
                        XCTAssertNotNil(model.player.currentItem)
                        return
                    }
                    XCTAssertFalse(try XCTUnwrap(pip).isActive)
                    XCTAssertFalse(try XCTUnwrap(pip).isPossible)
                }
            }
        }
    }
}
