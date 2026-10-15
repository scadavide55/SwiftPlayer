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
    func testEmbeddedCaptionTimingSupportsEarlyAndLateTransitionsAndFlushes() throws {
        let player = AVPlayer()
        let media = PlayerMediaControls(player: player, preferences: nil)
        let item = AVPlayerItem(asset: AVMutableComposition())
        defer { media.detach() }
        media.attach(to: item, sourceURL: audio[0])
        let output = try XCTUnwrap(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.first)
        media.subtitleDelay = 2
        media.legibleOutput(output, didOutputAttributedStrings: [NSAttributedString(string: "Generated caption")],
            nativeSampleBuffers: [], forItemTime: CMTime(seconds: 10, preferredTimescale: 600))
        media.tick(time: 11, duration: 20)
        XCTAssertTrue(media.embeddedText.isEmpty)
        media.tick(time: 12, duration: 20)
        XCTAssertEqual(media.embeddedText, "Generated caption")
        media.subtitleDelay = -2
        XCTAssertEqual(output.advanceIntervalForDelegateInvocation, 30)
        media.tick(time: 8, duration: 20)
        XCTAssertEqual(media.embeddedText, "Generated caption")
        media.legibleOutput(output, didOutputAttributedStrings: [], nativeSampleBuffers: [],
            forItemTime: CMTime(seconds: 15, preferredTimescale: 600))
        media.tick(time: 13, duration: 20)
        XCTAssertTrue(media.embeddedText.isEmpty)
        media.outputSequenceWasFlushed(output)
        media.tick(time: 8, duration: 20)
        XCTAssertTrue(media.embeddedText.isEmpty)
        media.subtitleDelay = .nan
        XCTAssertEqual(media.subtitleDelay, -2)
        media.subtitleDelay = 100
        XCTAssertEqual(media.subtitleDelay, 30)
    }

    func testCaptionHistoryAndTextAreBounded() {
        var timeline = CaptionTimeline()
        for index in 0..<2000 { timeline.insert(time: Double(index), text: "Caption") }
        XCTAssertEqual(timeline.events.count, CaptionTimeline.maximumEvents)
        XCTAssertTrue(timeline.text(at: 1).isEmpty)
        timeline.insert(time: 2001, text: String(repeating: "x", count: 20000))
        XCTAssertLessThanOrEqual(timeline.text(at: 2001).utf16.count, 8192)
        timeline.reset()
        XCTAssertTrue(timeline.events.isEmpty)
    }

    func testSubtitleMatchingPrefersLanguageAndRejectsUnrelatedOrUnsafeFiles() throws {
        let media = directory.appendingPathComponent("Episode.mp4")
        for name in ["Episode.srt", "Episode.en.srt", "Episode.en.forced.srt", "Episode.en-US.sdh.vtt", "Other.en.srt", "Episode.commentary.srt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let outside = directory.appendingPathComponent("Episode.fr.srt")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: audio[0])
        let matches = SubtitleMatching.find(in: directory, media: media, preferredLanguages: ["en-US"])
        XCTAssertEqual(matches.count, 4)
        XCTAssertTrue(matches.prefix(2).allSatisfy { $0.name.contains(".en") })
        XCTAssertFalse(matches.contains { $0.url == outside })
        XCTAssertEqual(matches.last?.name, "Episode.en.forced.srt")
    }

    func testAuthorizedFolderPersistsAndAutomaticSearchHonorsOff() async throws {
        let suite = "SubtitleFolders-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folders = SubtitleFolderStore(defaults: defaults)
        folders.add(directory)
        folders.add(directory)
        XCTAssertEqual(folders.entries.count, 1)
        let restored = SubtitleFolderStore(defaults: defaults)
        XCTAssertEqual(restored.entries.first?.reference.resolve()?.standardizedFileURL, directory.standardizedFileURL)
        let subtitle = directory.appendingPathComponent("audio-20.en.srt")
        try "1\n00:00:01,000 --> 00:00:05,000\nGenerated caption\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let model = PlayerModel()
        let search = SubtitleSearchController()
        defer { search.cancel(); model.teardown() }
        try await ready(model)
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        model.mediaControls.subtitleSelection = "off"
        search.start(model: model, folders: restored.entries, languages: ["en"], automatic: true)
        try await waitUntilCondition { !search.isSearching }
        XCTAssertEqual(model.mediaControls.subtitleSelection, "off")
        XCTAssertTrue(model.subtitleCues.isEmpty)
        model.mediaControls.subtitleSelection = "automatic"
        search.start(model: model, folders: restored.entries, languages: ["en"], automatic: true)
        try await waitUntilCondition { model.mediaControls.subtitleSelection == "external" }
        XCTAssertEqual(model.mediaControls.externalSubtitleName, subtitle.lastPathComponent)
        XCTAssertEqual(search.matches.count, 1)
        folders.remove(try XCTUnwrap(folders.entries.first))
        XCTAssertTrue(folders.entries.isEmpty)
    }

    func testNativeEmbeddedCaptionsCanAppearEarlyWhenLocalMediaIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else {
            throw XCTSkip("Set the optional local HD media to verify native embedded timing")
        }
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model, url: URL(fileURLWithPath: path))
        try await waitUntilCondition { !model.mediaControls.isDiscovering }
        let asset = try XCTUnwrap(model.player.currentItem?.asset)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var expected = ""
        var cueTime: Double = 0
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time >= 3, let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) >= 2 else { continue }
            var length: [UInt8] = [0, 0]
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 2, destination: &length) == noErr else { continue }
            let count = Int(length[0]) * 256 + Int(length[1])
            guard count > 0, count + 2 <= CMBlockBufferGetDataLength(block) else { continue }
            var bytes = [UInt8](repeating: 0, count: count)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 2, dataLength: count, destination: &bytes) == noErr else { continue }
            let data = Data(bytes)
            let encoding: String.Encoding = data.starts(with: [0xfe, 0xff]) || data.starts(with: [0xff, 0xfe]) ? .utf16 : .utf8
            expected = (String(data: data, encoding: encoding) ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if !expected.isEmpty { cueTime = time; break }
        }
        XCTAssertFalse(expected.isEmpty)
        model.subtitleOffset = -1
        model.seek(to: max(0, cueTime - 2))
        model.play()
        // Compare in memory without printing private subtitle dialogue.
        try await waitUntilCondition { model.mediaControls.embeddedText == expected }
        XCTAssertTrue(model.mediaControls.embeddedText == expected, "Native output must match the requested caption")
        XCTAssertLessThan(model.player.currentTime().seconds, cueTime - 0.3)
        model.pause()
    }

}
