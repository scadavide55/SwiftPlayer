import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class EndOfPlaybackTests: DebugMatrixTestCase {
    func testAllEndActionsPreserveTheirIntendedTransportAndPersist() async throws {
        let name = "EndActions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PlayerPreferences(defaults: defaults)
        XCTAssertEqual(settings.afterPlayback, .stay)
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        for action in EndOfPlaybackAction.allCases {
            settings.afterPlayback = action
            XCTAssertEqual(PlayerPreferences(defaults: defaults).afterPlayback, action)
            try await ready(model)
            let item = try XCTUnwrap(model.player.currentItem)
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            switch action {
            case .stay:
                XCTAssertTrue(model.playbackFinished)
                XCTAssertEqual(model.currentTime, model.duration)
                XCTAssertFalse(model.playbackRequested)
                XCTAssertNil(model.player.currentItem)
                XCTAssertFalse(model.currentFileName.isEmpty)
                model.play()
                try await waitUntilCondition { model.isPlaying }
                XCTAssertFalse(model.player.currentItem === item)
            case .repeatFile:
                try await waitUntilCondition { model.isPlaying }
                XCTAssertTrue(model.player.currentItem === item)
                XCTAssertFalse(model.playbackFinished)
                XCTAssertTrue(model.playbackRequested)

            }
        }
        try await ready(model)
    }

    func testStopReleasesItemAndSubtitleBuffersThenReloadsForPausedNavigation() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        weak var releasedItem = model.player.currentItem
        model.subtitleCues = [SubtitleCue(start: 0, end: 20, text: "Generated caption")]
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: model.player.currentItem)
        XCTAssertTrue(model.isFinishedUnloaded)
        XCTAssertNil(model.player.currentItem)
        XCTAssertTrue(model.subtitleCues.isEmpty)
        XCTAssertFalse(model.hasPendingSubtitleLoad)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(releasedItem)
        XCTAssertEqual(PlaybackDiagnosticSnapshot.capture(model).state, .finished)
        let end = model.duration
        XCTAssertEqual(model.skip(by: -5), end - 5)
        XCTAssertEqual(model.skip(by: -5), end - 10)
        try await waitUntilCondition { !model.isLoading && !model.isSeeking }
        XCTAssertEqual(model.player.currentTime().seconds, end - 10, accuracy: 0.125)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertFalse(model.playbackRequested)
        XCTAssertFalse(model.playbackFinished)
    }

    func testSpeedShortcutsApplyToPlayingAndPausedTransportAtBothLimits() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        for rate: Float in [0.05, 1, 1.25, 4] {
            model.playbackRate = rate
            XCTAssertEqual(model.player.rate, 0)
            model.play()
            XCTAssertEqual(model.player.rate, rate)
            model.adjustPlaybackSpeed(direction: 1)
            XCTAssertEqual(model.player.rate, min(rate + 0.05, 4), accuracy: 0.00001)
            model.pause()
            model.adjustPlaybackSpeed(direction: -1)
            XCTAssertEqual(model.player.rate, 0)
        }
    }

    func testNaturalEndRepeatsAndCanBeStoppedWithoutASecondClock() async throws {
        let name = "NaturalRepeat-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PlayerPreferences(defaults: defaults)
        settings.afterPlayback = .repeatFile
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        try await ready(model, url: audio[0])
        let item = try XCTUnwrap(model.player.currentItem)
        var ends = 0
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { ends += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        model.seek(to: model.duration - 0.15)
        model.play()
        try await waitUntilCondition { ends >= 1 && model.isPlaying && model.currentTime < 1 }
        model.pause()
        XCTAssertFalse(model.playbackRequested)
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertTrue(model.player.currentItem === item)
    }
}
