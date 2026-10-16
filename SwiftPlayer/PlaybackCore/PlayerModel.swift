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
    @Published private(set) var sourceURL: URL?
    @Published var currentFileName: String = ""
    @Published var subtitleCues: [SubtitleCue] = [] {
        didSet {
            cancelSubtitleImage()
            hasStyledSubtitles = subtitleCues.contains { $0.styled != nil }
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
        didSet {
            if mediaControls.subtitleDelay != subtitleOffset { mediaControls.subtitleDelay = subtitleOffset }
            updateSubtitleDisplay()
        }
    }
    @Published var currentSubtitleText: String = ""
    @Published private(set) var currentSubtitleImage: SubtitleImageFrame?
    private var subtitleImageTask: Task<Void, Never>?
    private var subtitleImageIdentifier = UUID()
    private var renderedSubtitleKey: String?
    private var subtitleStyleObservation: AnyCancellable?
    private var hasStyledSubtitles = false
    @Published var playbackFailed: Bool = false
    @Published var playbackErrorMessage: String = ""
    @Published var isLoading: Bool = false
    @Published private(set) var closedAtEnd = false
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
    @Published private(set) var maximumVolume: Float = 2
    private let audioGain = AudioGainController()
    private var audioProcessingObservation: AnyCancellable?
    private var maximumVolumeObservation: AnyCancellable?
    @Published var volume: Float = 1.0 {
        didSet {
            let clamped = volume.isFinite ? min(max(volume, 0), maximumVolume) : oldValue
            if volume != clamped {
                volume = clamped
                return
            }
            audioGain.setVolume(volume)
            let nativeVolume = min(volume, 1)
            if player.volume != nativeVolume { player.volume = nativeVolume }
            if volume == 0 { isMuted = true }
            else if !isSynchronizingAudioState, oldValue.isFinite, isMuted { isMuted = false }
            if preferences?.rememberVolume == true { preferences?.savedVolume = volume }
        }
    }

    @Published var isMuted: Bool = false {
        didSet {
            if volume == 0, !isMuted { isMuted = true; return }
            if player.isMuted != isMuted { player.isMuted = isMuted }
            if preferences?.rememberVolume == true { preferences?.savedMute = isMuted }
        }
    }
    let player: AVPlayer
    let mediaControls: PlayerMediaControls
    private let preferences: PlayerPreferences?
    private let history: PlaybackHistoryStore?
    private var historySession: PlaybackHistoryStore.Session?
    private var historyCompleted = false
    private var requestedStartTime: Double?
    
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
    private var externalSubtitleLocation: (url: URL, folder: URL?, companion: URL?, track: Int?)?
    private var subtitleMaximumEnds: [Double] = []
    private var subtitleOrder: [Int] = []
    private var fastSeekTask: Task<Void, Never>?
    private var fastSeekDirection: Int?
    private var fastSeekRate: Float?
    private var seekIdentifier = UUID()
    private var isSeeking = false
    
    init(preferences: PlayerPreferences? = nil, history: PlaybackHistoryStore? = nil) {
        let nativePlayer = AVPlayer()
        player = nativePlayer
        self.preferences = preferences
        self.history = history
        mediaControls = PlayerMediaControls(player: nativePlayer, preferences: preferences)
        mediaControls.onSeek = { [weak self] time in self?.seek(to: time) }
        mediaControls.onSubtitleDelayChanged = { [weak self] delay in
            if self?.subtitleOffset != delay { self?.subtitleOffset = delay }
        }
        mediaControls.onRestoreExternalSubtitles = { [weak self] url, companion, track in
            guard let self else { return }
            self.loadSubtitles(url: url, encoding: self.mediaControls.externalSubtitleEncoding, companion: companion, track: track)
        }
        if let preferences {
            subtitleStyleObservation = preferences.$useSubtitleFileStyles.dropFirst().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.cancelSubtitleImage(); self?.updateSubtitleDisplay() }
            }
            audioProcessingObservation = preferences.$limitAudioPeaks.combineLatest(preferences.$normalizeAudio)
                .sink { [weak self] limiter, normalization in
                    self?.audioGain.configure(limiter: limiter, normalization: normalization)
                }
        }
        maximumVolume = preferences?.maximumVolume ?? 2
        maximumVolumeObservation = preferences?.$maximumVolume.removeDuplicates().sink { [weak self] limit in
            guard let self, limit.isFinite else { return }
            let limit = min(max(limit, 1), 4)
            self.maximumVolume = limit
            if self.volume > limit {
                self.isSynchronizingAudioState = true
                self.volume = limit
                self.isSynchronizingAudioState = false
            }
        }
        if let preferences, preferences.rememberVolume {
            volume = preferences.savedVolume
            isMuted = preferences.savedMute
            player.volume = min(volume, 1)
            audioGain.setVolume(volume)
            player.isMuted = isMuted || volume == 0
        }
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
                self.mediaControls.tick(time: self.player.currentTime().seconds, duration: self.duration)
                self.saveHistory()
            }
        }
        
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        rateObservation = player.observe(\.rate, options: [.old, .new]) { [weak self] player, change in
            guard change.oldValue != change.newValue, let changedItem = player.currentItem else { return }
            // Main-thread transport commands must update intent before a
            // queued ready callback can apply initial autoplay.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.synchronizePlaybackIntent(from: player, item: changedItem) }
            } else {
                Task { @MainActor [weak self] in
                    self?.synchronizePlaybackIntent(from: player, item: changedItem)
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

    private func synchronizePlaybackIntent(from player: AVPlayer, item: AVPlayerItem) {
        guard player.currentItem === item, item.status == .readyToPlay else { return }
        // Background callbacks can arrive later; always read the latest rate.
        let rate = player.rate
        if isFastSeeking {
            // Ignore our own hold transport, but let native controls interrupt
            // it without restoring the old rate over the user's new command.
            guard rate != fastSeekRate else { return }
            cancelFastSeekTask()
        } else if fastSeekDirection != nil, rate != (playbackRequested ? playbackRate : 0) {
            // Before the hold threshold, transport still uses the ordinary rate.
            // A new native command must also cancel the pending hold timer.
            cancelFastSeekTask()
        }
        let requested = rate != 0
        if playbackRequested != requested {
            if !requested { saveHistory(force: true) }
            playbackRequested = requested
        }
        if requested {
            historyCompleted = false
            playbackFinished = false
            if rate > 0, rate <= 4, playbackRate != rate { playbackRate = rate }
        }
    }

    private func synchronizeAudioStateFromPlayer() {
        // Reflect native controls without applying the unmute-on-adjustment
        // policy reserved for volume changes requested through this model.
        isSynchronizingAudioState = true
        defer { isSynchronizingAudioState = false }
        if min(volume, 1) != player.volume { volume = player.volume }
        if isMuted != player.isMuted { isMuted = player.isMuted }
    }
    
    deinit {
        loadTask?.cancel()
        subtitleLoadTask?.cancel()
        subtitleImageTask?.cancel()
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
    
    func load(url: URL, startAt: Double? = nil) {
        teardown()
        requestedStartTime = startAt.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        sourceURL = url
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
                let item = AVPlayerItem(url: media.url)
                do { item.audioMix = try await self.audioGain.makeMix(for: item.asset) }
                catch { media.removeTemporaryFiles(); throw error }
                guard self.loadIdentifier == identifier, !Task.isCancelled else {
                    media.removeTemporaryFiles()
                    return
                }
                self.preparedMedia = media
                self.attach(item, sourceURL: url)
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

    private func attach(_ item: AVPlayerItem, sourceURL: URL) {
        mediaControls.attach(to: item, sourceURL: sourceURL, startAt: requestedStartTime)
        requestedStartTime = nil
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
                    self.mediaControls.itemBecameReady(item)
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    if self.historySession == nil { self.historySession = self.history?.begin(sourceURL, duration: self.duration) }
                    self.mediaControls.tick(time: self.player.currentTime().seconds, duration: self.duration)
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
                self.historyCompleted = true
                self.saveHistory(force: true, finished: true)
                switch self.preferences?.afterPlayback ?? .stay {
                case .stay: break
                case .rewind: self.seek(to: 0)
                case .repeatFile: self.play()
                case .close:
                    self.teardown()
                    self.closedAtEnd = true
                }
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
        saveHistory(force: true)
        mediaControls.savePosition()
        playbackRequested = false
        endFastSeeking()
        player.pause()
        isPlaying = false
    }

    func play() {
        guard isLoading || player.currentItem?.status == .readyToPlay else { return }
        historyCompleted = false
        endFastSeeking()
        playbackRequested = true
        if playbackFinished || (duration > 0 && currentTime >= duration) { seek(to: 0) }
        if player.currentItem?.status == .readyToPlay { player.rate = playbackRate }
    }
    
    func volumeUp() {
        volume = min((volume * 1_000_000 + 50_000).rounded() / 1_000_000, maximumVolume)
    }

    func volumeDown() {
        volume = max((volume * 1_000_000 - 50_000).rounded() / 1_000_000, 0)
    }

    func canStepFrame(direction: Int) -> Bool {
        guard let item = player.currentItem, item.status == .readyToPlay,
              item.presentationSize.width > 0, item.presentationSize.height > 0 else { return false }
        switch direction {
        case -1: return item.canStepBackward
        case 1: return item.canStepForward
        default: return false
        }
    }

    /// Step the native video timeline, including variable-frame-rate media.
    /// Ordinary seeks retain their default tolerance; no nominal-FPS estimate is used.
    func stepFrame(direction: Int) {
        guard canStepFrame(direction: direction), let item = player.currentItem else { return }
        // Repeated steps while paused must not force a preferences write per frame.
        if playbackRequested || player.rate != 0 { pause() }
        else { endFastSeeking() }
        isPlaying = false
        seekIdentifier = UUID()
        item.cancelPendingSeeks()
        isSeeking = false
        isScrubbing = false
        playbackFinished = false
        historyCompleted = false
        item.step(byCount: direction)
        // The existing native time observer updates position and captions when
        // the asynchronous step reaches its destination.
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
        // Frame stepping uses the separate native step command.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item,
                      self.seekIdentifier == identifier else { return }
                self.isSeeking = false
                if finished, !self.isScrubbing {
                    let actual = self.player.currentTime().seconds
                    if actual.isFinite { self.currentTime = max(0, actual) }
                    self.updateSubtitleDisplay()
                    if !self.playbackRequested, !self.isFastSeeking { self.saveHistory(force: true) }
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
                    if let rate = self?.playbackRate {
                        self?.fastSeekRate = rate * 4
                        self?.player.rate = rate * 4
                    }
                    return
                }
                // Reverse scrubbing must not compete with normal forward playback.
                self?.fastSeekRate = 0
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

    private func cancelFastSeekTask() {
        fastSeekTask?.cancel()
        fastSeekTask = nil
        fastSeekDirection = nil
        fastSeekRate = nil
        isFastSeeking = false
    }

    func endFastSeeking() {
        let wasFastSeeking = isFastSeeking
        cancelFastSeekTask()
        guard wasFastSeeking else { return }
        if playbackRequested, player.currentItem?.status == .readyToPlay {
            player.rate = playbackRate
        } else {
            player.pause()
        }
    }

    var hasPendingSubtitleLoad: Bool { subtitleLoadTask != nil }

    func reloadSubtitles(encoding: SubtitleEncoding) {
        guard let location = externalSubtitleLocation else { return }
        loadSubtitles(url: location.url, accessing: location.folder, encoding: encoding, activate: false, companion: location.companion, track: location.track)
    }

    func loadSubtitles(url: URL, accessing folder: URL? = nil,
                       encoding: SubtitleEncoding = .automatic, activate: Bool = true, companion: URL? = nil, track: Int? = nil) {
        subtitleLoadTask?.cancel()
        subtitleLoadIdentifier = UUID()
        let identifier = subtitleLoadIdentifier
        let selectionRevision = mediaControls.subtitleSelectionRevision
        let languages = preferences?.subtitleLanguage.isEmpty == false ? [preferences!.subtitleLanguage] : Locale.preferredLanguages
        let pair = ["idx", "sub"].contains(url.pathExtension.lowercased()) ? companion ?? url.deletingPathExtension().appendingPathExtension(url.pathExtension.lowercased() == "idx" ? "sub" : "idx") : nil
        subtitleLoadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let folderScoped = folder?.startAccessingSecurityScopedResource() ?? false
                let scoped = url.startAccessingSecurityScopedResource()
                let pairScoped = pair?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    if folderScoped { folder?.stopAccessingSecurityScopedResource() }
                    if pairScoped { pair?.stopAccessingSecurityScopedResource() }
                }
                return (parseSubtitles(from: url, encoding: encoding, companion: pair, track: track, preferredLanguages: languages),
                        SubtitleFileReference.capture(url, companion: pair, subtitleTrack: track))
            }
            let (cues, reference) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard let self, self.subtitleLoadIdentifier == identifier, !Task.isCancelled else { return }
            guard !cues.isEmpty else {
                if self.mediaControls.subtitleSelectionRevision == selectionRevision {
                    self.mediaControls.externalSubtitlesUnavailable()
                }
                self.subtitleLoadTask = nil
                return
            }
            self.subtitleCues = cues
            self.externalSubtitleLocation = (url, folder, pair, track)
            self.subtitlesEnabled = true
            self.mediaControls.useExternalSubtitles(named: url.lastPathComponent, reference: reference,
                encoding: encoding, activate: activate && self.mediaControls.subtitleSelectionRevision == selectionRevision)
            if cues.contains(where: { $0.styled?.hasUnsupportedEffects == true }) { self.mediaControls.noteUnsupportedSubtitleEffects() }
            self.subtitleLoadTask = nil
        }
    }
    
    func updateSubtitleDisplay() {
        guard subtitlesEnabled, !subtitleCues.isEmpty else {
            if !currentSubtitleText.isEmpty { currentSubtitleText = "" }
            cancelSubtitleImage()
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
        var activeIndex: Int?
        var styledIndices: [Int] = []
        if lower < subtitleCues.count {
            for index in subtitleOrder[lower...] {
                let cue = subtitleCues[index]
                if cue.start > adjustedTime { break }
                if cue.end > adjustedTime {
                    if activeIndex == nil { text = cue.text; activeIndex = index }
                    if cue.styled != nil, styledIndices.count < 64 { styledIndices.append(index) }
                    if !hasStyledSubtitles || preferences?.useSubtitleFileStyles == false { break }
                }
            }
        }
        if currentSubtitleText != text { currentSubtitleText = text }
        let bitmap = activeIndex.flatMap { subtitleCues[$0].bitmap }
        let styled = preferences?.useSubtitleFileStyles == false ? [] : styledIndices.compactMap { subtitleCues[$0].styled }
        if mediaControls.subtitleSelection == "external", bitmap != nil || !styled.isEmpty {
            let animated = styled.contains(where: \.animated)
            let identity = "\(activeIndex ?? -1):\(styledIndices):"
            let key = identity + "\(animated ? floor(adjustedTime * 10) : 0)"
            if renderedSubtitleKey != key {
                let keepPrevious = bitmap == nil && renderedSubtitleKey?.hasPrefix(identity) == true
                cancelSubtitleImage(clear: !keepPrevious)
                renderedSubtitleKey = key
                let generation = subtitleImageIdentifier
                subtitleImageTask = Task { [weak self] in
                    let worker = Task.detached(priority: .userInitiated) {
                        if let bitmap { return try bitmap.render() }
                        return try ASSSubtitleRenderer.render(styled, at: adjustedTime)
                    }
                    let image = try? await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard let self, self.subtitleImageIdentifier == generation, !Task.isCancelled else { return }
                    self.currentSubtitleImage = image
                    self.subtitleImageTask = nil
                    if image == nil { self.mediaControls.externalSubtitlesUnavailable() }
                }
            }
        } else { cancelSubtitleImage() }
    }

    /// Frame export must sample the captured clock, independently of UI delivery.
    func externalSubtitleSnapshot(at seconds: Double) -> (text: String, image: SubtitleRenderRequest?) {
        guard seconds.isFinite, subtitlesEnabled, mediaControls.subtitleSelection == "external" else { return ("", nil) }
        let time = seconds - subtitleOffset
        var text: String?, styled: [ASSSubtitle] = []
        for index in subtitleOrder {
            let cue = subtitleCues[index]
            if cue.start > time { break }
            guard cue.end > time else { continue }
            if text == nil { text = cue.text }
            if let bitmap = cue.bitmap { return ("", .bitmap(bitmap)) }
            if let style = cue.styled, preferences?.useSubtitleFileStyles != false, styled.count < 64 { styled.append(style) }
            else if !hasStyledSubtitles || preferences?.useSubtitleFileStyles == false { break }
        }
        return (text ?? "", styled.isEmpty ? nil : .styled(styled, time))
    }

    private func cancelSubtitleImage(clear: Bool = true) {
        subtitleImageIdentifier = UUID()
        subtitleImageTask?.cancel()
        subtitleImageTask = nil
        renderedSubtitleKey = nil
        if clear, currentSubtitleImage != nil { currentSubtitleImage = nil }
    }
    /// Call on window close / app termination to release decoder resources immediately.
    func teardown() {
        cancelSubtitleImage()
        saveHistory(force: true)
        historySession = nil
        historyCompleted = false
        requestedStartTime = nil
        mediaControls.detach()
        playbackRequested = false
        endFastSeeking()
        loadIdentifier = UUID()
        loadTask?.cancel()
        loadTask = nil
        subtitleLoadIdentifier = UUID()
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        seekIdentifier = UUID()
        externalSubtitleLocation = nil
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
        closedAtEnd = false
        playbackFailed = false
        playbackErrorMessage = ""
        isScrubbing = false
        currentTime = 0
        duration = 0
        currentFileName = ""
        sourceURL = nil
        subtitleCues = []
        subtitlesEnabled = false
        subtitleOffset = 0
        currentSubtitleText = ""
    }

    private func saveHistory(force: Bool = false, finished: Bool = false) {
        guard let session = historySession else { return }
        let completed = finished || historyCompleted
        history?.update(session, position: completed ? duration : player.currentTime().seconds, duration: duration,
                        finished: completed, force: force)
    }
}
