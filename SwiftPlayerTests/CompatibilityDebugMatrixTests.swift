import XCTest
import AVFoundation
@testable import SwiftPlayer

@MainActor
final class CompatibilityDebugMatrixTests: DebugMatrixTestCase {
    private func atom(_ type: String, _ payload: Data, extended: Bool = false) -> Data {
        func bytes(_ value: UInt64, _ count: Int) -> Data {
            Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        return (extended ? bytes(1, 4) + Data(type.utf8) + bytes(UInt64(payload.count + 16), 8)
                         : bytes(UInt64(payload.count + 8), 4) + Data(type.utf8)) + payload
    }

    private func movie(parameterSets: [UInt8] = [32, 33, 34], extended: Bool = false) -> Data {
        var config = Data(repeating: 0, count: 23)
        config[0] = 1
        config[22] = UInt8(parameterSets.count)
        for type in parameterSets { config += Data([type, 0, 1, 0, 2, type << 1, 1]) }
        let entry = atom("hev1", Data(repeating: 0, count: 78) + atom("hvcC", config))
        var data = atom("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + entry)
        for type in ["stbl", "minf", "mdia", "trak"] { data = atom(type, data) }
        return atom("moov", data, extended: extended)
    }

    private func fixture(_ variant: Int) async throws -> URL {
        let url = directory.appendingPathComponent("generated-\(variant).mp4")
        let width = 96 + variant * 16
        let height = 64 + (variant % 3) * 16
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        for index in 0..<(30 + variant) {
            try await waitUntilCondition { input.isReadyForMoreMediaData }
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func decode(_ source: URL, width: Int, seek: Double? = nil, copy: Bool) async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        model.load(url: source)
        try await waitUntilCondition { model.player.currentItem != nil || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
        let item = try XCTUnwrap(model.player.currentItem)
        let loaded = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
        XCTAssertEqual(loaded != source, copy)
        let originalTracks = try await AVURLAsset(url: source).load(.tracks)
        let loadedTracks = try await item.asset.load(.tracks)
        XCTAssertEqual(loadedTracks.map { $0.mediaType.rawValue }.sorted(),
                       originalTracks.map { $0.mediaType.rawValue }.sorted())
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        item.add(output)
        var frame: CVPixelBuffer?
        try await waitUntilCondition({
            frame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
            return frame != nil || model.playbackFailed
        }, seconds: 20)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame)), width)
        frame = nil
        if let seek {
            model.seek(to: seek)
            try await waitUntilCondition { abs(model.player.currentTime().seconds - seek) < 5 || model.playbackFailed }
            try await waitUntilCondition({
                frame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
                return frame != nil || model.playbackFailed
            }, seconds: 20)
            XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(frame)), width)
        }
        XCTAssertFalse(model.playbackFailed)
        model.teardown()
        XCTAssertEqual(FileManager.default.fileExists(atPath: loaded.path), !copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test100CompatibilityAndRenderingRounds() async throws {
        let names = ["local-hd-ordinary-seek", "hev1-decode", "fallback-integrity", "missing-parameter-set", "truncated-metadata",
                     "extended-padding", "read-only-original", "cancel-before-prepare", "extension-dispatch", "local-8k-ordinary-seek"]
        var generated: [URL] = []
        for variant in 0..<10 { generated.append(try await fixture(variant)) }
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("compatibility", family * 10 + variant, "\(names[family]); input=\(variant)") {
                    let source = directory.appendingPathComponent("input-\(family)-\(variant).mp4")
                    switch family {
                    case 0:
                        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"] else {
                            throw XCTSkip("The compatibility matrix requires opt-in local 1920-pixel-wide media.")
                        }
                        let times: [Double] = [0, 5, 10, 30, 60, 120, 180, 240, 300, 600]
                        try await decode(URL(fileURLWithPath: path), width: 1920, seek: times[variant], copy: true)
                    case 1:
                        var data = try Data(contentsOf: generated[variant])
                        data.replaceSubrange(try XCTUnwrap(data.range(of: Data("hvc1".utf8))), with: Data("hev1".utf8))
                        try data.write(to: source)
                        try await decode(source, width: 96 + variant * 16, copy: true)
                    case 2, 5, 6:
                        let original = atom("free", Data(repeating: 7, count: variant * 13))
                            + movie(extended: variant % 2 == 0)
                            + atom("mdat", Data(repeating: 42, count: (variant + 1) * (family == 2 ? 1024 * 1024 : 17)))
                        try original.write(to: source)
                        if family == 6 {
                            try FileManager.default.setAttributes([.posixPermissions: variant % 2 == 0 ? 0o400 : 0o444], ofItemAtPath: source.path)
                        }
                        let media = try HEVCCompatibility.prepare(url: source, allowClone: family != 2 && variant % 2 == 0)
                        defer { media.removeTemporaryFiles() }
                        var expected = original
                        expected.replaceSubrange(try XCTUnwrap(expected.range(of: Data("hev1".utf8))), with: Data("hvc1".utf8))
                        XCTAssertEqual(try Data(contentsOf: media.url), expected)
                        XCTAssertEqual(try Data(contentsOf: source), original)
                        if family == 6 {
                            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int,
                                variant % 2 == 0 ? 0o400 : 0o444)
                        }
                        media.removeTemporaryFiles()
                        XCTAssertFalse(FileManager.default.fileExists(atPath: media.url.path))
                    case 3:
                        let sets: [[UInt8]] = [[], [32], [33], [34], [32, 33], [32, 34], [33, 34], [31, 33, 34], [32, 35, 34], [32, 33, 35]]
                        let data = movie(parameterSets: sets[variant])
                        XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: data).isEmpty)
                        try data.write(to: source)
                        let media = try HEVCCompatibility.prepare(url: source)
                        XCTAssertEqual(media.url, source)
                    case 4:
                        let data = movie(extended: variant % 2 == 0)
                        let cut = variant * (data.count - 1) / 10
                        try data.prefix(cut).write(to: source)
                        XCTAssertTrue(HEVCCompatibility.sampleEntryOffsets(in: Data(data.prefix(cut))).isEmpty)
                        XCTAssertEqual(try HEVCCompatibility.prepare(url: source).url, source)
                    case 7:
                        try movie(extended: variant % 2 == 0).write(to: source)
                        let worker = Task.detached {
                            try await Task.sleep(for: .milliseconds(50 + variant))
                            return try HEVCCompatibility.prepare(url: source)
                        }
                        worker.cancel()
                        do {
                            let media = try await worker.value
                            media.removeTemporaryFiles()
                            XCTFail("Canceled preparation must not return a copy.")
                        } catch is CancellationError { }
                        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
                    case 8:
                        let ext = ["MP4", "MOV", "m4v", "wav", "mp3", "aiff", "caf", "aac", "bin", "mkv"][variant]
                        let url = source.deletingPathExtension().appendingPathExtension(ext)
                        try movie().write(to: url)
                        let media = try HEVCCompatibility.prepare(url: url)
                        defer { media.removeTemporaryFiles() }
                        XCTAssertEqual(media.url != url, variant < 3)
                    default:
                        guard let path = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_MEDIA"] else {
                            throw XCTSkip("The 100-round compatibility matrix requires opt-in local 8K media.")
                        }
                        let times: [Double] = [0, 1, 2, 5, 10, 30, 60, 120, 180, 240]
                        try await decode(URL(fileURLWithPath: path), width: 8192, seek: times[variant], copy: true)
                    }
                }
            }
        }
    }
}
