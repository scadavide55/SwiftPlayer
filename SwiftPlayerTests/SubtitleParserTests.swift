import XCTest
@testable import SwiftPlayer

@MainActor
final class SubtitleParserTests: XCTestCase {

    /// Writes `contents` to a temporary file with the given extension and parses it,
    /// which exercises the extension dispatch as well as the individual parsers.
    private func parse(_ contents: String, as ext: String) throws -> [SubtitleCue] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return parseSubtitles(from: url)
    }

    // MARK: - SRT

    func testSRTParsesTimestampsAndMultilineText() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello <i>world</i>

        2
        00:01:02,250 --> 00:01:04,750
        Line one
        Line two
        """
        let cues = try parse(srt, as: "srt")

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.0001)
        XCTAssertEqual(cues[0].text, "Hello world")
        XCTAssertEqual(cues[1].start, 62.25, accuracy: 0.0001)
        XCTAssertEqual(cues[1].end, 64.75, accuracy: 0.0001)
        XCTAssertEqual(cues[1].text, "Line one\nLine two")
    }

    // MARK: - VTT

    func testVTTSkipsHeaderAndStripsTags() throws {
        let vtt = """
        WEBVTT

        00:00:00.500 --> 00:00:02.000
        First cue

        00:00:03.000 --> 00:00:04.250
        Second <b>cue</b>
        """
        let cues = try parse(vtt, as: "vtt")

        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 2.0, accuracy: 0.0001)
        XCTAssertEqual(cues[1].start, 3.0, accuracy: 0.0001)
        XCTAssertEqual(cues[1].end, 4.25, accuracy: 0.0001)
        XCTAssertEqual(cues[1].text, "Second cue")
    }

    func testVTTAcceptsCommaSeparatedTimestamps() throws {
        let vtt = """
        WEBVTT

        00:00:01,500 --> 00:00:02,500
        Comma form
        """
        let cues = try parse(vtt, as: "vtt")

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.5, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 2.5, accuracy: 0.0001)
    }

    // MARK: - ASS / SSA

    func testASSParsesCentisecondsOverrideBlocksAndLineBreaks() throws {
        let ass = """
        [Script Info]
        Title: Test

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\i1}Hello{\\i0}\\NSecond line
        """
        let cues = try parse(ass, as: "ass")

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.0001)
        XCTAssertEqual(cues[0].text, "Hello\nSecond line")
    }

    /// The fractional field is centiseconds in the canonical `H:MM:SS.cc` form but
    /// milliseconds in the 3-digit `H:MM:SS.mmm` form. Both must scale correctly.
    func testASSScalesThreeDigitFractionsAsMilliseconds() throws {
        let ass = """
        [Events]
        Dialogue: 0,0:00:01.250,0:00:03.750,Default,,0,0,0,,Millisecond form
        """
        let cues = try parse(ass, as: "ass")

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.25, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 3.75, accuracy: 0.0001)
        XCTAssertEqual(cues[0].text, "Millisecond form")
    }

    func testASSPreservesCommasInsideCueText() throws {
        let ass = """
        [Events]
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,One, two, three
        """
        let cues = try parse(ass, as: "ass")

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "One, two, three")
    }

    func testSSAUsesSameParserAsASS() throws {
        let ssa = """
        [Events]
        Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,SSA cue
        """
        let cues = try parse(ssa, as: "ssa")

        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 5.0, accuracy: 0.0001)
    }

    // MARK: - Dispatch / helpers

    func testUnsupportedExtensionReturnsNoCues() throws {
        XCTAssertTrue(try parse("not a subtitle file", as: "txt").isEmpty)
    }

    func testMalformedSubtitleReturnsNoCues() throws {
        XCTAssertTrue(try parse("no timestamps here at all", as: "srt").isEmpty)
    }

    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(65), "1:05")
        XCTAssertEqual(formatTime(3661), "1:01:01")
        XCTAssertEqual(formatTime(.infinity), "0:00")
        XCTAssertEqual(formatTime(-5), "0:00")
    }
}
