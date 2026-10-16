import XCTest
@testable import SwiftPlayer

@MainActor
final class VobSubSubtitleTests: DebugMatrixTestCase {
    private func be(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func spu() -> Data {
        // Two 2-pixel scanlines, with different colors in the two fields.
        let commands: [UInt8] = [1, 3, 0x32, 0x10, 4, 0xff, 0xf0, 5, 0, 0x40, 5, 0, 0x50, 6, 6, 0, 4, 0, 5, 0xff]
        let stop = 6 + 4 + commands.count
        let length = stop + 6
        return Data(be(length, 2) + [0, 6, 0x90, 0xa0] + [0, 0] + be(stop, 2) + commands + [0, 90] + be(stop, 2) + [2, 0xff])
    }
    private func pes(_ payload: Data, stream: UInt8 = 0x20) -> Data {
        let body = [UInt8](payload)
        return Data([0, 0, 1, 0xbd] + be(body.count + 4, 2) + [0x80, 0, 0, stream] + body)
    }
    private func pair() throws -> (URL, URL) {
        let idx = directory.appendingPathComponent("Generated.idx")
        let sub = directory.appendingPathComponent("Generated.sub")
        let first = pes(spu()), second = pes(spu(), stream: 0x21)
        try (first + second).write(to: sub)
        let colors = ["000000", "ff0000", "00ff00", "0000ff"] + Array(repeating: "ffffff", count: 12)
        try """
        # VobSub index file, v7
        size: 16x9
        palette: \(colors.joined(separator: ", "))
        langidx: 0
        id: en, index: 0
        timestamp: 00:00:01:000, filepos: 000000000
        id: zh, index: 1
        timestamp: 00:00:02:000, filepos: \(String(first.count, radix: 16))
        """.write(to: idx, atomically: true, encoding: .utf8)
        return (idx, sub)
    }
    func testDVDCommandsFieldsPaletteTimingAndLanguageSelection() throws {
        let (idx, sub) = try pair()
        let first = try VobSubParser.load(index: idx, companion: sub, track: 0, preferred: [])
        XCTAssertEqual(first.track, 0)
        let cue = try XCTUnwrap(first.cues.first)
        XCTAssertEqual(cue.start, 1)
        XCTAssertEqual(cue.end, 2.024, accuracy: 0.000001)
        let frame = try XCTUnwrap(cue.bitmap).render()
        XCTAssertEqual(frame.canvas, CGSize(width: 16, height: 9))
        XCTAssertEqual(frame.parts.first?.bounds, CGRect(x: 4, y: 5, width: 2, height: 2))
        let rgba = try XCTUnwrap(frame.parts.first?.image.dataProvider?.data) as Data
        XCTAssertEqual(Array(rgba.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(Array(rgba.suffix(4)), [0, 255, 0, 255])
        let preferred = try VobSubParser.load(index: idx, companion: sub, track: nil, preferred: ["zh-Hant"])
        XCTAssertEqual(preferred.track, 1)
        XCTAssertEqual(preferred.cues.first?.start, 2)
        XCTAssertEqual(parseSubtitles(from: sub, companion: idx, track: 1).first?.start, 2)
    }
    func testPESReassemblyIgnoresOtherStreamsAndValidatesTruncation() throws {
        let packet = spu()
        let split = 9
        let muxed = pes(Data(packet.prefix(split))) + pes(packet, stream: 0x21) + pes(Data(packet.dropFirst(split)))
        XCTAssertEqual(try VobSubParser.subpicture(muxed, stream: 0x20), packet)
        for count in 0..<muxed.count where count < 10 || count % 7 == 0 {
            XCTAssertThrowsError(try VobSubParser.subpicture(Data(muxed.prefix(count)), stream: 0x20))
        }
        XCTAssertThrowsError(try VobSubParser.decode(Data([0, 5, 0, 4, 0]), at: 0, canvas: CGSize(width: 720, height: 480), palette: Array(repeating: 0, count: 16)))
        var cyclic = spu()
        cyclic[cyclic.count - 4] = 0
        cyclic[cyclic.count - 3] = 6
        XCTAssertThrowsError(try VobSubParser.decode(cyclic, at: 0, canvas: CGSize(width: 720, height: 480), palette: Array(repeating: 0, count: 16)))
    }
    func testPairedBookmarksRoundTripAndOldReferencesRemainCompatible() throws {
        let (idx, sub) = try pair()
        let reference = try XCTUnwrap(SubtitleFileReference.capture(idx, companion: sub, subtitleTrack: 1))
        let decoded = try JSONDecoder().decode(SubtitleFileReference.self, from: JSONEncoder().encode(reference))
        XCTAssertEqual(decoded.resolve()?.standardizedFileURL, idx.standardizedFileURL)
        XCTAssertEqual(decoded.resolveCompanion()?.standardizedFileURL, sub.standardizedFileURL)
        XCTAssertEqual(decoded.subtitleTrack, 1)
        let old = try JSONSerialization.data(withJSONObject: ["bookmark": reference.bookmark.base64EncodedString()])
        XCTAssertNil(try JSONDecoder().decode(SubtitleFileReference.self, from: old).companionBookmark)
        var invalid = reference; invalid.companionBookmark = Data(count: 16 * 1024 + 1)
        XCTAssertNil(MediaFileMemory(externalSubtitle: invalid).normalized.externalSubtitle)
    }
    func testModelPersistsPairAndExplicitLanguageWhileOffWinsLoadingRace() async throws {
        let (idx, sub) = try pair()
        let suite = "VobSub-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        let model = PlayerModel(preferences: preferences)
        defer { model.teardown() }
        try await ready(model)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        model.loadSubtitles(url: idx, companion: sub, track: 1)
        model.mediaControls.subtitleSelection = "off"
        try await waitUntilCondition { !model.hasPendingSubtitleLoad }
        XCTAssertEqual(model.mediaControls.subtitleSelection, "off")
        XCTAssertEqual(model.subtitleCues.first?.start, 2)
        model.mediaControls.subtitleSelection = "external"
        let memory = try XCTUnwrap(preferences.mediaMemory(for: audio[1]))
        XCTAssertEqual(memory.externalSubtitle?.resolveCompanion()?.standardizedFileURL, sub.standardizedFileURL)
        XCTAssertEqual(memory.externalSubtitle?.subtitleTrack, 1)
        model.load(url: audio[1]); model.pause()
        try await waitUntilCondition { !model.isLoading && !model.mediaControls.isDiscovering && !model.hasPendingSubtitleLoad }
        XCTAssertEqual(model.subtitleCues.first?.start, 2)
        model.currentTime = 2.1; model.updateSubtitleDisplay()
        try await waitUntilCondition { model.currentSubtitleImage != nil }
    }
}
