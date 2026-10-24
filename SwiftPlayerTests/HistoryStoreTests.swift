import XCTest
@testable import SwiftPlayer

@MainActor
final class HistoryStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HistoryStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    func testRecordMovesExistingEntryToTopAndKeepsPosition() {
        let store = HistoryStore(defaults: defaults)
        let first = store.record(url: url("a.mp4"))
        store.updatePosition(id: first.id, position: 42, duration: 100)
        store.record(url: url("b.mp4"))
        store.record(url: url("a.mp4"))

        XCTAssertEqual(store.entries.map(\.name), ["a.mp4", "b.mp4"])
        XCTAssertEqual(store.entries[0].id, first.id)
        XCTAssertEqual(store.entries[0].position, 42)
    }

    func testEntriesAreCappedAtMaximum() {
        let store = HistoryStore(defaults: defaults)
        for i in 0..<(HistoryStore.maxEntries + 5) {
            store.record(url: url("f\(i).mp4"))
        }

        XCTAssertEqual(store.entries.count, HistoryStore.maxEntries)
        XCTAssertEqual(store.entries.first?.name, "f\(HistoryStore.maxEntries + 4).mp4")
    }

    func testEntriesPersistAcrossInstances() {
        let store = HistoryStore(defaults: defaults)
        let entry = store.record(url: url("a.mp4"))
        store.updatePosition(id: entry.id, position: 30, duration: 90)

        let reloaded = HistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].position, 30)
        XCTAssertEqual(reloaded.entries[0].duration, 90)
    }

    func testResumePositionRules() {
        let store = HistoryStore(defaults: defaults)
        var entry = store.record(url: url("a.mp4"))

        entry.position = 2
        entry.duration = 100
        XCTAssertNil(store.resumePosition(for: entry), "too close to the start")

        entry.position = 50
        XCTAssertEqual(store.resumePosition(for: entry), 50)

        entry.position = 95
        XCTAssertNil(store.resumePosition(for: entry), "too close to the end")
    }

    func testRemoveAndClear() {
        let store = HistoryStore(defaults: defaults)
        let a = store.record(url: url("a.mp4"))
        store.record(url: url("b.mp4"))

        store.remove(id: a.id)
        XCTAssertEqual(store.entries.map(\.name), ["b.mp4"])

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(HistoryStore(defaults: defaults).entries.isEmpty)
    }
}
