import XCTest
import SwiftUI
import AppKit
@testable import SwiftPlayer

@MainActor
final class PlaybackFeatureTests: XCTestCase {
    func testJumpToTimeParsingRejectsMalformedAndOverflowingInputs() {
        for (input, expected) in [("90", 90.0), ("1:30", 90), ("1:02:03.5", 3723.5), (" 0:05 ", 5), ("0", 0)] {
            XCTAssertEqual(parsePlaybackTime(input), expected, input)
        }
        for input in ["", "-1", "1:", ":30", "1:60", "1:99:00", "1.5:20", "nan", "inf", "1e999", "1:2:3:4"] {
            XCTAssertNil(parsePlaybackTime(input), input)
        }
    }

    func testRecentBookmarksPersistResolveDeduplicateAndClear() throws {
        let suite = "SwiftPlayerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("First.mp4")
        let second = directory.appendingPathComponent("Second.mp4")
        try Data().write(to: first)
        try Data().write(to: second)
        let store = RecentMediaStore(defaults: defaults)
        store.record(first)
        store.record(second)
        store.record(first)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.name, "First.mp4")
        let restored = RecentMediaStore(defaults: defaults)
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(try restored.resolve(XCTUnwrap(restored.entries.first)).standardizedFileURL, first.standardizedFileURL)
        restored.clear()
        XCTAssertTrue(RecentMediaStore(defaults: defaults).entries.isEmpty)
    }

}
