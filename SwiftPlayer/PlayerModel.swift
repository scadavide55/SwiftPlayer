import AVFoundation
import SwiftUI
import Combine

/// Extensions AVFoundation can natively decode (container-level allow-list
/// for the open panel / drop validation). Actual playability still depends
/// on the codec inside the file, but this covers what Apple ships decoders for.
let supportedExtensions: [String] = [
    "mp4", "mov", "m4v", "mp3", "m4a", "aac", "wav", "aiff", "caf"
] // audio containers
struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

let supportedSubtitleExtensions: [String] = ["srt", "vtt", "ass", "ssa"]

func parseSubtitles(from url: URL) -> [SubtitleCue] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
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

private func timeToSeconds(_ h: Int, _ m: Int, _ s: Int, _ ms: Int) -> Double {
    Double(h) * 3600 + Double(m) * 60 + Double(s) + Double(ms) / 1000.0
}

private func parseSRT(_ content: String) -> [SubtitleCue] {
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

private func extractTime(_ match: NSTextCheckingResult, in line: String, groups: ClosedRange<Int>) -> Double? {
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

private func parseVTT(_ content: String) -> [SubtitleCue] {
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

private func parseASS(_ content: String) -> [SubtitleCue] {
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

        let start = timeToSeconds(sh, sm, ss, scs * 10)
        let end = timeToSeconds(eh, em, es, ecs * 10)

        // Text is everything after the 9th comma-separated field.
        let fields = line.components(separatedBy: ",")
        guard fields.count > 9 else { continue }
        let text = fields[9...].joined(separator: ",")
        cues.append(SubtitleCue(start: start, end: end, text: stripASSTags(text)))
    }
    return cues
}

private func stripTags(_ text: String) -> String {
    text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
}

private func stripASSTags(_ text: String) -> String {
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
    @Published var playbackErrorMessage: String = ""
    @Published var isLoading: Bool = false
    @Published var playbackFinished: Bool = false
    @Published var playbackRate: Float = 1.0 {
        didSet {
            if !isFastSeeking {
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
    
    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var loadIdentifier = UUID()
    private var preparedMedia: PreparedMedia?
    private var scopedURL: URL?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    
    init() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isScrubbing {
                    self.currentTime = time.seconds.isFinite ? time.seconds : 0
                }
                self.updateSubtitleDisplay()
            }
        }
        
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            let isPlaying = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                self?.isPlaying = isPlaying
            }
        }
    }
    
    deinit {
        loadTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        player.pause()
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
        currentFileName = url.lastPathComponent
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        let identifier = loadIdentifier
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try HEVCCompatibility.prepare(url: url)
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
                let asset = AVURLAsset(url: media.url)
                // An item can play audio despite having an unsupported video track.
                for track in try await asset.loadTracks(withMediaType: .video) {
                    guard try await track.load(.isDecodable) else {
                        throw NSError(domain: "SwiftPlayer", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "macOS cannot decode this video's codec or resolution."
                        ])
                    }
                }
                guard self.loadIdentifier == identifier, !Task.isCancelled else { return }
                self.attach(AVPlayerItem(asset: asset))
            } catch {
                guard let self, self.loadIdentifier == identifier, !Task.isCancelled else { return }
                self.failPlayback(error)
            }
        }
    }

    private func attach(_ item: AVPlayerItem) {
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
                    self.player.rate = self.playbackRate
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
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
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
        playbackErrorMessage = error?.localizedDescription ?? "macOS could not decode this file."
        playbackFailed = true
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
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        Task {
            await player.seek(to: time)
        }
        currentTime = seconds
        
    }
    func loadSubtitles(url: URL) {
        subtitleCues = parseSubtitles(from: url)
        subtitlesEnabled = true
    }
    
    func updateSubtitleDisplay() {
        guard subtitlesEnabled, !subtitleCues.isEmpty else {
            currentSubtitleText = ""
            return
        }
        let adjustedTime = currentTime - subtitleOffset
        if let cue = subtitleCues.first(where: { adjustedTime >= $0.start && adjustedTime <= $0.end }) {
            currentSubtitleText = cue.text
        } else {
            currentSubtitleText = ""
        }
    }
    /// Call on window close / app termination to release decoder resources immediately.
    func teardown() {
        loadIdentifier = UUID()
        loadTask?.cancel()
        loadTask = nil
        itemStatusObservation = nil
        itemDurationObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedMedia?.removeTemporaryFiles()
        preparedMedia = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        isPlaying = false
        isLoading = false
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

