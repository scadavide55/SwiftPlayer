import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class PerFileSettingsTests: DebugMatrixTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: PlayerPreferences!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "PerFileSettings-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = PlayerPreferences(defaults: defaults)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        settings = nil
        defaults = nil
        try super.tearDownWithError()
    }

    func testFileSettingsAreBoundedNormalizedAndClearedWhenDisabled() throws {
        for index in 0..<120 {
            settings.saveMediaMemory(MediaFileMemory(subtitleMode: "off", subtitleDelay: Double(index)),
                for: directory.appendingPathComponent("file-\(index).mp4"))
        }
        let data = try XCTUnwrap(defaults.data(forKey: "mediaFileSettings"))
        let saved = try JSONDecoder().decode([String: StoredMediaFileMemory].self, from: data)
        XCTAssertEqual(saved.count, 100)
        XCTAssertTrue(saved.values.allSatisfy { $0.settings.subtitleDelay <= 30 })
        let url = audio[0]
        settings.saveMediaMemory(MediaFileMemory(audioOption: Data(count: 20 * 1024), subtitleMode: "invalid", subtitleDelay: .nan), for: url)
        XCTAssertNil(settings.mediaMemory(for: url)?.audioOption)
        XCTAssertEqual(settings.mediaMemory(for: url)?.subtitleMode, "automatic")
        XCTAssertEqual(settings.mediaMemory(for: url)?.subtitleDelay, 0)
        settings.rememberFileSettings = false
        XCTAssertNil(settings.mediaMemory(for: url))
        XCTAssertNil(defaults.data(forKey: "mediaFileSettings"))
    }

    func testSubtitleOffAndDelayRestoreAfterClosingAndReopening() async throws {
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        try await ready(model)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        model.mediaControls.subtitleSelection = "off"
        model.subtitleOffset = 1.25
        model.teardown()
        try await ready(model)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        XCTAssertEqual(model.mediaControls.subtitleSelection, "off")
        XCTAssertEqual(model.subtitleOffset, 1.25)
        XCTAssertFalse(model.playbackRequested)
    }

    func testExternalSubtitleBookmarkAndTimingRestoreAfterReopening() async throws {
        let subtitle = directory.appendingPathComponent("Generated.srt")
        try "1\n00:00:01,000 --> 00:00:05,000\nGenerated caption\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        try await ready(model)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        model.loadSubtitles(url: subtitle)
        try await waitUntilCondition { model.mediaControls.subtitleSelection == "external" }
        model.subtitleOffset = -0.5
        XCTAssertNotNil(settings.mediaMemory(for: audio[1])?.externalSubtitle)
        model.teardown()
        try await ready(model)
        try await waitUntilCondition { model.mediaControls.subtitleSelection == "external" && !model.subtitleCues.isEmpty }
        XCTAssertEqual(model.subtitleOffset, -0.5)
        XCTAssertEqual(model.mediaControls.externalSubtitleName, subtitle.lastPathComponent)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testNewerSubtitleSelectionWinsOverPendingMemoryRestoration() async throws {
        settings.saveMediaMemory(MediaFileMemory(subtitleMode: "off"), for: audio[0])
        let player = AVPlayer()
        let media = PlayerMediaControls(player: player, preferences: settings)
        defer { media.detach() }
        let item = AVPlayerItem(url: audio[0])
        media.attach(to: item, sourceURL: audio[0])
        media.subtitleSelection = "off"
        media.subtitleSelection = "automatic"
        try await waitUntilCondition { !media.isDiscovering }
        XCTAssertEqual(media.subtitleSelection, "automatic")
    }

    func testNativeAudioOptionRestoresWhenChapterFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_CHAPTER_MEDIA"] else {
            throw XCTSkip("Set the optional generated chapter fixture to test multiple audio tracks")
        }
        let source = URL(fileURLWithPath: path)
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        try await ready(model, url: source)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        let japanese = try XCTUnwrap(model.mediaControls.audioTracks.first { $0.language?.hasPrefix("ja") == true })
        model.mediaControls.audioSelection = japanese.id
        model.teardown()
        try await ready(model, url: source)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        let restored = model.mediaControls.audioTracks.first { $0.id == model.mediaControls.audioSelection }
        XCTAssertTrue(restored?.language?.hasPrefix("ja") == true)
    }
}
