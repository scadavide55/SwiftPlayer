import XCTest
@testable import SwiftPlayer

@MainActor
final class SubtitleEncodingTests: DebugMatrixTestCase {
    private func subtitle(_ bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent("Generated.srt")
        var data = Data("1\n00:00:01,000 --> 00:00:05,000\n".utf8)
        data.append(contentsOf: bytes)
        try data.write(to: url)
        return url
    }

    func testKnownBig5GB18030AndShiftJISBytesDecodeCorrectly() throws {
        for (encoding, bytes, text) in [
            (SubtitleEncoding.big5, [UInt8(0xa4), 0xa4, 0xa4, 0xe5], "中文"),
            (.gb18030, [0xd6, 0xd0, 0xce, 0xc4], "中文"),
            (.shiftJIS, [0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea], "日本語")
        ] {
            let url = try subtitle(bytes)
            XCTAssertTrue(parseSubtitles(from: url).isEmpty, "Automatic must not guess an ambiguous legacy encoding")
            let cues = parseSubtitles(from: url, encoding: encoding)
            XCTAssertEqual(cues.count, 1)
            XCTAssertEqual(cues.first?.text, text)
        }
    }

    func testUnicodeBOMAndStrictUTF8RemainSupported() throws {
        let text = "1\n00:00:01,000 --> 00:00:05,000\nGenerated 中文\n"
        let url = directory.appendingPathComponent("Unicode.srt")
        try text.data(using: .utf16)?.write(to: url)
        XCTAssertEqual(parseSubtitles(from: url).first?.text, "Generated 中文")
        XCTAssertEqual(parseSubtitles(from: url, encoding: .utf16).first?.text, "Generated 中文")
        XCTAssertTrue(parseSubtitles(from: url, encoding: .utf8).isEmpty)
        try text.data(using: .utf8)?.write(to: url)
        XCTAssertEqual(parseSubtitles(from: url, encoding: .utf8).first?.text, "Generated 中文")
        XCTAssertTrue(parseSubtitles(from: url, encoding: .utf16).isEmpty)
    }

    func testOlderFileMemoryWithoutEncodingStillDecodes() throws {
        let old = Data(#"{"subtitleMode":"automatic","subtitleDelay":0}"#.utf8)
        let value = try JSONDecoder().decode(MediaFileMemory.self, from: old)
        XCTAssertNil(value.subtitleEncoding)
    }

    func testEncodingRestoresPerMediaAndFailedReloadKeepsWorkingCaptions() async throws {
        let suite = "SubtitleEncoding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        let model = PlayerModel(preferences: preferences)
        defer { model.teardown() }
        let url = try subtitle([0xa4, 0xa4, 0xa4, 0xe5])
        try await ready(model)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        model.loadSubtitles(url: url, encoding: .big5)
        try await waitUntilCondition { model.mediaControls.subtitleSelection == "external" }
        XCTAssertEqual(model.subtitleCues.first?.text, "中文")
        XCTAssertEqual(preferences.mediaMemory(for: audio[1])?.subtitleEncoding, .big5)
        model.reloadSubtitles(encoding: .utf8)
        try await waitUntilCondition { !model.hasPendingSubtitleLoad }
        XCTAssertEqual(model.subtitleCues.first?.text, "中文")
        XCTAssertEqual(model.mediaControls.externalSubtitleEncoding, .big5)
        model.teardown()
        try await ready(model)
        try await waitUntilCondition { model.mediaControls.subtitleSelection == "external" && !model.hasPendingSubtitleLoad }
        XCTAssertEqual(model.subtitleCues.first?.text, "中文")
        XCTAssertEqual(model.mediaControls.externalSubtitleEncoding, .big5)
        model.mediaControls.subtitleSelection = "off"
        model.reloadSubtitles(encoding: .big5)
        try await waitUntilCondition { !model.hasPendingSubtitleLoad }
        XCTAssertEqual(model.mediaControls.subtitleSelection, "off")
        XCTAssertEqual(model.player.rate, 0)
    }
}
