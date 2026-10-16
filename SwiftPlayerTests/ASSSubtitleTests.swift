import XCTest
import CoreGraphics
@testable import SwiftPlayer

@MainActor
final class ASSSubtitleTests: DebugMatrixTestCase {
    private func script(_ dialogue: String) -> String {
        """
        [Script Info]
        PlayResX: 320
        PlayResY: 180
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, BackColour, Bold, Italic, Underline, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
        Style: Default,Arial,24,&H000000FF,&H00000000,&H80000000,-1,0,0,1,1,0,2,10,10,10
        Style: Green,Arial,24,&H0000FF00,&H00000000,&H80000000,0,-1,0,1,1,0,7,10,10,10
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(dialogue)
        """
    }
    private func event(_ text: String, layer: Int = 0, style: String = "Default") -> String {
        "Dialogue: \(layer),0:00:01.00,0:00:05.00,\(style),,0,0,0,,\(text)"
    }
    private func pixels(_ frame: SubtitleImageFrame) throws -> Data {
        try XCTUnwrap(frame.parts.first?.image.dataProvider?.data) as Data
    }
    private func alphaTotal(_ frame: SubtitleImageFrame) throws -> Int {
        let data = try pixels(frame)
        return stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + Int(data[$1]) }
    }

    func testASSFormatsStylesInlineRunsUnicodeAndSSAAlignment() throws {
        let cues = ASSSubtitleParser.parse(script(event("{\\an7\\pos(20,30)\\fs30\\i1}Generated {\\c&H00FF00&\\u1}中文\\Ncaption\\htext")))
        let cue = try XCTUnwrap(cues.first), ass = try XCTUnwrap(cue.styled)
        XCTAssertEqual(cue.text, "Generated 中文\ncaption\u{00a0}text")
        XCTAssertEqual(ass.canvas, CGSize(width: 320, height: 180))
        XCTAssertEqual(ass.position, CGPoint(x: 20, y: 30))
        XCTAssertEqual(ass.style.alignment, 7)
        XCTAssertEqual(ass.runs.first?.style.size, 30)
        XCTAssertEqual(ass.runs.first?.style.italic, true)
        XCTAssertEqual(ass.runs.last?.style.underline, true)
        XCTAssertEqual(ass.runs.last?.style.primary, ASSColor(red: 0, green: 1, blue: 0))
        let reordered = "[Events]\nFormat: Start, End, Layer, Style, Text\nDialogue: 0:00:01.00,0:00:02.00,2,Default,Text, with comma"
        XCTAssertEqual(ASSSubtitleParser.parse(reordered).first?.text, "Text, with comma")
        let ssa = "[V4 Styles]\nFormat: Name, Fontname, Fontsize, Alignment\nStyle: Default,Arial,20,6\n[Events]\n" + event("Caption")
        XCTAssertEqual(ASSSubtitleParser.parse(ssa).first?.styled?.style.alignment, 8)
    }

    func testColorsAndMalformedInputAreBoundedAndEffectsAreFlagged() throws {
        XCTAssertEqual(ASSColor.parse("&H800000FF")?.red, 1)
        XCTAssertEqual(try XCTUnwrap(ASSColor.parse("&H800000FF")).alpha, 127.0 / 255, accuracy: 0.00001)
        XCTAssertNil(ASSColor.parse("&Hnot-a-color"))
        let bad = script("Dialogue: 0,999999999999999999999:00:00.00,0:00:02.00,Default,,0,0,0,,No\n" + event("{\\p1}m 0 0 l 5 5{\\p0}Readable {\\kf20}caption"))
        let cues = ASSSubtitleParser.parse(bad)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.text, "Readable caption")
        XCTAssertEqual(cues.first?.styled?.hasUnsupportedEffects, true)
        let extreme = ASSSubtitleParser.parse(script(event("{\\fsnan\\pos(inf,0)}Safe", layer: Int.max)))
        XCTAssertLessThanOrEqual(try XCTUnwrap(extreme.first?.styled?.layer), 100_000)
        XCTAssertGreaterThan(try alphaTotal(ASSSubtitleRenderer.render(extreme.compactMap(\.styled), at: 2)), 0)
        XCTAssertEqual(ASSSubtitleParser.parse(script(event("{unclosed"))).first?.text, "{unclosed")
    }

    func testMalformedOverrideArgumentsCannotBecomeDifferentValidEffects() throws {
        for tag in ["pos(10,bad,20)", "pos(10,,20)", "pos(10,20,)",
                    "move(10,20,bad,30,40)", "move(10,20,30,40,,500,1000)",
                    "fad(100,bad,200)", "fad(100,,200)"] {
            let cue = try XCTUnwrap(ASSSubtitleParser.parse(script(event("{\\\(tag)}Caption"))).first)
            let styled = try XCTUnwrap(cue.styled)
            XCTAssertNil(styled.position, tag)
            XCTAssertNil(styled.motion, tag)
            XCTAssertEqual(styled.fadeIn, 0, tag)
            XCTAssertEqual(styled.fadeOut, 0, tag)
            XCTAssertTrue(styled.hasUnsupportedEffects, tag)
            XCTAssertEqual(cue.text, "Caption")
        }
        let valid = try XCTUnwrap(ASSSubtitleParser.parse(script(event("{\\pos(10, 20)\\fad(100, 200)}Caption"))).first?.styled)
        XCTAssertEqual(valid.position, CGPoint(x: 10, y: 20))
        XCTAssertEqual(valid.fadeIn, 0.1)
        XCTAssertEqual(valid.fadeOut, 0.2)
        XCTAssertFalse(valid.hasUnsupportedEffects)
    }

    func testNativeRenderingHonorsColorsPositionMotionFadeAndLayerOrder() throws {
        let staticEvents = ASSSubtitleParser.parse(script(event("{\\an7\\pos(20,30)}Generated caption"))).compactMap(\.styled)
        let image = try ASSSubtitleRenderer.render(staticEvents, at: 2)
        XCTAssertGreaterThan(try alphaTotal(image), 0)
        XCTAssertEqual(image.parts.first?.image.width, 320)
        let data = try pixels(image)
        XCTAssertGreaterThan(stride(from: 0, to: data.count, by: 4).filter { data[$0] > data[$0 + 1] + min(20, 255 - data[$0 + 1]) }.count, 10)
        let animated = ASSSubtitleParser.parse(script(event("{\\an7\\move(10,20,180,90)\\fad(1000,1000)}Moving caption"))).compactMap(\.styled)
        let early = try ASSSubtitleRenderer.render(animated, at: 1.1)
        let later = try ASSSubtitleRenderer.render(animated, at: 2)
        XCTAssertLessThan(try alphaTotal(early), try alphaTotal(later))
        XCTAssertNotEqual(try pixels(ASSSubtitleRenderer.render(animated, at: 2)), try pixels(ASSSubtitleRenderer.render(animated, at: 3)))
        let red = event("{\\pos(160,90)}Layer", layer: 0)
        let green = event("{\\pos(160,90)}Layer", layer: 1, style: "Green")
        XCTAssertNotEqual(try pixels(ASSSubtitleRenderer.render(ASSSubtitleParser.parse(script(red)).compactMap(\.styled), at: 2)),
                          try pixels(ASSSubtitleRenderer.render(ASSSubtitleParser.parse(script(red + "\n" + green)).compactMap(\.styled), at: 2)))
        if ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_SUBTITLE_ARTIFACTS"] == "1" {
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.15, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            let background = try XCTUnwrap(context.makeImage())
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Generated-ASS.png")
            try FrameCaptureImage.png(background, caption: nil, subtitles: image).write(to: file)
            print("SUBTITLE_ARTIFACT|\(file.path)")
        }
    }

    func testModelOverlapsStylePreferenceDelayPausedAnimationAndClose() async throws {
        let suite = "ASS-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        let model = PlayerModel(preferences: preferences)
        defer { model.teardown() }
        try await ready(model)
        let url = directory.appendingPathComponent("Generated.ass")
        try script(event("{\\an7\\pos(20,30)}First") + "\n" + event("{\\an7\\move(20,80,100,80)}Second", layer: 1)).write(to: url, atomically: true, encoding: .utf8)
        model.loadSubtitles(url: url)
        try await waitUntilCondition { !model.hasPendingSubtitleLoad }
        model.currentTime = 2; model.updateSubtitleDisplay()
        try await waitUntilCondition { model.currentSubtitleImage != nil }
        let id = model.currentSubtitleImage?.id
        model.updateSubtitleDisplay()
        XCTAssertEqual(model.currentSubtitleImage?.id, id)
        preferences.useSubtitleFileStyles = false
        try await waitUntilCondition { model.currentSubtitleImage == nil }
        XCTAssertEqual(model.currentSubtitleText, "First")
        preferences.useSubtitleFileStyles = true
        model.currentTime = 2; model.updateSubtitleDisplay()
        try await waitUntilCondition { model.currentSubtitleImage != nil }
        model.currentTime = 3; model.updateSubtitleDisplay()
        XCTAssertNotNil(model.currentSubtitleImage, "Animation keeps its previous frame while the replacement renders")
        model.subtitleOffset = 10; model.updateSubtitleDisplay()
        XCTAssertNil(model.currentSubtitleImage)
        model.currentTime = 2; model.subtitleOffset = 0; model.updateSubtitleDisplay()
        model.teardown()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.currentSubtitleImage)
        XCTAssertTrue(model.subtitleCues.isEmpty)
    }
}
