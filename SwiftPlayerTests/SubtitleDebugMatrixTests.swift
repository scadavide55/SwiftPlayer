import XCTest
@testable import SwiftPlayer

@MainActor
final class SubtitleDebugMatrixTests: DebugMatrixTestCase {
    func test100SubtitleRounds() async throws {
        let names = ["srt-timing-text", "vtt-short-hours", "ass-fractions", "legacy-ssa", "encoding-newlines",
                     "cue-boundary-offset", "overlap-reference", "latest-load-wins", "overflow-hours", "input-limit-cancellation"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("subtitles", family * 10 + variant, "\(names[family]); input=\(variant)") {
                    let url = directory.appendingPathComponent("captions-\(family)-\(variant)")
                    let second = String(format: "%02d", variant + 1)
                    let end = String(format: "%02d", variant + 3)
                    switch family {
                    case 0, 1, 2, 3, 4:
                        let ext = ["srt", "vtt", "ass", "ssa", "srt"][family]
                        let file = url.appendingPathExtension(ext)
                        var text: String
                        switch family {
                        case 1:
                            let prefix = variant % 2 == 0 ? "" : "00:"
                            text = "WEBVTT\n\n\(prefix)00:\(second).250 --> \(prefix)00:\(end).750 align:start\n<b>Caption \(variant)</b>"
                        case 2, 3:
                            let layer = family == 3 ? "Marked=\(variant % 2)" : "\(variant)"
                            let fractions = variant % 2 == 0 ? ["25", "75"] : ["250", "750"]
                            text = "[Events]\nDialogue: \(layer),0:00:\(second).\(fractions[0]),0:00:\(end).\(fractions[1]),Default,,0,0,0,,{\\i1}Caption \(variant)"
                        default:
                            text = "1\n00:00:\(second),250 --> 00:00:\(end),750\n<i>Caption \(variant)</i>"
                        }
                        var encoding = String.Encoding.utf8
                        if family == 4 {
                            if variant % 3 == 0 { text = "\u{feff}" + text }
                            if variant % 3 == 1 { encoding = .utf16 }
                            if variant % 2 == 0 { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
                            else { text = text.replacingOccurrences(of: "\n", with: "\r") }
                        }
                        try text.write(to: file, atomically: true, encoding: encoding)
                        let cues = parseSubtitles(from: file)
                        XCTAssertEqual(cues.count, 1)
                        if let cue = cues.first {
                            XCTAssertEqual(cue.start, Double(variant + 1) + 0.25, accuracy: 0.0001)
                            XCTAssertEqual(cue.end, Double(variant + 3) + 0.75, accuracy: 0.0001)
                            XCTAssertEqual(cue.text, "Caption \(variant)")
                        }
                    case 5:
                        let model = PlayerModel()
                        let offset = Double(variant) - 5
                        model.subtitleCues = [SubtitleCue(start: 5, end: 6, text: "Before"), SubtitleCue(start: 6, end: 7, text: "After")]
                        model.subtitlesEnabled = true
                        model.subtitleOffset = offset
                        model.currentTime = 6 + offset
                        model.updateSubtitleDisplay()
                        XCTAssertEqual(model.currentSubtitleText, "After")
                        model.currentTime = 7 + offset
                        model.updateSubtitleDisplay()
                        XCTAssertEqual(model.currentSubtitleText, "")
                    case 6:
                        let model = PlayerModel()
                        let cues = (0..<((variant + 1) * 1_000)).map { index in
                            SubtitleCue(start: Double(index) / 10, end: Double(index) / 10 + (index % 7 == 0 ? 10 : 0.1), text: "Cue \(index)")
                        }
                        model.subtitleCues = cues.reversed()
                        model.subtitlesEnabled = true
                        for time in [Double(variant + 1) * 30, 0, 10.5, 1, 0.1] {
                            model.currentTime = time
                            model.updateSubtitleDisplay()
                            XCTAssertEqual(model.currentSubtitleText, cues.first { $0.start <= time && $0.end > time }?.text ?? "")
                        }
                    case 7:
                        let model = PlayerModel()
                        defer { model.teardown() }
                        let first = url.appendingPathExtension("srt")
                        let latest = url.appendingPathExtension("vtt")
                        try String(repeating: "1\n00:00:00,000 --> 00:00:02,000\nOld\n\n", count: (variant + 1) * 500)
                            .write(to: first, atomically: true, encoding: .utf8)
                        try "WEBVTT\n\n00:00.000 --> 00:02.000\nLatest \(variant)".write(to: latest, atomically: true, encoding: .utf8)
                        model.loadSubtitles(url: first)
                        try await settle(variant)
                        model.loadSubtitles(url: latest)
                        try await waitUntilCondition { model.currentSubtitleText == "Latest \(variant)" }
                        XCTAssertEqual(model.subtitleCues.count, 1)
                    case 8:
                        let file = url.appendingPathExtension("vtt")
                        let hours = String(repeating: "9", count: 20 + variant)
                        let start = variant % 2 == 0 ? "\(hours):00:01.000" : "00:00:01.000"
                        let end = variant % 2 == 0 ? "00:00:02.000" : "\(hours):00:02.000"
                        try "WEBVTT\n\n\(start) --> \(end)\nInvalid".write(to: file, atomically: true, encoding: .utf8)
                        XCTAssertTrue(parseSubtitles(from: file).isEmpty)
                    default:
                        let file = url.appendingPathExtension("srt")
                        try Data("1\n00:00:00,000 --> 00:00:02,000\nCaption".utf8).write(to: file)
                        let handle = try FileHandle(forWritingTo: file)
                        try handle.truncate(atOffset: UInt64(16 * 1024 * 1024 + variant + 1))
                        try handle.close()
                        XCTAssertTrue(parseSubtitles(from: file).isEmpty)
                        let worker = Task.detached {
                            try? await Task.sleep(for: .milliseconds(50))
                            return parseSubtitles(from: file)
                        }
                        worker.cancel()
                        let cues = await worker.value
                        XCTAssertTrue(cues.isEmpty)
                    }
                }
            }
        }
    }
}
