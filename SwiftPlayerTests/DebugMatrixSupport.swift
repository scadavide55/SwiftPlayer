import XCTest
import AVFoundation
import AppKit
import Combine
import Darwin
@testable import SwiftPlayer

/// The matrix suites run 100 distinct scenario/input combinations per area.
/// Only completed cases emit a result; assertions and thrown errors mark failure.
@MainActor
class DebugMatrixTestCase: XCTestCase {
    var directory: URL!
    var audio: [URL] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for seconds in [12, 20] {
            let url = directory.appendingPathComponent("audio-\(seconds).wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 8_000)))
            buffer.frameLength = buffer.frameCapacity
            memset(try XCTUnwrap(buffer.floatChannelData?[0]), 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            audio.append(url)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        audio.removeAll()
        directory = nil
    }

    final func waitUntilCondition(_ condition: @escaping @MainActor () -> Bool, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "DebugMatrixTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func settle(_ variant: Int) async throws {
        let milliseconds = [0, 1, 2, 5, 10, 15, 25, 40, 65, 100][variant]
        if milliseconds == 0 { await Task.yield() }
        else { try await Task.sleep(for: .milliseconds(milliseconds)) }
    }

    func ready(_ model: PlayerModel, url: URL? = nil, paused: Bool = true) async throws {
        model.load(url: url ?? audio[1])
        if paused { model.pause() }
        try await waitUntilCondition { model.player.currentItem?.status == .readyToPlay && model.duration > 0 || model.playbackFailed }
        XCTAssertFalse(model.playbackFailed, model.playbackErrorMessage)
    }

    final func round(_ area: String, _ index: Int, _ name: String,
               operation: () async throws -> Void) async throws {
        let failures = testRun?.failureCount ?? 0
        do {
            try await operation()
        } catch {
            print("DEBUG_ROUND|\(area)|\(String(format: "%03d", index + 1))|\(name)|ERROR")
            throw error
        }
        let result = (testRun?.failureCount ?? 0) == failures ? "PASS" : "FAIL"
        print("DEBUG_ROUND|\(area)|\(String(format: "%03d", index + 1))|\(name)|\(result)")
        if area == "memory" {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            XCTAssertEqual(status, KERN_SUCCESS)
            print("DEBUG_MEMORY|\(index + 1)|\(info.phys_footprint / (1024 * 1024))")
        }
    }

    func assertClosed(_ model: PlayerModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(model.player.currentItem, file: file, line: line)
        XCTAssertEqual(model.player.rate, 0, file: file, line: line)
        XCTAssertFalse(model.playbackRequested, file: file, line: line)
        XCTAssertFalse(model.isLoading, file: file, line: line)
        XCTAssertFalse(model.isFastSeeking, file: file, line: line)
        XCTAssertFalse(model.isScrubbing, file: file, line: line)
    }
}
