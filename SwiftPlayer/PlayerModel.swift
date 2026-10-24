import AVFoundation
import SwiftUI
import Combine

/// Extensions AVFoundation can natively decode (container-level allow-list
/// for the open panel / drop validation). Actual playability still depends
/// on the codec inside the file, but this covers what Apple ships decoders for.
let supportedExtensions: [String] = [
    "mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "aiff", "caf"
] // audio containers
nonisolated struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

let supportedSubtitleExtensions: [String] = ["srt", "vtt", "ass", "ssa"]

nonisolated func decodeSubtitleText(_ data: Data) -> String? {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
        if let text = String(data: data, encoding: .utf16) { return text }
    }
    return String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .windowsCP1252)
        ?? String(data: data, encoding: .isoLatin1)
}

nonisolated func parseSubtitles(from url: URL) -> [SubtitleCue] {
    guard let data = try? Data(contentsOf: url), let decoded = decodeSubtitleText(data) else { return [] }
    // Normalize line endings: CRLF files would otherwise never match the "\n\n" block split.
    let content = decoded
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "srt":
        return parseSRT(content)
    case "vtt":
        return parseVTT(content)
    case "ass", "ssa":
        return parseASS(content)
    default:
        return []
    }
}

nonisolated private func timeToSeconds(_ h: Int, _ m: Int, _ s: Int, _ ms: Int) -> Double {
    Double(h) * 3600 + Double(m) * 60 + Double(s) + Double(ms) / 1000.0
}

nonisolated private func parseSRT(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    let blocks = content.components(separatedBy: "\n\n")
    let timePattern = #"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})"#
    guard let regex = try? NSRegularExpression(pattern: timePattern) else { return [] }

    for block in blocks {
        let lines = block.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { continue }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range) {
                guard let lineIndex = lines.firstIndex(of: line) else { continue }
                let textLines = lines[(lineIndex + 1)...]
                let text = textLines.joined(separator: "\n")
                if let start = extractTime(match, in: line, groups: 1...4),
                   let end = extractTime(match, in: line, groups: 5...8) {
                    cues.append(SubtitleCue(start: start, end: end, text: stripTags(text)))
                }
                break
            }
        }
    }
    return cues
}

nonisolated private func extractTime(_ match: NSTextCheckingResult, in line: String, groups: ClosedRange<Int>) -> Double? {
    func value(_ idx: Int) -> Int? {
        guard let r = Range(match.range(at: idx), in: line) else { return nil }
        return Int(line[r])
    }
    guard let h = value(groups.lowerBound),
          let m = value(groups.lowerBound + 1),
          let s = value(groups.lowerBound + 2),
          let ms = value(groups.lowerBound + 3) else { return nil }
    return timeToSeconds(h, m, s, ms)
}

nonisolated private func parseVTT(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    let blocks = content.components(separatedBy: "\n\n")
    let timePattern = #"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[.,](\d{3})"#
    guard let regex = try? NSRegularExpression(pattern: timePattern) else { return [] }

    for block in blocks {
        let lines = block.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { continue }
        for (idx, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range) {
                let text = lines[(idx + 1)...].joined(separator: "\n")
                if let start = extractTime(match, in: line, groups: 1...4),
                   let end = extractTime(match, in: line, groups: 5...8) {
                    cues.append(SubtitleCue(start: start, end: end, text: stripTags(text)))
                }
                break
            }
        }
    }
    return cues
}

nonisolated private func parseASS(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    let lines = content.components(separatedBy: .newlines)
    let timePattern = #"^Dialogue:\s*\d+,(\d+):(\d{2}):(\d{2})[.,](\d{2,3}),(\d+):(\d{2}):(\d{2})[.,](\d{2,3}),"#
    guard let regex = try? NSRegularExpression(pattern: timePattern) else { return [] }

    for line in lines where line.hasPrefix("Dialogue:") {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { continue }
        func value(_ idx: Int) -> Int? {
            guard let r = Range(match.range(at: idx), in: line) else { return nil }
            return Int(line[r])
        }
        guard let sh = value(1), let sm = value(2), let ss = value(3), let scs = value(4),
              let eh = value(5), let em = value(6), let es = value(7), let ecs = value(8) else { continue }

        // Fractions are centiseconds ("12") or milliseconds ("123"); scale by digit count.
        func milliseconds(_ idx: Int, _ fraction: Int) -> Int {
            guard let r = Range(match.range(at: idx), in: line) else { return fraction * 10 }
            return line[r].count >= 3 ? fraction : fraction * 10
        }
        let start = timeToSeconds(sh, sm, ss, milliseconds(4, scs))
        let end = timeToSeconds(eh, em, es, milliseconds(8, ecs))

        // Text is everything after the 9th comma-separated field.
        let fields = line.components(separatedBy: ",")
        guard fields.count > 9 else { continue }
        let text = fields[9...].joined(separator: ",")
        cues.append(SubtitleCue(start: start, end: end, text: stripASSTags(text)))
    }
    return cues
}

nonisolated private func stripTags(_ text: String) -> String {
    text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
}

nonisolated private func stripASSTags(_ text: String) -> String {
    let noOverrides = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    return noOverrides.replacingOccurrences(of: #"\\N|\\n"#, with: "\n", options: .regularExpression)
}

@MainActor
final class PlayerModel: ObservableObject {
   
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing: Bool = false
    @Published var currentFileName: String = ""
    @Published var subtitleCues: [SubtitleCue] = []
    @Published var subtitlesEnabled: Bool = false
    @Published var subtitleOffset: Double = 0.0
    @Published var currentSubtitleText: String = ""
    @Published var playbackFailed: Bool = false
    @Published var playbackFinished: Bool = false
    @Published var playbackRate: Float = 1.0 {
        didSet {
            // Only touch the rate while playing: assigning a non-zero rate to a paused player resumes it.
            if !isFastSeeking && isPlaying {
                player.rate = playbackRate
            }
        }
    }

    var isFastSeeking: Bool = false
    @Published var volume: Float = 1.0 {
        didSet {
            player.volume = volume
            if volume > 0 && isMuted { isMuted = false }
        }
    }

    @Published var isMuted: Bool = false {
        didSet { player.isMuted = isMuted }
    }
    let player = AVPlayer()
    
    private let history: HistoryStore
    private var currentEntryID: UUID?
    private var securityScopedURL: URL?
    private var pendingResume: Double?
    private var lastSavedTime: Double = 0
    
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    
    // Seeks are coalesced: while one is in flight only the latest requested target is kept.
    private var isSeekInProgress = false
    private var pendingSeekTime: CMTime?
    
    init(history: HistoryStore = .shared) {
        self.history = history
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isScrubbing {
                    let seconds = time.seconds.isFinite ? time.seconds : 0
                    if self.currentTime != seconds { self.currentTime = seconds }
                    if abs(seconds - self.lastSavedTime) >= 5 {
                        self.lastSavedTime = seconds
                        self.persistProgress()
                    }
                }
                self.updateSubtitleDisplay()
            }
        }
        
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            let isPlaying = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
            }
        }
    }
    
    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
    
    /// - Parameter securityScoped: true when `url` came from a history bookmark and needs
    ///   `startAccessingSecurityScopedResource()`. Files from the open panel or a drop are already accessible.
    func load(url: URL, securityScoped: Bool = false) {
        // Keep the previous file's position, then release its resources before attaching a new one.
        persistProgress()
        releaseCurrentItem()
        if securityScoped, url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
        
        player.pause()
        isPlaying = false
        currentTime = 0
        duration = 0
        lastSavedTime = 0
        playbackFinished = false
        playbackFailed = false
        isSeekInProgress = false
        pendingSeekTime = nil
        
        let entry = history.record(url: url)
        currentEntryID = entry.id
        pendingResume = history.resumePosition(for: entry)
        
        let item = AVPlayerItem(url: url)
        currentFileName = url.lastPathComponent
        
        itemDurationObservation = item.observe(\.duration, options: [.new]) { item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = item.duration.seconds
                self.duration = seconds.isFinite ? seconds : 0
            }
        }
        
        itemStatusObservation = item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.status == .readyToPlay {
                    self.beginPlayback()
                } else if item.status == .failed {
                    self.playbackFailed = true
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackFinished = true
                self.persistProgress()
            }
        }
        player.replaceCurrentItem(with: item)
    }
    
    private func beginPlayback() {
        guard let resume = pendingResume else {
            startPlaying()
            return
        }
        pendingResume = nil
        currentTime = resume
        lastSavedTime = resume
        player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startPlaying() }
        }
    }
    
    private func startPlaying() {
        player.rate = playbackRate
        isPlaying = true
    }
    
    private func releaseCurrentItem() {
        itemDurationObservation = nil
        itemStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
    
    /// Writes the current position to the history. Finished files are stored as position 0.
    func persistProgress() {
        guard let id = currentEntryID, pendingResume == nil, duration > 0 else { return }
        let finished = playbackFinished || currentTime >= duration - HistoryStore.finishedMargin
        history.updatePosition(id: id, position: finished ? 0 : currentTime, duration: duration)
    }
    
    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.rate = playbackRate
        }
    }
    
    func volumeUp() {
        volume = min(volume + 0.05, 1.0)
    }

    func volumeDown() {
        volume = max(volume - 0.05, 0.0)
    }
    
    func seek(to seconds: Double) {
        var target = max(seconds, 0)
        if duration > 0 { target = min(target, duration) }
        currentTime = target
        
        let time = CMTime(seconds: target, preferredTimescale: 600)
        if isSeekInProgress {
            pendingSeekTime = time
        } else {
            startSeek(to: time)
        }
    }
    
    private func startSeek(to time: CMTime) {
        isSeekInProgress = true
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeekInProgress = false
                if let next = self.pendingSeekTime {
                    self.pendingSeekTime = nil
                    self.startSeek(to: next)
                }
            }
        }
    }
    
    func loadSubtitles(url: URL) {
        Task {
            let cues = await Task.detached(priority: .userInitiated) { parseSubtitles(from: url) }.value
            subtitleCues = cues
            subtitlesEnabled = true
            updateSubtitleDisplay()
        }
    }
    
    func updateSubtitleDisplay() {
        var text = ""
        if subtitlesEnabled, !subtitleCues.isEmpty {
            let adjustedTime = currentTime - subtitleOffset
            if let cue = subtitleCues.first(where: { adjustedTime >= $0.start && adjustedTime <= $0.end }) {
                text = cue.text
            }
        }
        // Assigning an unchanged value would still re-render every observing view.
        if currentSubtitleText != text { currentSubtitleText = text }
    }
    /// Call on window close / app termination to release decoder resources immediately.
    func teardown() {
        persistProgress()
        player.pause()
        player.replaceCurrentItem(with: nil)
        releaseCurrentItem()
        currentEntryID = nil
        pendingResume = nil
        playbackFinished = false
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%d:%02d", m, s)
    }
}

