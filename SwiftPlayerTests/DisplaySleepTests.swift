import XCTest
@testable import SwiftPlayer

@MainActor
final class DisplaySleepTests: DebugMatrixTestCase {
    func testOnlyPlayingVideoAcquiresOneActivityAndPauseReleasesIt() {
        var starts = 0
        weak var lease: NSObject?
        let controller = DisplaySleepController {
            starts += 1
            let token = NSObject()
            lease = token
            return token
        }
        controller.update(playing: true, hasVideo: false, enabled: true)
        controller.update(playing: false, hasVideo: true, enabled: true)
        controller.update(playing: true, hasVideo: true, enabled: false)
        XCTAssertEqual(starts, 0)
        for _ in 0..<20 { controller.update(playing: true, hasVideo: true, enabled: true) }
        XCTAssertEqual(starts, 1)
        XCTAssertNotNil(lease)
        controller.update(playing: false, hasVideo: true, enabled: true)
        XCTAssertNil(lease)
        XCTAssertFalse(controller.isPreventingSleep)
    }

    func testWindowsKeepIndependentActivitiesAndClosingReleasesEach() {
        let first = DisplaySleepController()
        let second = DisplaySleepController()
        first.update(playing: true, hasVideo: true, enabled: true)
        second.update(playing: true, hasVideo: true, enabled: true)
        first.detach()
        XCTAssertFalse(first.isPreventingSleep)
        XCTAssertTrue(second.isPreventingSleep)
        second.detach()
        XCTAssertFalse(second.isPreventingSleep)
    }

    func testControllerDeallocationReleasesActivity() {
        weak var lease: NSObject?
        var controller: DisplaySleepController? = DisplaySleepController {
            let token = NSObject(); lease = token; return token
        }
        controller?.update(playing: true, hasVideo: true, enabled: true)
        XCTAssertNotNil(lease)
        controller = nil
        XCTAssertNil(lease)
    }

    func testPreferencePersistsAndAudioPlaybackDoesNotPreventDisplaySleep() async throws {
        let suite = "DisplaySleep-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        XCTAssertTrue(preferences.keepDisplayAwake)
        preferences.keepDisplayAwake = false
        XCTAssertFalse(PlayerPreferences(defaults: defaults).keepDisplayAwake)
        preferences.keepDisplayAwake = true
        let model = PlayerModel()
        let controller = DisplaySleepController()
        defer { controller.detach(); model.teardown() }
        controller.attach(model: model, preferences: preferences)
        try await ready(model)
        model.play()
        try await waitUntilCondition { model.isPlaying && !model.mediaControls.isDiscovering }
        XCTAssertFalse(controller.isPreventingSleep)
    }

    func testNativeVideoPauseReplacementAndPreferenceReleaseWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else {
            throw XCTSkip("Set optional local HD media for display activity integration")
        }
        let suite = "DisplaySleep-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        let model = PlayerModel()
        let controller = DisplaySleepController()
        defer { controller.detach(); model.teardown() }
        controller.attach(model: model, preferences: preferences)
        try await ready(model, url: URL(fileURLWithPath: path))
        XCTAssertFalse(controller.isPreventingSleep)
        model.play()
        try await waitUntilCondition { controller.isPreventingSleep }
        model.pause()
        try await waitUntilCondition { !controller.isPreventingSleep }
        model.play()
        try await waitUntilCondition { controller.isPreventingSleep }
        preferences.keepDisplayAwake = false
        try await waitUntilCondition { !controller.isPreventingSleep }
        preferences.keepDisplayAwake = true
        try await waitUntilCondition { controller.isPreventingSleep }
        try await ready(model)
        try await waitUntilCondition { !controller.isPreventingSleep }
        model.teardown()
        XCTAssertFalse(controller.isPreventingSleep)
    }
}
