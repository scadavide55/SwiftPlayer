import XCTest
import AppKit
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class VideoViewingTests: DebugMatrixTestCase {
    private final class TestWindow: NSWindow {
        var fullScreenRequests = 0
        override func toggleFullScreen(_ sender: Any?) { fullScreenRequests += 1 }
    }

    private func window() -> TestWindow {
        let window = TestWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 360),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testNativeVideoLayerUsesGravityWithoutAddingCompositionOrOutputs() {
        let player = AVPlayer()
        let item = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: item)
        defer { player.replaceCurrentItem(with: nil) }
        let view = PlayerLayerNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.playerLayer.player = player
        view.display.fit = .fill
        view.layout()
        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspectFill)
        view.display.fit = .fit
        view.layout()
        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspect)
        XCTAssertEqual(view.playerLayer.frame, view.bounds)
        XCTAssertEqual(view.layer?.masksToBounds, true)
        XCTAssertNil(item.videoComposition)
        XCTAssertTrue(item.outputs.isEmpty)
        PlayerLayerView.dismantleNSView(view, coordinator: ())
    }

    func testAlwaysOnTopIsPerWindowAndRestoresTheOriginalLevel() {
        let first = window(), other = window()
        defer { first.close(); other.close() }
        let controls = PlayerWindowControls()
        controls.attach(first)
        controls.alwaysOnTop = true
        XCTAssertEqual(first.level, .floating)
        XCTAssertEqual(other.level, .normal)
        controls.attach(other)
        XCTAssertEqual(first.level, .normal)
        XCTAssertEqual(other.level, .floating)
        controls.detach()
        XCTAssertEqual(other.level, .normal)
        XCTAssertFalse(controls.isAttached)
    }

    func testFullscreenTargetsOnlyItsOwnerAndCoalescesTransitionRequests() {
        let owner = window(), other = window()
        defer { owner.close(); other.close() }
        let controls = PlayerWindowControls()
        controls.attach(owner)
        controls.alwaysOnTop = true
        controls.toggleFullScreen()
        controls.toggleFullScreen()
        XCTAssertEqual(owner.fullScreenRequests, 1)
        XCTAssertEqual(other.fullScreenRequests, 0)
        XCTAssertEqual(owner.level, .normal)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: other)
        XCTAssertTrue(controls.isTransitioning)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: owner)
        XCTAssertTrue(controls.isFullScreen)
        controls.toggleFullScreen()
        XCTAssertEqual(owner.fullScreenRequests, 2)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: owner)
        XCTAssertEqual(owner.level, .floating)
        XCTAssertFalse(controls.isFullScreen)
        controls.detach()
    }

    func testNativePresentationSizeAndReplacementWhenLocalMediaIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else {
            throw XCTSkip("Set optional local HD media for window sizing integration")
        }
        let model = PlayerModel()
        let controls = PlayerWindowControls()
        let owner = window()
        defer { controls.detach(); model.teardown(); owner.close() }
        controls.attach(owner)
        controls.observe(model.player)
        try await ready(model, url: URL(fileURLWithPath: path))
        try await waitUntilCondition { controls.hasVideo }
        XCTAssertEqual(controls.videoSize.width, 1920)
        let item = model.player.currentItem
        let time = model.player.currentTime().seconds
        owner.setContentSize(CGSize(width: 800, height: 450))
        controls.display.fit = .fill
        XCTAssertTrue(model.player.currentItem === item)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.player.currentTime().seconds, time, accuracy: 0.001)
        try await ready(model)
        try await waitUntilCondition { !controls.hasVideo }
        controls.detach()
        XCTAssertEqual(controls.videoSize, .zero)
    }
}
