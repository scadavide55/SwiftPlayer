import AVFoundation
import Foundation
import Combine

/// Extensions AVFoundation can natively decode (container-level allow-list
/// for the open panel / drop validation). Actual playability still depends
/// on the codec inside the file, but this covers what Apple ships decoders for.
let supportedExtensions: [String] = [
    "mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "aiff", "caf"
] // audio containers

@MainActor
final class PlayerModel: ObservableObject {
   
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing: Bool = false
    @Published var currentFileName: String = ""
    @Published var subtitleCues: [SubtitleCue] = [] {
        didSet {
            subtitleOrder = subtitleCues.indices.sorted { subtitleCues[$0].start < subtitleCues[$1].start }
            var maximumEnd = -Double.infinity
            subtitleMaximumEnds = subtitleOrder.map {
                maximumEnd = max(maximumEnd, subtitleCues[$0].end)
                return maximumEnd
            }
            updateSubtitleDisplay()
        }
    }
    @Published var subtitlesEnabled: Bool = false {
        didSet { updateSubtitleDisplay() }
    }
    @Published var subtitleOffset: Double = 0.0 {
        didSet { updateSubtitleDisplay() }
    }
    @Published var currentSubtitleText: String = ""
    @Published var playbackFailed: Bool = false
    @Published var playbackErrorMessage: String = ""
    @Published var isLoading: Bool = false
    @Published var playbackFinished: Bool = false
    @Published var playbackRate: Float = 1.0 {
        didSet {
            guard playbackRate.isFinite, playbackRate > 0, playbackRate <= 4 else {
                playbackRate = oldValue
                return
            }
            if playbackRequested, player.currentItem?.status == .readyToPlay, !isFastSeeking,
               player.rate != playbackRate {
                player.rate = playbackRate
            }
        }
    }

    private(set) var isFastSeeking: Bool = false
    @Published private(set) var playbackRequested: Bool = false
    @Published var volume: Float = 1.0 {
        didSet {
            let clamped = volume.isFinite ? min(max(volume, 0), 1) : oldValue
            if volume != clamped {
                volume = clamped
                return
            }
            if player.volume != volume { player.volume = volume }
            if !isSynchronizingAudioState, volume > 0, oldValue.isFinite, isMuted { isMuted = false }
        }
    }

    @Published var isMuted: Bool = false {
        didSet { if player.isMuted != isMuted { player.isMuted = isMuted } }
    }
    let player = AVPlayer()
    
    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var volumeObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var isSynchronizingAudioState = false
    private var loadTask: Task<Void, Never>?
    private var loadIdentifier = UUID()
    private var preparedMedia: PreparedMedia?
    private var scopedURL: URL?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var subtitleLoadTask: Task<Void, Never>?
    private var subtitleLoadIdentifier = UUID()
    private var subtitleMaximumEnds: [Double] = []
    private var subtitleOrder: [Int] = []
    private var fastSeekTask: Task<Void, Never>?
    private var fastSeekDirection: Int?
    private var seekIdentifier = UUID()
    private var isSeeking = false
    
    init() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isScrubbing, !self.isSeeking, self.player.currentItem != nil {
                    // Read current state when this callback reaches the main actor;
                    // its supplied timestamp may belong to an item already replaced.
                    let seconds = self.player.currentTime().seconds
                    if seconds.isFinite { self.currentTime = max(0, seconds) }
                }
                self.updateSubtitleDisplay()
            }
        }
        
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isLoading, !self.isFastSeeking,
                      player.currentItem?.status == .readyToPlay else { return }
                // Native controls and PiP can change the player without calling
                // this model. Read the latest rate so old callbacks cannot undo
                // a newer command; internal hold pauses retain their own intent.
                let rate = player.rate
                let requested = rate != 0
                if self.playbackRequested != requested { self.playbackRequested = requested }
                if requested {
                    self.playbackFinished = false
                    if rate > 0, rate <= 4, self.playbackRate != rate { self.playbackRate = rate }
                }
            }
        }
        volumeObservation = player.observe(\.volume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.synchronizeAudioStateFromPlayer() }
        }
        muteObservation = player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.synchronizeAudioStateFromPlayer() }
        }
    }

    private func synchronizeAudioStateFromPlayer() {
        // Reflect native controls without applying the unmute-on-adjustment
        // policy reserved for volume changes requested through this model.
        isSynchronizingAudioState = true
        defer { isSynchronizingAudioState = false }
        if volume != player.volume { volume = player.volume }
        if isMuted != player.isMuted { isMuted = player.isMuted }
    }
    
    deinit {
        loadTask?.cancel()
        subtitleLoadTask?.cancel()
        fastSeekTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        preparedMedia?.removeTemporaryFiles()
        scopedURL?.stopAccessingSecurityScopedResource()
    }
    
    func load(url: URL) {
        teardown()
        currentTime = 0
        duration = 0
        playbackFailed = false
        playbackErrorMessage = ""
        isLoading = true
        playbackRequested = true
        currentFileName = url.lastPathComponent
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        let identifier = loadIdentifier
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try await Self.prepareMedia(url: url)
            }
            do {
                let media = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.loadIdentifier == identifier, !Task.isCancelled else {
                    media.removeTemporaryFiles()
                    return
                }
                self.preparedMedia = media
                self.attach(AVPlayerItem(url: media.url))
                self.loadTask = nil
            } catch {
                guard let self, self.loadIdentifier == identifier, !Task.isCancelled else { return }
                self.failPlayback(error)
            }
        }
    }

    nonisolated private static func prepareMedia(url: URL) async throws -> PreparedMedia {
        // Keep this access alive through asset inspection, even if the model closes.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let media = try HEVCCompatibility.prepare(url: url)
        do {
            let asset = AVURLAsset(url: media.url)
            // An item can play audio despite having an unsupported video track.
            for track in try await asset.loadTracks(withMediaType: .video) {
                try Task.checkCancellation()
                guard try await track.load(.isDecodable) else {
                    throw NSError(domain: "SwiftPlayer", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "This device cannot decode this video's codec or resolution."
                    ])
                }
            }
            try Task.checkCancellation()
            return media
        } catch {
            media.removeTemporaryFiles()
            throw error
        }
    }

    private func attach(_ item: AVPlayerItem) {
        // Preserve the original pitch for speech and music when playback speed
        // changes, including native controls and accelerated held-key playback.
        item.audioTimePitchAlgorithm = .spectral
        itemDurationObservation = item.observe(\.duration, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                let seconds = item.duration.seconds
                self.duration = seconds.isFinite ? seconds : 0
            }
        }
        
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.isLoading = false
                    if self.playbackRequested { self.player.rate = self.playbackRate }
                } else if item.status == .failed {
                    self.failPlayback(item.error)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter delivers this observer on the main queue. Handle
            // it immediately so it cannot overtake a subsequent seek or replay.
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem === item else { return }
                self.playbackRequested = false
                self.endFastSeeking()
                self.player.pause()
                self.isPlaying = false
                self.currentTime = self.duration
                self.updateSubtitleDisplay()
                self.playbackFinished = true
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.failPlayback(error)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func failPlayback(_ error: Error?) {
        teardown()
        playbackErrorMessage = error?.localizedDescription ?? "This device could not decode this file."
        playbackFailed = true
    }
    
    func togglePlayPause() {
        playbackRequested ? pause() : play()
    }

    func pause() {
        playbackRequested = false
        endFastSeeking()
        player.pause()
        isPlaying = false
    }

    func play() {
        guard isLoading || player.currentItem?.status == .readyToPlay else { return }
        endFastSeeking()
        playbackRequested = true
        if playbackFinished || (duration > 0 && currentTime >= duration) { seek(to: 0) }
        if player.currentItem?.status == .readyToPlay { player.rate = playbackRate }
    }
    
    func volumeUp() {
        volume = min(volume + 0.05, 1.0)
    }

    func volumeDown() {
        volume = max(volume - 0.05, 0.0)
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        let target = min(max(seconds, 0), duration)
        seekIdentifier = UUID()
        let identifier = seekIdentifier
        item.cancelPendingSeeks()
        isSeeking = true
        currentTime = target
        playbackFinished = false
        updateSubtitleDisplay()
        // Let AVFoundation choose a responsive seek position for ordinary playback.
        // Sample-accurate seeks are reserved for explicit decoding tests.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item,
                      self.seekIdentifier == identifier else { return }
                self.isSeeking = false
                if finished, !self.isScrubbing {
                    let actual = self.player.currentTime().seconds
                    if actual.isFinite { self.currentTime = max(0, actual) }
                    self.updateSubtitleDisplay()
                }
            }
        }
    }

    func beginFastSeeking(direction: Int) {
        guard [-1, 1].contains(direction), player.currentItem?.status == .readyToPlay,
              fastSeekDirection != direction else { return }
        endFastSeeking()
        fastSeekDirection = direction
        seek(to: currentTime + Double(direction) * 5)
        fastSeekTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(800))
                try Task.checkCancellation()
                self?.isFastSeeking = true
                if direction > 0, self?.playbackRequested == true {
                    if let rate = self?.playbackRate { self?.player.rate = rate * 4 }
                    return
                }
                // Reverse scrubbing must not compete with normal forward playback.
                self?.player.pause()
                while !Task.isCancelled {
                    guard let time = self?.currentTime, let duration = self?.duration,
                          direction < 0 ? time > 0 : time < duration else { return }
                    self?.seek(to: time + Double(direction))
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch { /* Releasing a key or closing playback cancels the hold. */ }
        }
    }

    func endFastSeeking() {
        fastSeekTask?.cancel()
        fastSeekTask = nil
        fastSeekDirection = nil
        guard isFastSeeking else { return }
        isFastSeeking = false
        if playbackRequested, player.currentItem?.status == .readyToPlay {
            player.rate = playbackRate
        } else {
            player.pause()
        }
    }

    func loadSubtitles(url: URL) {
        subtitleLoadTask?.cancel()
        subtitleLoadIdentifier = UUID()
        let identifier = subtitleLoadIdentifier
        subtitleLoadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { parseSubtitles(from: url) }
            let cues = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard let self, self.subtitleLoadIdentifier == identifier, !Task.isCancelled else { return }
            self.subtitleCues = cues
            self.subtitlesEnabled = !cues.isEmpty
            self.subtitleLoadTask = nil
        }
    }
    
    func updateSubtitleDisplay() {
        guard subtitlesEnabled, !subtitleCues.isEmpty else {
            if !currentSubtitleText.isEmpty { currentSubtitleText = "" }
            return
        }
        let adjustedTime = currentTime - subtitleOffset
        // Prefix maximum end times support overlapping cues while skipping all
        // expired entries in logarithmic time, including after backward seeks.
        var lower = 0
        var upper = subtitleMaximumEnds.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if subtitleMaximumEnds[middle] <= adjustedTime { lower = middle + 1 }
            else { upper = middle }
        }
        var text = ""
        if lower < subtitleCues.count {
            for index in subtitleOrder[lower...] {
                let cue = subtitleCues[index]
                if cue.start > adjustedTime { break }
                if cue.end > adjustedTime { text = cue.text; break }
            }
        }
        if currentSubtitleText != text { currentSubtitleText = text }
    }
    /// Call on window close / app termination to release decoder resources immediately.
    func teardown() {
        playbackRequested = false
        endFastSeeking()
        loadIdentifier = UUID()
        loadTask?.cancel()
        loadTask = nil
        subtitleLoadIdentifier = UUID()
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        seekIdentifier = UUID()
        isSeeking = false
        itemStatusObservation = nil
        itemDurationObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        preparedMedia?.removeTemporaryFiles()
        preparedMedia = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        isPlaying = false
        isLoading = false
        playbackFinished = false
        playbackFailed = false
        playbackErrorMessage = ""
        isScrubbing = false
        currentTime = 0
        duration = 0
        currentFileName = ""
        subtitleCues = []
        subtitlesEnabled = false
        subtitleOffset = 0
        currentSubtitleText = ""
    }
}
