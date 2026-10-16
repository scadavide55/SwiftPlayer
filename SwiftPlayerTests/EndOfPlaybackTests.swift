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
            case .rewind:
                try await waitUntilCondition { model.player.currentTime().seconds < 0.1 }
                XCTAssertEqual(model.currentTime, 0, accuracy: 0.1)
                XCTAssertEqual(model.player.rate, 0)
                XCTAssertFalse(model.playbackRequested)
            case .repeatFile:
                try await waitUntilCondition { model.isPlaying }
                XCTAssertTrue(model.player.currentItem === item)
                XCTAssertFalse(model.playbackFinished)
                XCTAssertTrue(model.playbackRequested)
            case .close:
                XCTAssertTrue(model.closedAtEnd)
                XCTAssertNil(model.player.currentItem)
                XCTAssertFalse(model.playbackRequested)
                XCTAssertTrue(model.currentFileName.isEmpty)
            }
        }
        try await ready(model)
        XCTAssertFalse(model.closedAtEnd)
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
