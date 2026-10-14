import XCTest
import AVFoundation
import Darwin
@testable import SwiftPlayer

@MainActor
final class HEVCCompatibilityTests: XCTestCase {
    private func atom(_ type: String, _ payload: Data, extended: Bool = false) -> Data {
        func bytes(_ value: UInt64, count: Int) -> Data {
            Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        let header = extended
            ? bytes(1, count: 4) + Data(type.utf8) + bytes(UInt64(payload.count + 16), count: 8)
            : bytes(UInt64(payload.count + 8), count: 4) + Data(type.utf8)
        return header + payload
    }

    private func movie(tag: String = "hev1", parameterSets: [UInt8] = [32, 33, 34], extended: Bool = false) -> Data {
        var config = Data(repeating: 0, count: 23)
        config[0] = 1
        config[22] = UInt8(parameterSets.count)
        for type in parameterSets { config += Data([type, 0, 1, 0, 2, type << 1, 1]) }
        let entry = atom(tag, Data(repeating: 0, count: 78) + atom("hvcC", config))
        var data = atom("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + entry)
        for type in ["stbl", "minf", "mdia", "trak"] { data = atom(type, data) }
        return atom("moov", data, extended: extended)
    }

    func testFindsOnlyHEVCSampleEntryWithParameterSets() {
        for extended in [false, true] {
            let data = movie(extended: extended)
            let offsets = HEVCCompatibility.sampleEntryOffsets(in: data)
            XCTAssertEqual(offsets.count, 1)
            XCTAssertEqual(String(decoding: data[offsets[0]..<(offsets[0] + 4)], as: UTF8.self), "hev1")
        }
        XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: movie(tag: "hvc1")).isEmpty)
        XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: movie(parameterSets: [33, 34])).isEmpty)
        XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: atom("mdat", movie())).isEmpty)
    }

    func testTruncatedAndInvalidMetadataIsSafe() {
        let data = movie()
        for length in 0..<data.count {
            XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: Data(data.prefix(length))).isEmpty)
        }
        XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: Data([0, 0, 0, 1]) + Data("moov".utf8)).isEmpty)
        XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: atom("moov", Data([255, 255, 255, 255]) + Data("trak".utf8))).isEmpty)
    }

    func testPreparationPreservesOriginalAndCleansUpCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("test.mp4")
        // Include a false match in frame data and a size-zero final box.
        let original = atom("ftyp", Data("isom".utf8)) + movie()
            + Data([0, 0, 0, 0]) + Data("mdathev1".utf8)
        try original.write(to: source)
        let prepared = try HEVCCompatibility.prepare(url: source)
        defer { prepared.removeTemporaryFiles() }
        XCTAssertNotEqual(prepared.url, source)
        XCTAssertEqual(try Data(contentsOf: source), original)
        var expected = original
        let tag = try XCTUnwrap(expected.range(of: Data("hev1".utf8)))
        expected.replaceSubrange(tag, with: Data("hvc1".utf8))
        XCTAssertEqual(try Data(contentsOf: prepared.url), expected)
        prepared.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.path))
    }

    func testReadOnlySourceAndBoundedFallbackCopy() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let original = movie() + atom("mdat", Data(repeating: 42, count: 5 * 1024 * 1024))
        try original.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: source.path)
        for allowClone in [false, true] {
            let media = try HEVCCompatibility.prepare(url: source, allowClone: allowClone)
            defer { media.removeTemporaryFiles() }
            var expected = original
            expected.replaceSubrange(try XCTUnwrap(expected.range(of: Data("hev1".utf8))), with: Data("hvc1".utf8))
            XCTAssertEqual(try Data(contentsOf: media.url), expected)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int, 0o400)
        }
    }

    func testNativeHEVCPlaybackAndSeekingAfterRetagging() async throws {
        let source = try await makeHEVCFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        var data = try Data(contentsOf: source)
        let tag = try XCTUnwrap(data.range(of: Data("hvc1".utf8)))
        data.replaceSubrange(tag, with: Data("hev1".utf8))
        try data.write(to: source)
        let originalTracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)
        let originalTrack = try XCTUnwrap(originalTracks.first)
        let originalDecodable = try await originalTrack.load(.isDecodable)
        XCTAssertFalse(originalDecodable)
        try await verifyPlayback(source, expectedWidth: 96, seekTime: 0.5)
    }

    func testLocal8KMediaWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_MEDIA"] else {
            throw XCTSkip("Set SWIFTPLAYER_TEST_MEDIA to exercise a local 8K file.")
        }
        try await verifyPlayback(URL(fileURLWithPath: path), expectedWidth: 8192, seekTime: 120)
    }

    func testLocal8KRepeatedPlaybackResourceRelease() async throws {
        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_MEDIA"] else {
            throw XCTSkip("Set SWIFTPLAYER_TEST_MEDIA to exercise repeated local 8K playback.")
        }
        var footprints: [UInt64] = []
        for _ in 0..<4 {
            try await verifyPlayback(URL(fileURLWithPath: path), expectedWidth: 8192, seekTime: 120)
            try await Task.sleep(for: .milliseconds(300))
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            XCTAssertEqual(result, KERN_SUCCESS)
            footprints.append(info.phys_footprint / (1024 * 1024))
        }
        // Record process footprint without treating framework caching as a leak.
        print("8K process physical footprint after each teardown (MiB): \(footprints)")
    }

    func testNativeHVC1PlaybackUsesOriginalFile() async throws {
        let source = try await makeHEVCFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        try await verifyPlayback(source, expectedWidth: 96, seekTime: 0.5, expectsCopy: false)
    }

    func testAudioPlaybackUsesOriginalFile() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: source) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for channel in 0..<Int(format.channelCount) {
            memset(try XCTUnwrap(buffer.floatChannelData?[channel]), 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let model = PlayerModel()
        defer { model.teardown() }
        model.load(url: source)
        try await waitUntil { model.isPlaying || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
        XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url, source)
        XCTAssertGreaterThan(model.duration, 0)
        model.teardown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testModelDeallocationRemovesCompatibilityCopy() async throws {
        let source = try await makeHEVCFixture()
        defer { try? FileManager.default.removeItem(at: source) }
        var data = try Data(contentsOf: source)
        let tag = try XCTUnwrap(data.range(of: Data("hvc1".utf8)))
        data.replaceSubrange(tag, with: Data("hev1".utf8))
        try data.write(to: source)
        var model: PlayerModel? = PlayerModel()
        let isReleased = { [weak model] in model == nil }
        model?.load(url: source)
        try await waitUntil { model?.isPlaying == true || model?.playbackFailed == true }
        XCTAssertFalse(try XCTUnwrap(model).playbackFailed)
        let temporaryURL = try XCTUnwrap((model?.player.currentItem?.asset as? AVURLAsset)?.url)
        XCTAssertNotEqual(temporaryURL, source)
        model = nil
        try await waitUntil(isReleased)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testReplacementIgnoresPreviousPreparation() async throws {
        let first = try await makeHEVCFixture()
        let second = try await makeHEVCFixture()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        var data = try Data(contentsOf: first)
        let tag = try XCTUnwrap(data.range(of: Data("hvc1".utf8)))
        data.replaceSubrange(tag, with: Data("hev1".utf8))
        try data.write(to: first)
        let model = PlayerModel()
        defer { model.teardown() }
        model.load(url: first)
        await Task.yield()
        model.load(url: second)
        try await waitUntil { model.isPlaying || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
        XCTAssertEqual(model.currentFileName, second.lastPathComponent)
        XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url, second)
    }

    private func verifyPlayback(_ source: URL, expectedWidth: Int, seekTime: Double, expectsCopy: Bool = true) async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        model.load(url: source)
        try await waitUntil { model.player.currentItem != nil || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
        let item = try XCTUnwrap(model.player.currentItem)
        let temporaryURL = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
        XCTAssertEqual(temporaryURL != source, expectsCopy)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        item.add(output)
        try await waitUntil { item.status == .readyToPlay || model.playbackFailed }
        var frame: CVPixelBuffer?
        try await waitUntil {
            frame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
            return frame != nil || model.playbackFailed
        }
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame)), expectedWidth)
        let sought = await model.player.seek(to: CMTime(seconds: seekTime, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)
        frame = nil
        try await waitUntil {
            frame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
            return frame != nil || model.playbackFailed
        }
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame)), expectedWidth)
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
        model.teardown()
        XCTAssertEqual(FileManager.default.fileExists(atPath: temporaryURL.path), !expectsCopy)
        // Loading a new file invalidates earlier preparation and playback callbacks.
        model.load(url: source)
        model.teardown()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.player.currentItem)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.playbackFailed)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "PlaybackTestTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeHEVCFixture() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 96, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<30 {
            try await waitUntil { input.isReadyForMoreMediaData }
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return url
    }
}
