import XCTest
import AVFoundation
import Combine
import Darwin
@testable import SwiftPlayer

@MainActor
final class CoreDebugMatrixTests: DebugMatrixTestCase {
    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.25, 2.5, 3, 4]

    func test100SharedCoreRounds() async throws {
        let names = ["native-control-state", "latest-native-command", "internal-hold-intent", "close-pending-events",
                     "invalid-volume-preserves-mute", "subtitle-boundary-index", "escaped-caption-text",
                     "bounded-header-scan", "preparation-cancel-integrity", "real-media-ordinary-seek"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("core", family * 10 + variant, "\(names[family]); input=\(variant)") {
                    switch family {
                    case 0:
                        let model = PlayerModel()
                        defer { model.teardown() }
                        try await ready(model, paused: false)
                        try await waitUntilCondition { model.isPlaying }
                        model.player.pause()
                        try await waitUntilCondition { !model.playbackRequested && !model.isPlaying }
                        model.playbackRate = rates[variant]
                        try await settle(variant)
                        XCTAssertEqual(model.player.rate, 0)
                        model.player.rate = rates[variant]
                        try await waitUntilCondition { model.playbackRequested && model.isPlaying }
                        XCTAssertEqual(model.playbackRate, rates[variant])
                        model.togglePlayPause()
                        XCTAssertEqual(model.player.rate, 0)
                    case 1:
                        let model = PlayerModel()
                        defer { model.teardown() }
                        try await ready(model)
                        for index in 0...variant {
                            model.player.rate = rates[index]
                            model.player.pause()
                            model.play()
                        }
                        let playing = variant % 2 == 0
                        if playing { model.player.rate = rates[variant] }
                        else { model.player.pause() }
                        try await settle(variant)
                        try await waitUntilCondition { model.playbackRequested == playing }
                        XCTAssertEqual(model.player.rate, playing ? rates[variant] : 0)
                        if playing { XCTAssertEqual(model.playbackRate, rates[variant]) }
                    case 2:
                        let model = PlayerModel()
                        defer { model.teardown() }
                        let playing = variant % 3 != 0
                        try await ready(model, paused: !playing)
                        model.playbackRate = rates[variant]
                        model.seek(to: 7 + Double(variant) / 4)
                        let direction = variant % 2 == 0 ? -1 : 1
                        model.beginFastSeeking(direction: direction)
                        try await waitUntilCondition { model.isFastSeeking }
                        XCTAssertEqual(model.playbackRequested, playing)
                        XCTAssertEqual(model.playbackRate, rates[variant])
                        if direction < 0 || !playing { XCTAssertEqual(model.player.rate, 0) }
                        model.playbackRate = 0.5
                        model.endFastSeeking()
                        try await settle(variant)
                        XCTAssertEqual(model.playbackRequested, playing)
                        XCTAssertEqual(model.player.rate, playing ? 0.5 : 0)
                    case 3:
                        var model: PlayerModel? = PlayerModel()
                        let released: @MainActor @Sendable () -> Bool = { [weak model] in model == nil }
                        try await ready(try XCTUnwrap(model))
                        let player = try XCTUnwrap(model).player
                        let old = try XCTUnwrap(player.currentItem)
                        player.rate = rates[variant]
                        model?.seek(to: Double(variant + 1))
                        model?.load(url: audio[0])
                        try await settle(variant)
                        model?.teardown()
                        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: old)
                        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: old)
                        assertClosed(try XCTUnwrap(model))
                        model = nil
                        try await waitUntilCondition(released)
                        XCTAssertNil(player.currentItem)
                    case 4:
                        let model = PlayerModel()
                        let volume = Float(variant + 1) / 10
                        model.volume = volume
                        model.isMuted = true
                        let invalid: [Float] = [.nan, .infinity, -.infinity]
                        model.volume = invalid[variant % invalid.count]
                        XCTAssertEqual(model.volume, volume)
                        XCTAssertEqual(model.player.volume, volume)
                        XCTAssertTrue(model.isMuted)
                        XCTAssertTrue(model.player.isMuted)
                        model.volumeDown()
                        if model.volume > 0 { XCTAssertFalse(model.isMuted) }
                        model.player.volume = volume / 2
                        model.player.isMuted = true
                        try await waitUntilCondition { model.volume == volume / 2 && model.isMuted }
                        XCTAssertTrue(model.player.isMuted)
                        model.player.isMuted = false
                        try await waitUntilCondition { !model.isMuted }
                    case 5:
                        let model = PlayerModel()
                        let cues = (0..<((variant + 1) * 1_000)).map { index in
                            SubtitleCue(start: Double(index), end: Double(index + (index % 5 == 0 ? 9 : 1)), text: "Cue \(index)")
                        }
                        model.subtitleCues = cues.reversed()
                        model.subtitlesEnabled = true
                        model.subtitleOffset = Double(variant) - 5
                        for time in [Double(variant + 1) * 900, 5, 9, 0, 1, 10_020] {
                            model.currentTime = time + model.subtitleOffset
                            model.updateSubtitleDisplay()
                            XCTAssertEqual(model.currentSubtitleText, cues.first { $0.start <= time && $0.end > time }?.text ?? "")
                        }
                    case 6:
                        let samples = ["A &amp; B", "&lt;literal&gt;", "A&nbsp;B", "&lrm;Text", "Text&rlm;",
                                       "&gt; &lt; &amp;", "&amp;lt;", "<b>A &amp; B</b>", "&lt;b&gt;text&lt;/b&gt;", "A &unknown; B"]
                        let expected = ["A & B", "<literal>", "A\u{00a0}B", "\u{200e}Text", "Text\u{200f}",
                                        "> < &", "&lt;", "A & B", "<b>text</b>", "A &unknown; B"]
                        let url = directory.appendingPathComponent("escaped-\(variant).vtt")
                        try "WEBVTT\n\n00:00.000 --> 00:02.000\n\(samples[variant])".write(to: url, atomically: true, encoding: .utf8)
                        XCTAssertEqual(parseSubtitles(from: url).first?.text, expected[variant])
                    case 7:
                        let url = directory.appendingPathComponent("headers-\(variant).mp4")
                        let header = Data([0, 0, 0, 8, 102, 114, 101, 101])
                        var data = Data(capacity: (variant + 1) * 80_000)
                        for _ in 0..<((variant + 1) * 10_000) { data.append(header) }
                        try data.write(to: url)
                        let result = try await Task.detached { try HEVCCompatibility.prepare(url: url) }.value
                        XCTAssertEqual(result.url, url)
                        XCTAssertNil(result.temporaryDirectory)
                        XCTAssertEqual(try Data(contentsOf: url), data)
                    case 8:
                        let url = directory.appendingPathComponent("cancel-\(variant).mp4")
                        let data = Data(repeating: UInt8(variant), count: (variant + 1) * 1_024)
                        try data.write(to: url)
                        let worker = Task.detached {
                            try? await Task.sleep(for: .milliseconds(50 + variant))
                            return try HEVCCompatibility.prepare(url: url, allowClone: variant % 2 == 0)
                        }
                        worker.cancel()
                        do {
                            let result = try await worker.value
                            result.removeTemporaryFiles()
                            XCTFail("Canceled preparation must not return media.")
                        } catch is CancellationError { }
                        XCTAssertEqual(try Data(contentsOf: url), data)
                    default:
                        let use8K = variant % 2 == 0
                        let key = use8K ? "SWIFTPLAYER_TEST_MEDIA" : "SWIFTPLAYER_TEST_HD_MEDIA"
                        guard let path = ProcessInfo.processInfo.environment[key] else {
                            throw XCTSkip("The complete shared-core matrix requires local HD and 8K samples.")
                        }
                        let source = URL(fileURLWithPath: path)
                        let model = PlayerModel()
                        defer { model.teardown() }
                        model.load(url: source)
                        try await waitUntilCondition { model.player.currentItem != nil || model.playbackFailed }
                        XCTAssertFalse(model.playbackFailed)
                        let item = try XCTUnwrap(model.player.currentItem)
                        let loaded = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
                        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                        item.add(output)
                        var frame: CVPixelBuffer?
                        try await waitUntilCondition({
                            frame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
                            return frame != nil || model.playbackFailed
                        }, seconds: 20)
                        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame)), use8K ? 8192 : 1920)
                        frame = nil
                        let target = Double((variant + 1) * 15)
                        model.seek(to: target)
                        try await waitUntilCondition { abs(model.player.currentTime().seconds - target) < 5 || model.playbackFailed }
                        try await waitUntilCondition({
                            frame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
                            return frame != nil || model.playbackFailed
                        }, seconds: 20)
                        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame)), use8K ? 8192 : 1920)
                        model.player.pause()
                        try await waitUntilCondition { !model.playbackRequested }
                        model.teardown()
                        XCTAssertFalse(FileManager.default.fileExists(atPath: loaded.path))
                        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
                        assertClosed(model)
                    }
                }
            }
        }
    }
}
