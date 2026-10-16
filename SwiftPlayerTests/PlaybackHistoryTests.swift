import XCTest
import AVFoundation
import Combine
@testable import SwiftPlayer

@MainActor
final class PlaybackHistoryTests: DebugMatrixTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "History-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try super.tearDownWithError()
    }

    func testProgressIsThrottledAndClearDisableOrRemoveInvalidateSessions() throws {
        var now = Date()
        let store = PlaybackHistoryStore(defaults: defaults, now: { now })
        let session = try XCTUnwrap(store.begin(audio[1], duration: 20))
        store.update(session, position: 8, duration: 20)
        XCTAssertEqual(store.entries.first?.position, 0)
        now.addTimeInterval(11)
        store.update(session, position: 8, duration: 20)
        XCTAssertEqual(store.entries.first?.continuePosition, 8)
        store.clear()
        store.update(session, position: 9, duration: 20, force: true)
        XCTAssertTrue(store.entries.isEmpty)
        let next = try XCTUnwrap(store.begin(audio[1], duration: 20))
        store.remove(try XCTUnwrap(store.entries.first))
        store.update(next, position: 10, duration: 20, force: true)
        XCTAssertTrue(store.entries.isEmpty)
        _ = store.begin(audio[1], duration: 20)
        store.enabled = false
        XCTAssertNil(store.begin(audio[0], duration: 12))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "playbackHistory"))
        XCTAssertFalse(PlaybackHistoryStore(defaults: defaults).enabled)
    }

    func testHistoryIsBoundedAndExpiredEntriesAreRemovedFromStorage() throws {
        var now = Date()
        let store = PlaybackHistoryStore(defaults: defaults, now: { now })
        for index in 0..<205 {
            let file = directory.appendingPathComponent("Generated-\(index).mp4")
            try Data().write(to: file)
            XCTAssertNotNil(store.begin(file, duration: 100))
            now.addTimeInterval(1)
        }
        XCTAssertEqual(store.entries.count, 200)
        XCTAssertEqual(store.entries.first?.name, "Generated-204.mp4")
        now.addTimeInterval(91 * 86_400)
        let restored = PlaybackHistoryStore(defaults: defaults, now: { now })
        XCTAssertTrue(restored.entries.isEmpty)
        let data = try XCTUnwrap(defaults.data(forKey: "playbackHistory"))
        XCTAssertTrue(try JSONDecoder().decode([PlaybackHistoryEntry].self, from: data).isEmpty)
    }

    func testInvalidStorageIsDiscardedAndUnavailableBookmarksFailWithoutDeletingEntries() throws {
        defaults.set(Data(count: 8 * 1024 * 1024 + 1), forKey: "playbackHistory")
        XCTAssertTrue(PlaybackHistoryStore(defaults: defaults).entries.isEmpty)
        XCTAssertNil(defaults.data(forKey: "playbackHistory"))
        let store = PlaybackHistoryStore(defaults: defaults)
        _ = store.begin(audio[0], duration: 12)
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(try store.resolve(entry).standardizedFileURL, audio[0].standardizedFileURL)
        try FileManager.default.removeItem(at: audio[0])
        XCTAssertThrowsError(try store.resolve(entry))
        XCTAssertEqual(store.entries.count, 1)
    }

    func testExplicitContinueRestoresPausedPositionWhenAutomaticResumeIsOff() async throws {
        let store = PlaybackHistoryStore(defaults: defaults)
        let preferences = PlayerPreferences(defaults: defaults)
        XCTAssertFalse(preferences.resumePlayback)
        let model = PlayerModel(preferences: preferences, history: store)
        defer { model.teardown() }
        model.load(url: audio[1], startAt: 10)
        model.pause()
        try await waitUntilCondition { abs(model.player.currentTime().seconds - 10) < 0.5 && (store.entries.first?.position ?? 0) >= 9.5 }
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertNil(preferences.resumeTime(for: audio[1]))
        model.teardown()
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertGreaterThanOrEqual(entry.continuePosition, 9.5)
        model.load(url: try store.resolve(entry), startAt: entry.continuePosition)
        model.pause()
        try await waitUntilCondition { abs(model.player.currentTime().seconds - entry.continuePosition) < 0.5 }
        XCTAssertEqual(model.player.rate, 0)
    }

    func testExplicitBeginningOverridesAutomaticResumeAndLatestLoadWins() async throws {
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.resumePlayback = true
        preferences.savePosition(10, duration: 20, for: audio[1])
        let model = PlayerModel(preferences: preferences)
        defer { model.teardown() }
        model.load(url: audio[1], startAt: 10)
        model.load(url: audio[1], startAt: 0)
        model.pause()
        try await waitUntilCondition { model.player.currentItem?.status == .readyToPlay && !model.isLoading }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testNaturalCompletionIsRememberedAndClearedHistoryStaysEmptyDuringPlayback() async throws {
        let store = PlaybackHistoryStore(defaults: defaults)
        let model = PlayerModel(history: store)
        defer { model.teardown() }
        try await ready(model)
        _ = await model.player.seek(to: CMTime(seconds: model.duration - 0.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        model.play()
        try await waitUntilCondition { model.playbackFinished }
        XCTAssertTrue(store.entries.first?.isFinished ?? false)
        XCTAssertEqual(store.entries.first?.continuePosition, 0)
        store.clear()
        model.play()
        model.pause()
        model.teardown()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testHistoryUpdatesDoNotInvalidateMenusOrRetainAClosedPlayer() async throws {
        let store = PlaybackHistoryStore(defaults: defaults)
        var model: PlayerModel? = PlayerModel(history: store)
        weak var released = model
        var menus: PlayerMenuState? = PlayerMenuState(model: model)
        try await ready(try XCTUnwrap(model))
        for _ in 0..<10 { await Task.yield() }
        var changes = 0
        let observation = try XCTUnwrap(menus).objectWillChange.sink { changes += 1 }
        let session = try XCTUnwrap(store.begin(audio[1], duration: 20))
        for index in 0..<100 {
            store.update(session, position: Double(index % 19), duration: 20, force: true)
            await Task.yield()
        }
        XCTAssertEqual(changes, 0)
        observation.cancel()
        model?.teardown()
        model = nil
        menus = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(released)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testRewindAndPauseAfterNaturalEndPreservesFinishedHistory() async throws {
        let store = PlaybackHistoryStore(defaults: defaults)
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.afterPlayback = .rewind
        let model = PlayerModel(preferences: preferences, history: store)
        defer { model.teardown() }
        try await ready(model)
        _ = await model.player.seek(to: CMTime(seconds: model.duration - 0.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        model.play()
        try await waitUntilCondition { model.player.rate == 0 && model.player.currentTime().seconds < 0.5 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.entries.first?.isFinished ?? false)
        XCTAssertEqual(store.entries.first?.progress ?? 0, 1, accuracy: 0.01)
        model.teardown()
        XCTAssertTrue(store.entries.first?.isFinished ?? false)
    }
}
