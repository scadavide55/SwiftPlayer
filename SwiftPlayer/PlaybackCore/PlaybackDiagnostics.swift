import Foundation
import AVFoundation
import Combine
import Darwin

nonisolated enum PlaybackDiagnosticState: String, Sendable {
    case noMedia = "No media", opening = "Opening", failed = "Failed", finished = "Finished"
    case seeking = "Seeking", starting = "Starting", waiting = "Waiting", playing = "Playing", paused = "Paused", unknown = "Unknown"
}

nonisolated struct LoadedPlaybackRange: Equatable, Sendable {
    let start: Double
    var end: Double
}

nonisolated struct PlaybackBufferSummary: Equatable, Sendable {
    var ranges: [LoadedPlaybackRange] = []
    var ahead: Double?
    var total: Double?
    var isTruncated = false

    static func make(_ input: [CMTimeRange], position: Double, truncated: Bool = false) -> Self {
        let valid = input.prefix(256).compactMap { range -> LoadedPlaybackRange? in
            let start = range.start.seconds, duration = range.duration.seconds
            let end = start + duration
            guard start.isFinite, duration.isFinite, duration > 0, end.isFinite, end > 0 else { return nil }
            return LoadedPlaybackRange(start: max(0, start), end: end)
        }.sorted { $0.start < $1.start }
        var result = Self(isTruncated: truncated || input.count > 256)
        for range in valid {
            if let last = result.ranges.last, range.start <= last.end + 0.001 {
                result.ranges[result.ranges.count - 1].end = max(last.end, range.end)
            } else { result.ranges.append(range) }
        }
        guard !result.ranges.isEmpty else { return result }
        let total = result.ranges.reduce(0) { $0 + $1.end - $1.start }
        result.total = total.isFinite ? total : nil
        if position.isFinite, position >= 0 {
            result.ahead = result.ranges.first { $0.start <= position + 0.001 && $0.end > position }.map { max(0, $0.end - position) } ?? 0
        }
        return result
    }
}

nonisolated struct PlaybackDiagnosticSnapshot: Equatable, Sendable {
    var state: PlaybackDiagnosticState = .noMedia
    var waitingReason: String?
    var position: Double?
    var duration: Double?
    var selectedRate: Float = 1
    var playerRate: Float?
    var actualRate: Float?
    var buffer = PlaybackBufferSummary()
    var bufferEmpty: Bool?
    var bufferFull: Bool?
    var likelyToKeepUp: Bool?
    var width: Int?
    var height: Int?
    var memoryBytes: UInt64?

    static func state(hasItem: Bool, status: AVPlayerItem.Status, timeStatus: AVPlayer.TimeControlStatus,
                       waitingReason: AVPlayer.WaitingReason? = nil, requested: Bool,
                       loading: Bool, failed: Bool, finished: Bool, seeking: Bool) -> PlaybackDiagnosticState {
        if failed || status == .failed { return .failed }
        if loading || (hasItem && status == .unknown) { return .opening }
        if finished { return .finished }
        if !hasItem { return .noMedia }
        if seeking { return .seeking }
        switch timeStatus {
        case .playing: return .playing
        case .waitingToPlayAtSpecifiedRate: return waitingReason == .evaluatingBufferingRate ? .starting : .waiting
        case .paused: return requested ? .starting : .paused
        @unknown default: return .unknown
        }
    }

    static func reason(_ reason: AVPlayer.WaitingReason?) -> String {
        switch reason {
        case .toMinimizeStalls: return "Loading enough media for smooth playback"
        case .evaluatingBufferingRate: return "Checking playback readiness"
        case .noItemToPlay: return "Waiting for a media item"
        case .waitingForCoordinatedPlayback: return "Waiting for coordinated playback"
        default: return "Reason not available"
        }
    }

    @MainActor
    static func capture(_ model: PlayerModel) -> Self {
        let player = model.player
        let item = player.currentItem
        let ready = item?.status == .readyToPlay
        let time = player.currentTime().seconds
        let nativeRanges = ready ? item?.loadedTimeRanges ?? [] : []
        let reason = player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? player.reasonForWaitingToPlay : nil
        var result = Self()
        result.state = state(hasItem: item != nil, status: item?.status ?? .unknown, timeStatus: player.timeControlStatus,
            waitingReason: reason, requested: model.playbackRequested, loading: model.isLoading,
            failed: model.playbackFailed, finished: model.playbackFinished,
            seeking: model.isSeeking || model.isScrubbing || model.isFastSeeking)
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { result.waitingReason = Self.reason(reason) }
        result.position = model.isFinishedUnloaded ? model.currentTime : (item != nil && time.isFinite && time >= 0 ? time : nil)
        result.duration = model.duration.isFinite && model.duration > 0 ? model.duration : nil
        result.selectedRate = model.playbackRate
        result.playerRate = item != nil && player.rate.isFinite ? player.rate : nil
        result.actualRate = effectiveRate(item?.timebase)
        result.buffer = .make(nativeRanges.prefix(256).map(\.timeRangeValue), position: time, truncated: nativeRanges.count > 256)
        result.bufferEmpty = ready ? item?.isPlaybackBufferEmpty : nil
        result.bufferFull = ready ? item?.isPlaybackBufferFull : nil
        result.likelyToKeepUp = ready ? item?.isPlaybackLikelyToKeepUp : nil
        if let size = item?.presentationSize, size.width.isFinite, size.height.isFinite,
           size.width > 0, size.height > 0, size.width < CGFloat(Int.max), size.height < CGFloat(Int.max) {
            result.width = Int(size.width)
            result.height = Int(size.height)
        }
        result.memoryBytes = physicalFootprint()
        return result
    }

    static func effectiveRate(_ timebase: CMTimebase?) -> Float? {
        guard let timebase else { return nil }
        let rate = CMTimebaseGetEffectiveRate(timebase)
        guard rate.isFinite, abs(rate) <= Double(Float.greatestFiniteMagnitude) else { return nil }
        return Float(rate)
    }

    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// Runs only while the playback information panel is visible. No model or
/// native player is held across the sampling interval.
@MainActor
final class PlaybackDiagnostics: ObservableObject {
    @Published private(set) var snapshot = PlaybackDiagnosticSnapshot()
    private(set) var sampleCount = 0
    var isSampling: Bool { task != nil }
    private weak var model: PlayerModel?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start(_ model: PlayerModel) {
        stop()
        self.model = model
        _ = refresh()
        let identifier = generation
        task = Task { [weak self] in
            defer { if self?.generation == identifier { self?.task = nil } }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    guard self?.generation == identifier, self?.refresh() == true else { return }
                }
            } catch { /* Hiding or closing the panel cancels sampling. */ }
        }
    }

    private func refresh() -> Bool {
        guard let model else { return false }
        let next = PlaybackDiagnosticSnapshot.capture(model)
        if snapshot != next { snapshot = next }
        sampleCount += 1
        return true
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        model = nil
    }

    deinit { task?.cancel() }
}
