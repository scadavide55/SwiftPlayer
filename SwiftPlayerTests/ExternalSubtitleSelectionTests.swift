import XCTest
@testable import SwiftPlayer

@MainActor
final class ExternalSubtitleSelectionTests: XCTestCase {
    func testLateExternalLoadKeepsTheUsersNewerOffSelection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        try "1\n00:00:00,000 --> 00:00:02,000\nFixture caption\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PlayerModel()
        defer { model.teardown() }
        model.loadSubtitles(url: url)
        model.mediaControls.subtitleSelection = "off"
        let deadline = Date().addingTimeInterval(5)
        while model.subtitleCues.isEmpty {
            guard Date() < deadline else { return XCTFail("External subtitle loading did not finish.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.mediaControls.subtitleSelection, "off")
        XCTAssertEqual(model.mediaControls.externalSubtitleName, url.lastPathComponent)
        model.mediaControls.subtitleSelection = "external"
        model.currentTime = 1
        model.updateSubtitleDisplay()
        XCTAssertEqual(model.currentSubtitleText, "Fixture caption")
    }
}
