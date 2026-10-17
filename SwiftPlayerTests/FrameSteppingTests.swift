import XCTest
import AVFoundation
import AppKit
@testable import SwiftPlayer

@MainActor
final class FrameSteppingTests: DebugMatrixTestCase {
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeated, keyCode: code))
    }

    func testControlArrowsRouteFramesSeparatelyFromSeekingAndReleaseHandlers() throws {
        let view = KeyEventHandlingView.KeyCatcherView()
        var steps: [Int] = []
        var seeks: [Int] = []
        view.onFrameStep = { steps.append($0) }
        view.onArrowDown = { direction, _ in seeks.append(direction) }
        view.keyDown(with: try key(123, flags: .control))
        view.keyDown(with: try key(124, flags: [.control, .capsLock]))
        view.keyDown(with: try key(124, flags: .control, repeated: true))
        for flags: NSEvent.ModifierFlags in [[.control, .option], [.control, .command], [.control, .shift], .option] {
            view.keyDown(with: try key(123, flags: flags))
        }
        XCTAssertEqual(steps, [-1, 1, 1])
        XCTAssertTrue(seeks.isEmpty)
        view.keyDown(with: try key(123))
        view.keyDown(with: try key(124))
        XCTAssertEqual(seeks, [-1, 1])
        var owner: NSObject? = NSObject()
        weak let released = owner
        view.onFrameStep = { [retained = owner] _ in _ = retained }
        owner = nil
        XCTAssertNotNil(released)
        KeyEventHandlingView.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.onFrameStep)
        XCTAssertNil(released)
    }

    func testUnsupportedAudioLoadingAndClosedMediaDoNotChangeTransport() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        XCTAssertFalse(model.canStepFrame(direction: 1))
        model.stepFrame(direction: 1)
        try await ready(model, paused: false)
        try await waitUntilCondition { model.isPlaying }
        XCTAssertFalse(model.canStepFrame(direction: -1))
        XCTAssertFalse(model.canStepFrame(direction: 1))
        let state = PlayerMenuState(model: model)
        model.stepFrame(direction: -1)
        model.stepFrame(direction: 1)
        XCTAssertTrue(model.playbackRequested)
        XCTAssertEqual(model.player.rate, 1)
        XCTAssertFalse(state.snapshot.canStepBackward)
        XCTAssertFalse(state.snapshot.canStepForward)
        model.teardown()
        model.stepFrame(direction: 1)
        assertClosed(model)
    }

    func testNativeStepsFollowVariableFrameTimestampsInBothDirectionsAndUpdateCaptions() async throws {
        let url = try await video()
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model, url: url)
        try await waitUntilCondition { model.canStepFrame(direction: 1) && model.canStepFrame(direction: -1) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        model.player.currentItem?.add(output)
        let positioned = await model.player.seek(to: CMTime(value: 30, timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(positioned)
        model.subtitleCues = [SubtitleCue(start: 31.0 / 30, end: 33.0 / 30, text: "Generated caption")]
        model.subtitlesEnabled = true
        for (direction, target) in [(1, 31.0 / 30), (1, 33.0 / 30), (-1, 31.0 / 30), (-1, 1.0)] {
            model.stepFrame(direction: direction)
            try await waitUntilCondition { abs(model.player.currentTime().seconds - target) < 0.001 }
            try await waitUntilCondition { abs(model.currentTime - target) < 0.001 }
            XCTAssertEqual(model.player.rate, 0)
            XCTAssertFalse(model.playbackRequested)
            XCTAssertEqual(model.currentSubtitleText, target == 31.0 / 30 ? "Generated caption" : "")
        }
        let state = PlayerMenuState(model: model)
        XCTAssertTrue(state.snapshot.canStepBackward)
        XCTAssertTrue(state.snapshot.canStepForward)
        model.stepFrame(direction: 0)
        model.stepFrame(direction: 2)
        XCTAssertEqual(model.player.currentTime().seconds, 1, accuracy: 0.001)
        for _ in 0..<3 { model.stepFrame(direction: 1) }
        try await waitUntilCondition { abs(model.player.currentTime().seconds - 34.0 / 30) < 0.001 }
    }

    func testStepPausesPlaybackAndCancelsHeldSeekingAndStaleSeeks() async throws {
        let url = try await video()
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model, url: url)
        try await waitUntilCondition { model.canStepFrame(direction: 1) }
        model.playbackRate = 1.5
        model.play()
        try await waitUntilCondition { model.player.currentTime().seconds > 0.1 }
        model.stepFrame(direction: 1)
        try await Task.sleep(for: .milliseconds(150))
        let pausedTime = model.player.currentTime().seconds
        XCTAssertFalse(model.playbackRequested)
        XCTAssertEqual(model.player.rate, 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.player.currentTime().seconds, pausedTime, accuracy: 0.001)
        XCTAssertEqual(model.playbackRate, 1.5)
        model.beginFastSeeking(direction: -1)
        model.seek(to: 1)
        model.stepFrame(direction: 1)
        try await Task.sleep(for: .milliseconds(200))
        let steppedTime = model.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(model.player.currentTime().seconds, steppedTime, accuracy: 0.001)
        XCTAssertEqual(model.currentTime, steppedTime, accuracy: 0.001)
        XCTAssertFalse(model.isFastSeeking)
        XCTAssertFalse(model.playbackRequested)
        model.load(url: audio[0])
        model.stepFrame(direction: 1)
        model.teardown()
        try await Task.sleep(for: .milliseconds(100))
        assertClosed(model)
    }

    func testNativeBoundaryStepsStayPausedAndDoNotRunAutomaticEndAction() async throws {
        let url = try await video()
        let suite = "FrameStep-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.afterPlayback = .repeatFile
        let model = PlayerModel(preferences: preferences)
        defer { model.teardown() }
        try await ready(model, url: url)
        try await waitUntilCondition { model.canStepFrame(direction: -1) }
        model.stepFrame(direction: -1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.001)
        let item = try XCTUnwrap(model.player.currentItem)
        let positioned = await model.player.seek(to: item.duration, toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(positioned)
        model.stepFrame(direction: 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(model.player.currentItem)
        XCTAssertFalse(model.playbackRequested)
        XCTAssertEqual(model.player.rate, 0)
        model.stepFrame(direction: -1)
        try await waitUntilCondition { model.player.currentTime().seconds < model.duration }
        XCTAssertFalse(model.playbackFinished)
    }

    func testLocal8KNativeFrameStepWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_MEDIA"] else { throw XCTSkip("Set optional local 8K media for native frame stepping") }
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model, url: URL(fileURLWithPath: path))
        try await waitUntilCondition { model.canStepFrame(direction: 1) && model.canStepFrame(direction: -1) }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        model.player.currentItem?.add(output)
        XCTAssertEqual(model.player.currentItem?.presentationSize.width, 8192)
        let item = try XCTUnwrap(model.player.currentItem)
        let tracks = try await item.asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: item.asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(samples)
        XCTAssertTrue(reader.startReading())
        var timestamps: [CMTime] = []
        for _ in 0..<128 {
            guard let sample = samples.copyNextSampleBuffer() else { break }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isNumeric, time.seconds >= 2 { timestamps.append(time) }
        }
        reader.cancelReading()
        timestamps.sort { CMTimeCompare($0, $1) < 0 }
        XCTAssertGreaterThan(timestamps.count, 2)
        guard timestamps.count > 2 else { return }
        let positioned = await model.player.seek(to: timestamps[1], toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(positioned)
        model.stepFrame(direction: 1)
        try await waitUntilCondition { abs(model.player.currentTime().seconds - timestamps[2].seconds) < 0.001 }
        model.stepFrame(direction: -1)
        try await waitUntilCondition { abs(model.player.currentTime().seconds - timestamps[1].seconds) < 0.001 }
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertFalse(model.playbackRequested)
    }

    private func video() async throws -> URL {
        let url = directory.appendingPathComponent("Generated.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 96, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let frame = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(frame, [])
            memset(CVPixelBufferGetBaseAddress(frame), Int32(index * 3), CVPixelBufferGetDataSize(frame))
            CVPixelBufferUnlockBaseAddress(frame, [])
            try await waitUntilCondition { input.isReadyForMoreMediaData }
            // Alternating one- and two-tick intervals prevent nominal-FPS stepping from passing.
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index + index / 2), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}
