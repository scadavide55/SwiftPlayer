import XCTest
import AVFoundation
import CoreGraphics
@testable import SwiftPlayer

@MainActor
final class SeekPreviewTests: DebugMatrixTestCase {
    func testCacheEvictsLeastRecentlyUsedImagesWithinByteAndCountLimits() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
            bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let cost = image.bytesPerRow * image.height
        var cache = ThumbnailCache(byteLimit: cost * 4, countLimit: 4)
        for key in 0..<4 { cache.insert(image, time: Double(key), for: key) }
        XCTAssertNotNil(cache.entry(for: 0))
        cache.insert(image, time: 4, for: 4)
        XCTAssertNil(cache.entry(for: 1))
        XCTAssertNotNil(cache.entry(for: 0))
        XCTAssertLessThanOrEqual(cache.bytes, cost * 4)
        XCTAssertEqual(cache.entries.count, 4)
        var small = ThumbnailCache(byteLimit: cost - 1)
        small.insert(image, time: 0, for: 0)
        XCTAssertTrue(small.entries.isEmpty)
        cache.reset()
        XCTAssertEqual(cache.bytes, 0)
        XCTAssertTrue(cache.entries.isEmpty)
    }

    func testAudioOnlyAndInvalidRequestsFailQuietlyAndClosingReleasesController() async throws {
        var preview: SeekPreviewController? = SeekPreviewController()
        weak var weakPreview = preview
        preview?.attach(AVURLAsset(url: audio[0]))
        for invalid in [Double.nan, .infinity, -.infinity] { preview?.request(time: invalid, duration: 12) }
        XCTAssertFalse(preview?.isLoading ?? true)
        preview?.request(time: 2, duration: 12)
        try await waitUntilCondition { preview?.isLoading == false }
        XCTAssertNil(preview?.image)
        preview?.request(time: 3, duration: 12)
        preview?.detach()
        preview = nil
        try await waitUntilCondition { weakPreview == nil }
    }

    private func verifyLocalPreview(environment: String, repeats: Int) async throws {
        guard let path = ProcessInfo.processInfo.environment[environment] else {
            throw XCTSkip("Set the optional local video to verify native seek previews")
        }
        let model = PlayerModel()
        let preview = SeekPreviewController()
        defer { preview.detach(); model.teardown() }
        try await ready(model, url: URL(fileURLWithPath: path))
        let item = try XCTUnwrap(model.player.currentItem)
        for iteration in 0..<repeats {
            preview.attach(item.asset)
            let playing = iteration.isMultiple(of: 2)
            if playing { model.play(); try await waitUntilCondition { model.isPlaying } }
            else { model.pause() }
            let before = model.player.currentTime().seconds
            let started = Date()
            for request in 0..<100 {
                preview.request(time: Double((request + iteration) % 20), duration: model.duration)
            }
            let target = min(19 + Double(iteration % 2), model.duration / 2)
            preview.request(time: target, duration: model.duration)
            try await waitUntilCondition { preview.image != nil && !preview.isLoading }
            let image = try XCTUnwrap(preview.image)
            XCTAssertLessThanOrEqual(image.width, 320)
            XCTAssertLessThanOrEqual(image.height, 180)
            XCTAssertLessThanOrEqual(abs((preview.imageTime ?? -100) - target), 2.1)
            XCTAssertLessThanOrEqual(preview.cache.bytes, 8 * 1024 * 1024)
            XCTAssertLessThanOrEqual(preview.cache.entries.count, 32)
            XCTAssertEqual(model.player.rate, playing ? 1 : 0)
            XCTAssertEqual(model.playbackRequested, playing)
            XCTAssertLessThanOrEqual(model.player.currentTime().seconds, before + Date().timeIntervalSince(started) + 0.5,
                "Preview generation must not seek the actual player")
            if !playing { XCTAssertEqual(model.player.currentTime().seconds, before, accuracy: 0.01) }
            model.pause()
            preview.hide()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNil(preview.image, "Late callbacks must not reopen a dismissed preview")
            preview.request(time: target, duration: model.duration)
            XCTAssertNotNil(preview.image, "A cached preview must not require another decode")
            preview.detach()
            XCTAssertTrue(preview.cache.entries.isEmpty)
            XCTAssertEqual(preview.cache.bytes, 0)
        }
        preview.attach(AVURLAsset(url: audio[0]))
        XCTAssertNil(preview.image)
        XCTAssertTrue(preview.cache.entries.isEmpty)
    }

    func testLocalHDPreviewsCoalesceRequestsAndLeavePlaybackUntouchedWhenProvided() async throws {
        try await verifyLocalPreview(environment: "SWIFTPLAYER_TEST_HD_MEDIA", repeats: 2)
    }
    func testLocal8KPreviewsAreSmallAndReleaseCachesAcrossRepeatedCloseWhenProvided() async throws {
        try await verifyLocalPreview(environment: "SWIFTPLAYER_TEST_MEDIA", repeats: 5)
    }
}
