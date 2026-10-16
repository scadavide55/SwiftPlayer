import XCTest
import AVFoundation
import Combine
@testable import SwiftPlayer

@MainActor
final class PlaybackDiagnosticsTests: DebugMatrixTestCase {
    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func testOverlappingLoadedRangesAreMergedWithoutCountingGapsOrDuplicates() {
        let input = [range(30, 10), range(5, 15), range(0, 10), range(0, 10)]
        let summary = PlaybackBufferSummary.make(input, position: 8)
        XCTAssertEqual(summary.ranges, [LoadedPlaybackRange(start: 0, end: 20), LoadedPlaybackRange(start: 30, end: 40)])
        XCTAssertEqual(summary.total, 30)
        XCTAssertEqual(summary.ahead, 12)
        XCTAssertEqual(PlaybackBufferSummary.make(input, position: 25).ahead, 0)
        XCTAssertEqual(PlaybackBufferSummary.make(input, position: 20).ahead, 0)
        XCTAssertEqual(PlaybackBufferSummary.make(input, position: 35).ahead, 5)
    }

    func testUnknownAndMalformedBuffersStayUnavailableAndRangeWorkIsBounded() {
        let invalid = CMTimeRange(start: .indefinite, duration: .invalid)
        let empty = PlaybackBufferSummary.make([invalid, range(10, -2), range(0, 0)], position: 0)
        XCTAssertNil(empty.ahead)
        XCTAssertNil(empty.total)
        XCTAssertTrue(empty.ranges.isEmpty)
        let many = (0..<1000).map { range(Double($0 * 3), 1) }
        let bounded = PlaybackBufferSummary.make(many, position: .nan)
        XCTAssertEqual(bounded.ranges.count, 256)
        XCTAssertTrue(bounded.isTruncated)
        XCTAssertNil(bounded.ahead)
    }

    func testStatePriorityAndWaitingReasonsDescribeStartupStallsAndFailure() {
        func state(hasItem: Bool = true, status: AVPlayerItem.Status = .readyToPlay,
                   time: AVPlayer.TimeControlStatus = .paused, reason: AVPlayer.WaitingReason? = nil,
                   requested: Bool = false, loading: Bool = false, failed: Bool = false,
                   finished: Bool = false, seeking: Bool = false) -> PlaybackDiagnosticState {
            PlaybackDiagnosticSnapshot.state(hasItem: hasItem, status: status, timeStatus: time, waitingReason: reason,
                   requested: requested, loading: loading, failed: failed, finished: finished, seeking: seeking)
        }
        XCTAssertEqual(state(hasItem: false), .noMedia)
        XCTAssertEqual(state(hasItem: false, loading: true), .opening)
        XCTAssertEqual(state(status: .failed, loading: true), .failed)
        XCTAssertEqual(state(time: .playing, failed: true), .failed)
        XCTAssertEqual(state(time: .playing, finished: true), .finished)
        XCTAssertEqual(state(seeking: true), .seeking)
        XCTAssertEqual(state(time: .playing), .playing)
        XCTAssertEqual(state(), .paused)
        XCTAssertEqual(state(requested: true), .starting)
        XCTAssertEqual(state(time: .waitingToPlayAtSpecifiedRate, reason: .evaluatingBufferingRate), .starting)
        XCTAssertEqual(state(time: .waitingToPlayAtSpecifiedRate, reason: .toMinimizeStalls), .waiting)
        XCTAssertNotEqual(PlaybackDiagnosticSnapshot.reason(.toMinimizeStalls), PlaybackDiagnosticSnapshot.reason(.noItemToPlay))
        XCTAssertEqual(PlaybackDiagnosticSnapshot.reason(AVPlayer.WaitingReason(rawValue: "Unknown")), "Reason not available")
    }

    func testNativeSnapshotsFollowTransportAndReadMemoryWithoutChangingPlayback() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        let item = model.player.currentItem
        let paused = PlaybackDiagnosticSnapshot.capture(model)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.playerRate, 0)
        XCTAssertEqual(paused.actualRate, 0)
        XCTAssertGreaterThan(paused.memoryBytes ?? 0, 0)
        let initialTime = model.player.currentTime().seconds
        model.play()
        try await waitUntilCondition { model.isPlaying && model.player.currentTime().seconds > initialTime + 0.05 }
        let playing = PlaybackDiagnosticSnapshot.capture(model)
        XCTAssertEqual(playing.state, .playing)
        XCTAssertEqual(playing.playerRate, 1)
        XCTAssertEqual(try XCTUnwrap(playing.actualRate), 1, accuracy: 0.01)
        XCTAssertTrue(model.player.currentItem === item)
        XCTAssertTrue(model.playbackRequested)
        model.pause()
        XCTAssertEqual(PlaybackDiagnosticSnapshot.capture(model).state, .paused)
        model.teardown()
        XCTAssertEqual(PlaybackDiagnosticSnapshot.capture(model).state, .noMedia)
        model.load(url: directory.appendingPathComponent("Missing.mp4"))
        try await waitUntilCondition { model.playbackFailed }
        XCTAssertEqual(PlaybackDiagnosticSnapshot.capture(model).state, .failed)
    }

    func testOrdinaryPendingSeeksAreReportedUntilTheLatestSeekCompletes() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        try await ready(model)
        XCTAssertEqual(PlaybackDiagnosticSnapshot.capture(model).state, .paused)
        for target in [8.0, 3, 11, 2] {
            model.seek(to: target)
            XCTAssertEqual(PlaybackDiagnosticSnapshot.capture(model).state, .seeking)
        }
        try await waitUntilCondition {
            abs(model.player.currentTime().seconds - 2) < 0.1 &&
            PlaybackDiagnosticSnapshot.capture(model).state == .paused
        }
        XCTAssertFalse(model.playbackRequested)
        model.seek(to: 8)
        model.teardown()
        XCTAssertEqual(PlaybackDiagnosticSnapshot.capture(model).state, .noMedia)
    }

    func testEffectiveClockRateIncludesPausedAndSlowerSourceTimebases() throws {
        var source: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &source), noErr)
        let sourceClock = try XCTUnwrap(source)
        var child: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault,
            sourceTimebase: sourceClock, timebaseOut: &child), noErr)
        let mediaClock = try XCTUnwrap(child)
        XCTAssertEqual(CMTimebaseSetRate(mediaClock, rate: 1), noErr)
        XCTAssertEqual(CMTimebaseGetRate(mediaClock), 1)
        XCTAssertEqual(PlaybackDiagnosticSnapshot.effectiveRate(mediaClock), 0,
            "A requested media rate of one is ineffective while its source timebase is paused")
        XCTAssertEqual(CMTimebaseSetRate(sourceClock, rate: 0.5), noErr)
        XCTAssertEqual(PlaybackDiagnosticSnapshot.effectiveRate(mediaClock), 0.5)
        XCTAssertNil(PlaybackDiagnosticSnapshot.effectiveRate(nil))
    }

    func testSamplerStopsWhenHiddenAndDoesNotRetainItsPlayerOrInvalidateMenus() async throws {
        var model: PlayerModel? = PlayerModel()
        weak var released = model
        try await ready(try XCTUnwrap(model))
        var menus: PlayerMenuState? = PlayerMenuState(model: model)
        for _ in 0..<10 { await Task.yield() }
        var changes = 0
        let observation = try XCTUnwrap(menus).objectWillChange.sink { changes += 1 }
        let sampler = PlaybackDiagnostics()
        sampler.start(try XCTUnwrap(model))
        try await waitUntilCondition { sampler.sampleCount >= 2 }
        XCTAssertEqual(changes, 0)
        sampler.stop()
        let count = sampler.sampleCount
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(sampler.sampleCount, count)
        XCTAssertFalse(sampler.isSampling)
        sampler.start(try XCTUnwrap(model))
        observation.cancel()
        menus = nil
        model?.teardown()
        model = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(released)
        sampler.stop()
    }

    func testRapidRestartAndDeallocationReleaseTheSamplerTask() async throws {
        let first = PlayerModel(), second = PlayerModel()
        defer { first.teardown(); second.teardown() }
        try await ready(first)
        var sampler: PlaybackDiagnostics? = PlaybackDiagnostics()
        weak var released = sampler
        sampler?.start(first)
        sampler?.stop()
        sampler?.start(second)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertTrue(sampler?.isSampling ?? false)
        XCTAssertEqual(sampler?.snapshot.state, .noMedia)
        XCTAssertGreaterThanOrEqual(sampler?.sampleCount ?? 0, 3)
        sampler = nil
        XCTAssertNil(released)
    }

    func testLocalHDAnd8KPresentationSizesAreReportedWhenProvided() async throws {
        guard let hd = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_HD_MEDIA"],
              let large = ProcessInfo.processInfo.environment["SWIFTPLAYER_TEST_MEDIA"] else {
            throw XCTSkip("Set optional local HD and 8K media for diagnostic presentation checks")
        }
        let model = PlayerModel()
        defer { model.teardown() }
        for (path, width) in [(hd, 1920), (large, 8192)] {
            try await ready(model, url: URL(fileURLWithPath: path))
            try await waitUntilCondition { (model.player.currentItem?.presentationSize.width ?? 0) > 0 }
            let snapshot = PlaybackDiagnosticSnapshot.capture(model)
            XCTAssertEqual(snapshot.width, width)
            XCTAssertGreaterThan(snapshot.height ?? 0, 0)
            XCTAssertEqual(model.player.rate, 0)
        }
    }
}
