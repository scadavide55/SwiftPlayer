import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class MediaControlsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        suite = "SwiftPlayerTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suite) }

    private func wait(_ condition: () -> Bool, seconds: Double = 15) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { throw NSError(domain: "MediaControlsTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testPreferencesPersistAndNormalizeAppearance() {
        let settings = PlayerPreferences(defaults: defaults)
        settings.subtitleLanguage = "zh-Hant"
        settings.audioLanguage = "en"
        settings.rememberVolume = true
        settings.savedVolume = 0.35
        settings.savedMute = true
        settings.appearance.fontFamily = "Helvetica"
        settings.appearance.size = 1_000
        settings.appearance.backgroundOpacity = -1
        settings.appearance.color = "Yellow"
        settings.resumePlayback = true
        let restored = PlayerPreferences(defaults: defaults)
        XCTAssertEqual(restored.subtitleLanguage, "zh-Hant")
        XCTAssertEqual(restored.audioLanguage, "en")
        XCTAssertEqual(restored.savedVolume, 0.35, accuracy: 0.001)
        XCTAssertTrue(restored.savedMute)
        XCTAssertEqual(restored.appearance.fontFamily, "Helvetica")
        XCTAssertEqual(restored.appearance.size, 64)
        XCTAssertEqual(restored.appearance.backgroundOpacity, 0)
        XCTAssertEqual(restored.appearance.color, "Yellow")
        XCTAssertTrue(restored.resumePlayback)
        let model = PlayerModel(preferences: restored)
        XCTAssertEqual(model.player.volume, 0.35, accuracy: 0.001)
        XCTAssertTrue(model.player.isMuted)
        model.volume = 0.5
        XCTAssertEqual(restored.savedVolume, 0.5)
        XCTAssertFalse(restored.savedMute)
    }

    func testResumePositionsDiscardStartEndAndDisabledHistory() {
        let settings = PlayerPreferences(defaults: defaults)
        let url = URL(fileURLWithPath: "/fixture/video.mp4")
        settings.resumePlayback = true
        settings.savePosition(30, duration: 100, for: url)
        XCTAssertEqual(settings.resumeTime(for: url), 30)
        settings.savePosition(98, duration: 100, for: url)
        XCTAssertNil(settings.resumeTime(for: url))
        settings.savePosition(30, duration: 100, for: url)
        settings.resumePlayback = false
        settings.resumePlayback = true
        XCTAssertNil(settings.resumeTime(for: url))
        settings.savePosition(.nan, duration: 100, for: url)
        XCTAssertNil(settings.resumeTime(for: url))
    }

    func testExternalSelectionAndDetachClearAllFeatureState() {
        let model = PlayerModel()
        model.mediaControls.useExternalSubtitles(named: "Captions.srt")
        XCTAssertEqual(model.mediaControls.subtitleSelection, "external")
        model.teardown()
        XCTAssertTrue(model.mediaControls.externalSubtitleName.isEmpty)
        XCTAssertTrue(model.mediaControls.embeddedText.isEmpty)
        XCTAssertTrue(model.mediaControls.streams.isEmpty)
        XCTAssertTrue(model.mediaControls.chapters.isEmpty)
        XCTAssertFalse(model.mediaControls.isDiscovering)
    }

    func testLocalEmbeddedSubtitlesAndAudioAreSelectableWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else {
            throw XCTSkip("Provide the local HD track-selection fixture.")
        }
        let settings = PlayerPreferences(defaults: defaults)
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        model.load(url: URL(fileURLWithPath: path))
        model.pause()
        try await wait { model.player.currentItem?.status == .readyToPlay && !model.mediaControls.isDiscovering || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed)
        let controls = model.mediaControls
        XCTAssertTrue(controls.informationError.isEmpty)
        let full = try XCTUnwrap(controls.subtitleTracks.first { !$0.forcedOnly })
        let item = try XCTUnwrap(model.player.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), full.option)
        controls.subtitleSelection = "off"
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        controls.subtitleSelection = full.id
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), full.option)
        controls.useExternalSubtitles(named: "External.srt")
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        controls.subtitleSelection = "automatic"
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), full.option)
        let audio = try XCTUnwrap(controls.audioTracks.first)
        let loadedAudioGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let audioGroup = try XCTUnwrap(loadedAudioGroup)
        controls.audioSelection = audio.id
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: audioGroup), audio.option)
        XCTAssertTrue(controls.streams.contains { $0.kind == "Subtitle" && $0.codec == "tx3g" })
        XCTAssertTrue(controls.streams.contains { $0.kind == "Video" && $0.details.contains("1920") })
        // Find a timed text sample without reading or logging its dialogue.
        let tracks = try await item.asset.loadTracks(withMediaType: .subtitle)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var subtitleTime: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length: [UInt8] = [0, 0]
            guard CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: 2, destination: &length) == kCMBlockBufferNoErr else { continue }
            if length[0] != 0 || length[1] != 0 {
                subtitleTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds + 0.1
                break
            }
        }
        model.seek(to: try XCTUnwrap(subtitleTime))
        model.play()
        try await wait({ !controls.embeddedText.isEmpty }, seconds: 20)
        controls.subtitleSelection = "off"
        XCTAssertTrue(controls.embeddedText.isEmpty)
        model.teardown()
        XCTAssertTrue(controls.subtitleTracks.isEmpty)
        XCTAssertTrue(controls.audioTracks.isEmpty)
    }
}
