import XCTest
import AVFoundation
import CoreGraphics
@testable import SwiftPlayer

@MainActor
final class BitmapSubtitleTests: DebugMatrixTestCase {
    private func be(_ value: Int, _ count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    private func segment(_ type: UInt8, _ payload: [UInt8], time: Int = 90_000) -> Data {
        Data([0x50, 0x47] + be(time, 4) + [0, 0, 0, 0, type] + be(payload.count, 2) + payload)
    }
    private func presentation(objects: Int, time: Int = 90_000, state: UInt8 = 0x80, cropped: Bool = false) -> Data {
        segment(0x16, [0, 16, 0, 9, 0x10, 0, 0, state, 0, 0, UInt8(objects)] +
            (objects == 0 ? [] : [0, 1, 0, cropped ? 0x80 : 0, 0, 4, 0, 5] + (cropped ? [0, 1, 0, 0, 0, 1, 0, 2] : [])), time: time)
    }
    private func fixture(cropped: Bool = false, fragmented: Bool = false) -> Data {
        var data = presentation(objects: 1, cropped: cropped)
        data.append(segment(0x14, [0, 0, 1, 235, 128, 128, 255]))
        let pixels: [UInt8] = [1, 1, 0, 0, 1, 1, 0, 0]
        if fragmented {
            data.append(segment(0x15, [0, 1, 0, 0x80] + be(pixels.count + 4, 3) + [0, 2, 0, 2] + Array(pixels.prefix(3))))
            data.append(segment(0x15, [0, 1, 0, 0x40] + Array(pixels.dropFirst(3))))
        } else { data.append(segment(0x15, [0, 1, 0, 0xc0] + be(pixels.count + 4, 3) + [0, 2, 0, 2] + pixels)) }
        data.append(segment(0x80, []))
        data.append(presentation(objects: 0, time: 270_000, state: 0))
        data.append(segment(0x80, [], time: 270_000))
        return data
    }
    private func write(_ data: Data, name: String = "Generated.sup") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testPGSPalettePlacementClearingFragmentationAndCropping() throws {
        for fragmented in [false, true] {
            let cues = try PGSSubtitleParser.load(write(fixture(fragmented: fragmented)))
            XCTAssertEqual(cues.count, 1)
            XCTAssertEqual(cues.first?.start, 1)
            XCTAssertEqual(cues.first?.end, 3)
            let image = try XCTUnwrap(cues.first?.bitmap).render()
            XCTAssertEqual(image.canvas, CGSize(width: 16, height: 9))
            XCTAssertEqual(image.parts.first?.bounds, CGRect(x: 4, y: 5, width: 2, height: 2))
            let bytes = try XCTUnwrap(image.parts.first?.image.dataProvider?.data) as Data
            XCTAssertTrue(bytes.allSatisfy { $0 >= 254 })
        }
        let cues = try PGSSubtitleParser.load(write(fixture(cropped: true)))
        let image = try XCTUnwrap(cues.first?.bitmap).render()
        XCTAssertEqual(image.parts.first?.image.width, 1)
        XCTAssertEqual(image.parts.first?.image.height, 2)
        var twiceCleared = fixture()
        twiceCleared.append(presentation(objects: 0, time: 450_000, state: 0))
        twiceCleared.append(segment(0x80, [], time: 450_000))
        XCTAssertEqual(try PGSSubtitleParser.load(write(twiceCleared)).first?.end, 3)
    }

    func testPGSRLETransparencyLongRunsAndMalformedInput() throws {
        XCTAssertEqual(try DVDSubtitleDecoder.pixels(Data([0, 0, 0, 0, 0x90, 0xa0]), width: 2, height: 2, offsets: (4, 5)), [1, 1, 2, 2])
        XCTAssertEqual(try DVDSubtitleDecoder.pixels(Data([0, 0, 0, 0, 0, 2, 0, 3]), width: 5, height: 2, offsets: (4, 6)), [UInt8](repeating: 2, count: 5) + [UInt8](repeating: 3, count: 5))
        XCTAssertEqual(try BitmapSubtitle.pgsPixels(Data([0, 0x83, 2, 0, 1, 0, 0]), width: 4, height: 1), [2, 2, 2, 0])
        XCTAssertEqual(try BitmapSubtitle.pgsPixels(Data([0, 0x41, 0, 0, 0]), width: 256, height: 1), [UInt8](repeating: 0, count: 256))
        for bad: [UInt8] in [[], [0], [0, 0x83], [0, 0x85, 1], [1, 0, 0]] {
            XCTAssertThrowsError(try BitmapSubtitle.pgsPixels(Data(bad), width: 4, height: 1))
        }
        let valid = fixture()
        for length in stride(from: 1, to: valid.count, by: 7) {
            XCTAssertThrowsError(try PGSSubtitleParser.load(write(Data(valid.prefix(length)))))
        }
        XCTAssertThrowsError(try PGSSubtitleParser.load(write(Data([0, 1, 2]))))
        let huge = BitmapSubtitle(canvas: CGSize(width: 8192, height: 8192), parts: [
            .init(bounds: .zero, width: 8192, height: 8192, bytes: Data(), palette: [])])
        XCTAssertThrowsError(try huge.render())
    }

    func testPGSModelDelayOffSeekReplacementAndCancellation() async throws {
        let url = try write(fixture())
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        model.loadSubtitles(url: url)
        try await waitUntilCondition { !model.hasPendingSubtitleLoad }
        XCTAssertEqual(model.mediaControls.subtitleSelection, "external")
        model.currentTime = 2; model.updateSubtitleDisplay()
        try await waitUntilCondition { model.currentSubtitleImage != nil }
        XCTAssertTrue(model.currentSubtitleText.isEmpty)
        let first = model.currentSubtitleImage?.id
        for _ in 0..<20 { model.updateSubtitleDisplay() }
        XCTAssertEqual(model.currentSubtitleImage?.id, first)
        model.subtitleOffset = 2
        model.updateSubtitleDisplay()
        XCTAssertNil(model.currentSubtitleImage)
        model.subtitleOffset = 0
        model.currentTime = 3; model.updateSubtitleDisplay()
        XCTAssertNil(model.currentSubtitleImage)
        model.currentTime = 1; model.updateSubtitleDisplay()
        try await waitUntilCondition { model.currentSubtitleImage != nil }
        model.mediaControls.subtitleSelection = "off"; model.updateSubtitleDisplay()
        XCTAssertNil(model.currentSubtitleImage)
        model.mediaControls.subtitleSelection = "external"; model.updateSubtitleDisplay()
        model.loadSubtitles(url: try write(Data(), name: "Broken.sup"))
        try await waitUntilCondition { !model.hasPendingSubtitleLoad }
        XCTAssertEqual(model.subtitleCues.count, 1, "A failed load must preserve the previous subtitle document")
        model.currentTime = 2; model.updateSubtitleDisplay()
        model.teardown()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.currentSubtitleImage)
        XCTAssertTrue(model.subtitleCues.isEmpty)
    }

    func testPGSRenderingIsIncludedInPNGAndParserIsAvailableToMatching() throws {
        let url = try write(fixture(), name: "Generated.en.sup")
        XCTAssertNotNil(SubtitleMatching.rank(candidate: url, media: directory.appendingPathComponent("Generated.mp4"), preferredLanguages: ["en"]))
        let cues = parseSubtitles(from: url)
        let subtitle = try XCTUnwrap(cues.first?.bitmap).render()
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertNotEqual(try FrameCaptureImage.png(image, caption: nil), try FrameCaptureImage.png(image, caption: nil, subtitles: subtitle))
    }
}
