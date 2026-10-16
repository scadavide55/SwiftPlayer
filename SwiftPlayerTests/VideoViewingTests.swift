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

    func testAspectFitAndFillAreCenteredAndRespectTheirBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        for aspect in VideoAspect.allCases where aspect != .original {
            for fit in VideoFit.allCases {
                let frame = VideoDisplayOptions(fit: fit, aspect: aspect).frame(in: bounds)
                XCTAssertEqual(frame.midX, bounds.midX, accuracy: 0.001)
                XCTAssertEqual(frame.midY, bounds.midY, accuracy: 0.001)
                XCTAssertEqual(frame.width / frame.height, aspect.ratio!, accuracy: 0.001)
                if fit == .fit {
                    XCTAssertLessThanOrEqual(frame.width, bounds.width + 0.001)
                    XCTAssertLessThanOrEqual(frame.height, bounds.height + 0.001)
                } else {
                    XCTAssertGreaterThanOrEqual(frame.width, bounds.width - 0.001)
                    XCTAssertGreaterThanOrEqual(frame.height, bounds.height - 0.001)
                }
            }
        }
        XCTAssertEqual(VideoDisplayOptions().frame(in: bounds), bounds)
        XCTAssertEqual(VideoDisplayOptions(aspect: .square).frame(in: .zero), .zero)
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
        view.display.aspect = .widescreen
        view.layout()
        XCTAssertEqual(view.playerLayer.videoGravity, .resize)
        XCTAssertEqual(view.playerLayer.frame.width / view.playerLayer.frame.height, 16 / 9, accuracy: 0.001)
        XCTAssertEqual(view.layer?.masksToBounds, true)
        XCTAssertNil(item.videoComposition)
        XCTAssertTrue(item.outputs.isEmpty)
        PlayerLayerView.dismantleNSView(view, coordinator: ())
    }

    func testRetinaSizingScreenClampingAndInvalidDimensions() throws {
        let available = CGSize(width: 1400, height: 900)
        let hd = CGSize(width: 1920, height: 1080)
        let original = try XCTUnwrap(PlayerWindowControls.contentSize(video: hd, scale: 1,
            backingScale: 2, available: available, minimum: .zero))
        XCTAssertEqual(original, CGSize(width: 960, height: 540))
        let half = try XCTUnwrap(PlayerWindowControls.contentSize(video: hd, scale: 0.5,
            backingScale: 2, available: available, minimum: .zero))
        XCTAssertEqual(half, CGSize(width: 480, height: 270))
        for scale: CGFloat? in [nil, 1, 2] {
            let huge = try XCTUnwrap(PlayerWindowControls.contentSize(video: CGSize(width: 8192, height: 4320),
                scale: scale, backingScale: 2, available: available, minimum: CGSize(width: 480, height: 320)))
            XCTAssertLessThanOrEqual(huge.width, available.width)
            XCTAssertLessThanOrEqual(huge.height, available.height)
            XCTAssertGreaterThanOrEqual(huge.width, 480)
            XCTAssertGreaterThanOrEqual(huge.height, 320)
        }
        XCTAssertNil(PlayerWindowControls.contentSize(video: .zero, scale: 1, backingScale: 2, available: available, minimum: .zero))
        XCTAssertNil(PlayerWindowControls.contentSize(video: hd, scale: .nan, backingScale: 2, available: available, minimum: .zero))
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
        controls.resize(scale: 1)
        controls.display = VideoDisplayOptions(fit: .fill, aspect: .classic)
        controls.resize(scale: nil)
        XCTAssertTrue(model.player.currentItem === item)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.player.currentTime().seconds, time, accuracy: 0.001)
        try await ready(model)
        try await waitUntilCondition { !controls.hasVideo }
        controls.detach()
        XCTAssertEqual(controls.videoSize, .zero)
    }
}
