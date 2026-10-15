import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class SubtitleWorkflowTests: DebugMatrixTestCase {
    func testUnreadableNewFileKeepsPreviouslyLoadedSubtitles() async throws {
        let valid = directory.appendingPathComponent("Generated.srt")
        try "1\n00:00:01,000 --> 00:00:05,000\nGenerated caption\n".write(to: valid, atomically: true, encoding: .utf8)
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        model.loadSubtitles(url: valid)
        try await waitUntilCondition { model.mediaControls.subtitleSelection == "external" }
        model.loadSubtitles(url: directory.appendingPathComponent("Missing.srt"))
        try await waitUntilCondition { !model.mediaControls.subtitleStatusMessage.isEmpty }
        XCTAssertEqual(model.subtitleCues.count, 1)
        XCTAssertTrue(model.subtitlesEnabled)
        XCTAssertEqual(model.mediaControls.externalSubtitleName, valid.lastPathComponent)
        XCTAssertEqual(model.mediaControls.subtitleSelection, "external")
    }
}
