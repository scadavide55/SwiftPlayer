import XCTest
import AppKit
import AVFoundation
import ImageIO
@testable import SwiftPlayer

@MainActor
final class FrameCaptureTests: DebugMatrixTestCase {
    private func dimensions(_ data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
                      height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    func testPNGRenderingIncludesStyledUnicodeCaptionsAndPreservesDimensions() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = try XCTUnwrap(context.makeImage())
        let plain = try FrameCaptureImage.png(image, caption: nil)
        for position in ["Top", "Center", "Bottom"] {
            let caption = FrameCaption(text: "Generated caption 中文 日本語", fontName: NSFont.systemFont(ofSize: 24).fontName,
                size: 24, color: "Yellow", outline: true, backgroundOpacity: 0.6, position: position, referenceHeight: 360)
            let data = try FrameCaptureImage.png(image, caption: caption)
            XCTAssertEqual(try dimensions(data), CGSize(width: 640, height: 360))
            XCTAssertNotEqual(data, plain, "The exported image must contain visible caption rendering")
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil)?.dataProvider?.data) as Data
            XCTAssertGreaterThan(pixels.filter { $0 > 100 && $0 < 255 }.count, 10, "Antialiased caption pixels must be present")
        }
    }

    private func setup(_ path: String) async throws -> (PlayerModel, PlayerPreferences, PlayerWindowControls, FrameCaptureController, NSPasteboard, String) {
        let suite = "Capture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = PlayerPreferences(defaults: defaults)
        let model = PlayerModel()
        let viewing = PlayerWindowControls()
        let board = NSPasteboard(name: NSPasteboard.Name("Capture-\(UUID().uuidString)"))
        let capture = FrameCaptureController(pasteboard: board)
        viewing.observe(model.player)
        capture.attach(model: model, preferences: preferences, viewing: viewing)
        try await ready(model, url: URL(fileURLWithPath: path))
        try await waitUntilCondition { viewing.hasVideo }
        return (model, preferences, viewing, capture, board, suite)
    }

    func testLocalHDCopyCaptionsAndFileExportLeavePlaybackUntouchedWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else { throw XCTSkip("Set optional local HD media for frame capture") }
        let (model, preferences, viewing, capture, board, suite) = try await setup(path)
        defer {
            capture.detach(); viewing.detach(); model.teardown(); board.releaseGlobally()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        _ = preferences
        let before = model.player.currentTime().seconds
        let item = model.player.currentItem
        capture.copyFrame()
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 30)
        XCTAssertNil(capture.errorMessage)
        let plain = try XCTUnwrap(board.data(forType: .png))
        XCTAssertEqual(try dimensions(plain), CGSize(width: 1920, height: 1080))
        model.subtitleCues = [SubtitleCue(start: 0, end: 20, text: "Generated caption 中文")]
        model.subtitlesEnabled = true
        model.mediaControls.useExternalSubtitles(named: "Generated.srt")
        model.updateSubtitleDisplay()
        capture.includeSubtitles = true
        capture.copyFrame()
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 30)
        let captioned = try XCTUnwrap(board.data(forType: .png))
        XCTAssertTrue(captioned != plain, "Enabling captions must change the exported image")
        let file = directory.appendingPathComponent("Frame.png")
        capture.capture(to: file)
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(capture.statusMessage, "Frame saved")
        XCTAssertTrue(model.player.currentItem === item)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.player.currentTime().seconds, before, accuracy: 0.001)
    }

    func testLocal8KExportAndCancelPreserveClipboardAndReleaseControllerWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_MEDIA"] else { throw XCTSkip("Set optional local 8K media for frame capture") }
        let suite = "Capture-\(UUID().uuidString)"
        let preferences = PlayerPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let model = PlayerModel()
        let viewing = PlayerWindowControls()
        let board = NSPasteboard(name: NSPasteboard.Name("Capture-\(UUID().uuidString)"))
        var capture: FrameCaptureController? = FrameCaptureController(pasteboard: board)
        weak var released = capture
        viewing.observe(model.player)
        capture?.attach(model: model, preferences: preferences, viewing: viewing)
        defer {
            capture?.detach(); viewing.detach(); model.teardown(); board.releaseGlobally()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try await ready(model, url: URL(fileURLWithPath: path))
        try await waitUntilCondition { viewing.hasVideo }
        model.play()
        try await waitUntilCondition { model.isPlaying }
        let before = model.player.currentTime().seconds
        let started = Date()
        let file = directory.appendingPathComponent("Frame.png")
        capture?.capture(to: file)
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 60)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 8192)
        XCTAssertNil(capture?.errorMessage)
        XCTAssertEqual(model.player.rate, 1)
        XCTAssertTrue(model.playbackRequested)
        XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, before)
        XCTAssertLessThanOrEqual(model.player.currentTime().seconds, before + Date().timeIntervalSince(started) + 0.5)
        board.clearContents(); board.setString("Existing clipboard", forType: .string)
        capture?.copyFrame()
        capture?.cancel()
        model.teardown()
        capture = nil
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 30)
        XCTAssertEqual(board.string(forType: .string), "Existing clipboard")
        XCTAssertNil(board.data(forType: .png))
        XCTAssertNil(released)
    }

    func testTwoWindowsCannotAllocateFullResolutionCapturesConcurrentlyWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else { throw XCTSkip("Set optional local HD media for capture coordination") }
        let first = try await setup(path)
        let second = try await setup(path)
        defer {
            for environment in [first, second] {
                environment.3.detach(); environment.2.detach(); environment.0.teardown(); environment.4.releaseGlobally()
                UserDefaults(suiteName: environment.5)?.removePersistentDomain(forName: environment.5)
            }
        }
        second.4.clearContents(); second.4.setString("Existing clipboard", forType: .string)
        first.3.capture(to: directory.appendingPathComponent("First.png"))
        XCTAssertTrue(FrameCaptureCoordinator.shared.isBusy)
        second.3.copyFrame()
        XCTAssertFalse(second.3.isCapturing)
        XCTAssertNotNil(second.3.errorMessage)
        XCTAssertEqual(second.4.string(forType: .string), "Existing clipboard")
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 30)
        XCTAssertEqual(first.3.statusMessage, "Frame saved")
        second.3.copyFrame()
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 30)
        XCTAssertNil(second.3.errorMessage)
        XCTAssertNotNil(second.4.data(forType: .png))
    }

    func testCapturingAtEndUsesLastVideoFrameWithoutSeekingWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else { throw XCTSkip("Set optional local HD media for end-frame capture") }
        let (model, preferences, viewing, capture, board, suite) = try await setup(path)
        defer {
            capture.detach(); viewing.detach(); model.teardown(); board.releaseGlobally()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        _ = preferences
        let end = model.duration
        let sought = await model.player.seek(to: CMTime(seconds: end, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)
        let before = model.player.currentTime().seconds
        capture.copyFrame()
        try await waitUntilCondition({ !FrameCaptureCoordinator.shared.isBusy }, seconds: 30)
        XCTAssertNil(capture.errorMessage)
        XCTAssertNotNil(board.data(forType: .png), "The final displayed frame must be exportable")
        XCTAssertEqual(model.player.currentTime().seconds, before, accuracy: 0.001)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testAudioOnlyCopyDoesNotReplaceClipboardAndControllerIsReleased() async throws {
        let model = PlayerModel()
        let preferences = PlayerPreferences(defaults: .standard)
        let viewing = PlayerWindowControls()
        let board = NSPasteboard(name: NSPasteboard.Name("Capture-\(UUID().uuidString)"))
        var capture: FrameCaptureController? = FrameCaptureController(pasteboard: board)
        weak var released = capture
        defer { viewing.detach(); model.teardown(); board.releaseGlobally() }
        capture?.attach(model: model, preferences: preferences, viewing: viewing)
        viewing.observe(model.player)
        try await ready(model)
        board.clearContents(); board.setString("Existing clipboard", forType: .string)
        capture?.copyFrame()
        XCTAssertFalse(capture?.isCapturing ?? true)
        XCTAssertEqual(board.string(forType: .string), "Existing clipboard")
        capture = nil
        XCTAssertNil(released)
    }
}
