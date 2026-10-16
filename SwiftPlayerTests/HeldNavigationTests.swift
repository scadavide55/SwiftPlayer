import XCTest
import AVFoundation
import Combine
@testable import SwiftPlayer

@MainActor
final class HeldNavigationTests: DebugMatrixTestCase {
    private func longAudio() throws -> URL {
        let url = directory.appendingPathComponent("navigation.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000 * 600))
        buffer.frameLength = buffer.frameCapacity
        memset(try XCTUnwrap(buffer.floatChannelData?[0]), 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testHoldHasHalfSecondDelayThenRepeatsNormalAndShiftJumpsEveryTenthSecond() async throws {
        let url = try longAudio()
        for largeJump in [false, true] {
            let length = largeJump ? 30.0 : 5.0
            for playing in [false, true] {
                for direction in [-1, 1] {
                    let model = PlayerModel()
                    defer { model.teardown() }
                    try await ready(model, url: url)
                    model.seek(to: 300)
                    try await waitUntilCondition { !model.isSeeking }
                    if playing { model.play() }
                    let start = model.player.currentTime().seconds
                    let clock = ContinuousClock()
                    let began = clock.now
                    var jumps: [Duration] = []
                    var previous = model.currentTime
                    let token = model.$currentTime.sink { time in
                        if (time - previous) * Double(direction) > length * 0.8 { jumps.append(began.duration(to: clock.now)) }
                        previous = time
                    }
                    model.beginFastSeeking(direction: direction, mode: largeJump ? .largeJump : .jump)
                    try await Task.sleep(until: began.advanced(by: .milliseconds(400)), clock: clock)
                    XCTAssertFalse(model.isFastSeeking)
                    XCTAssertEqual(jumps.count, 1)
                    XCTAssertEqual(model.player.currentTime().seconds, start + Double(direction) * length, accuracy: 0.6)
                    try await Task.sleep(until: began.advanced(by: .milliseconds(1050)), clock: clock)
                    model.endFastSeeking()
                    token.cancel()
                    try await waitUntilCondition { !model.isSeeking }
                    XCTAssertTrue((6...7).contains(jumps.count), "Observed \(jumps.count) jumps")
                    if jumps.count > 1 {
                        XCTAssertGreaterThanOrEqual(jumps[1], .milliseconds(480))
                        XCTAssertLessThan(jumps[1], .milliseconds(650))
                        for index in 2..<jumps.count {
                            XCTAssertGreaterThanOrEqual(jumps[index] - jumps[index - 1], .milliseconds(80))
                            XCTAssertLessThan(jumps[index] - jumps[index - 1], .milliseconds(180))
                        }
                    }
                    XCTAssertEqual(model.playbackRequested, playing)
                    XCTAssertEqual(model.player.rate, playing ? model.playbackRate : 0)
                    let released = model.player.currentTime().seconds
                    try await Task.sleep(for: .milliseconds(250))
                    XCTAssertEqual(model.player.currentTime().seconds, released, accuracy: playing ? 0.5 : 0.05)
                }
            }
        }
    }
}
