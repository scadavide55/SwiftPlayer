import Foundation
import AVFoundation
import Combine

struct MediaTrackChoice: Identifiable {
    let id: String
    let name: String
    let language: String?
    let forcedOnly: Bool
    let option: AVMediaSelectionOption
}

struct PlaybackChapter: Identifiable {
    let id: Int
    let title: String
    let start: Double
}

struct MediaStreamInfo: Identifiable {
    let id: Int32
    let kind: String
    let codec: String
    let details: String
}

@MainActor
final class PlayerMediaControls: NSObject, ObservableObject, AVPlayerItemLegibleOutputPushDelegate {
    @Published private(set) var subtitleTracks: [MediaTrackChoice] = []
    @Published private(set) var audioTracks: [MediaTrackChoice] = []
    @Published private(set) var chapters: [PlaybackChapter] = []
    @Published private(set) var streams: [MediaStreamInfo] = []
    @Published private(set) var embeddedText = ""
    @Published private(set) var isDiscovering = false
    @Published private(set) var informationError = ""
    @Published var subtitleSelection = "automatic" { didSet { applySubtitleSelection() } }
    @Published var audioSelection = "automatic" { didSet { applyAudioSelection() } }
    @Published private(set) var externalSubtitleName = ""
    var nativeSubtitleRendering = false {
        didSet { legibleOutput?.suppressesPlayerRendering = !nativeSubtitleRendering }
    }
    var onSeek: ((Double) -> Void)?
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private let preferences: PlayerPreferences?
    private var preferenceObserver: AnyCancellable?
    private var discoveryTask: Task<Void, Never>?
    private var identifier = UUID()
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private var sourceURL: URL?
    private var lastSavedTime: Double = 0
    private var pendingResume: Double?

    init(player: AVPlayer, preferences: PlayerPreferences?) {
        self.player = player
        self.preferences = preferences
        super.init()
        preferenceObserver = preferences?.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.subtitleSelection == "automatic" { self.applySubtitleSelection() }
                if self.audioSelection == "automatic" { self.applyAudioSelection() }
            }
        }
    }

    deinit { discoveryTask?.cancel() }

    func attach(to item: AVPlayerItem, sourceURL: URL) {
        detach()
        self.item = item
        self.sourceURL = sourceURL
        pendingResume = preferences?.resumeTime(for: sourceURL)
        subtitleSelection = preferences?.subtitlesByDefault == false ? "off" : "automatic"
        audioSelection = "automatic"
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = !nativeSubtitleRendering
        output.setDelegate(self, queue: .main)
        item.add(output)
        legibleOutput = output
        isDiscovering = true
        let generation = identifier
        let asset = item.asset
        discoveryTask = Task { [weak self, weak item] in
            do {
                let subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
                let audio = try await asset.loadMediaSelectionGroup(for: .audible)
                var chapterGroups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
                if chapterGroups.isEmpty, let locale = try? await asset.load(.availableChapterLocales).first {
                    chapterGroups = (try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle])) ?? []
                }
                var chapters: [PlaybackChapter] = []
                for (index, group) in chapterGroups.enumerated() {
                    let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
                    let title = try? await titleItem?.load(.stringValue)
                    let start = group.timeRange.start.seconds
                    if start.isFinite { chapters.append(PlaybackChapter(id: index, title: title ?? "Chapter \(index + 1)", start: start)) }
                }
                var streams: [MediaStreamInfo] = []
                for track in try await asset.load(.tracks) {
                    try Task.checkCancellation()
                    let formats = try await track.load(.formatDescriptions)
                    let codecs = formats.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) }.joined(separator: ", ")
                    let size = try await track.load(.naturalSize)
                    let rate = try await track.load(.nominalFrameRate)
                    let extendedLanguage = try await track.load(.extendedLanguageTag)
                    let legacyLanguage = try await track.load(.languageCode)
                    let language = extendedLanguage ?? legacyLanguage
                    var details = language ?? "Language unspecified"
                    if track.mediaType == .video { details = "\(Int(abs(size.width))) × \(Int(abs(size.height))), \(String(format: "%.2f", rate)) fps" }
                    if let format = formats.first, let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format), track.mediaType == .audio {
                        details += ", \(audio.pointee.mChannelsPerFrame) channels, \(Int(audio.pointee.mSampleRate)) Hz"
                    }
                    streams.append(MediaStreamInfo(id: track.trackID, kind: Self.kind(track.mediaType), codec: codecs, details: details))
                }
                try Task.checkCancellation()
                guard let self, let item, self.identifier == generation, self.item === item else { return }
                self.subtitleGroup = subtitles
                self.audioGroup = audio
                self.subtitleTracks = Self.choices(subtitles, prefix: "subtitle")
                self.audioTracks = Self.choices(audio, prefix: "audio")
                self.chapters = chapters
                self.streams = streams
                self.applySubtitleSelection()
                self.applyAudioSelection()
                self.isDiscovering = false
                self.discoveryTask = nil
            } catch {
                guard let self, self.identifier == generation, !Task.isCancelled else { return }
                self.informationError = "Some track information could not be loaded."
                self.isDiscovering = false
                self.discoveryTask = nil
            }
        }
    }

    private static func choices(_ group: AVMediaSelectionGroup?, prefix: String) -> [MediaTrackChoice] {
        (group?.options ?? []).enumerated().filter { $0.element.isPlayable }.map { index, option in
            let forced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            return MediaTrackChoice(id: "\(prefix)-\(index)", name: option.displayName + (forced ? " (Forced only)" : ""),
                                    language: option.extendedLanguageTag ?? option.locale?.identifier, forcedOnly: forced, option: option)
        }
    }

    private func preferred(_ tracks: [MediaTrackChoice], language: String) -> MediaTrackChoice? {
        let requested = language.isEmpty ? Locale.preferredLanguages : [language]
        for tag in requested {
            if let exact = tracks.first(where: { $0.language?.replacingOccurrences(of: "_", with: "-").lowercased() == tag.lowercased() }) { return exact }
            let base = tag.lowercased().split(separator: "-").first
            if let match = tracks.first(where: { $0.language?.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first == base }) { return match }
        }
        return nil
    }

    private func applySubtitleSelection() {
        embeddedText = ""
        guard let item, let group = subtitleGroup else { return }
        switch subtitleSelection {
        case "off", "external": item.select(nil, in: group)
        case "automatic":
            let full = subtitleTracks.filter { !$0.forcedOnly }
            let choice = preferred(full, language: preferences?.subtitleLanguage ?? "") ?? full.first ?? subtitleTracks.first
            item.select(choice?.option, in: group)
        default:
            if let choice = subtitleTracks.first(where: { $0.id == subtitleSelection }) { item.select(choice.option, in: group) }
        }
    }

    private func applyAudioSelection() {
        guard let item, let group = audioGroup else { return }
        if audioSelection == "automatic" {
            if let language = preferences?.audioLanguage, !language.isEmpty,
               let choice = preferred(audioTracks, language: language) { item.select(choice.option, in: group) }
            else { item.selectMediaOptionAutomatically(in: group) }
        } else if let choice = audioTracks.first(where: { $0.id == audioSelection }) { item.select(choice.option, in: group) }
    }

    func useExternalSubtitles(named name: String) {
        externalSubtitleName = name
        subtitleSelection = "external"
    }

    func tick(time: Double, duration: Double) {
        if let resume = pendingResume, duration > 0 {
            pendingResume = nil
            if resume >= 5, resume < duration - 5 { onSeek?(resume) }
        }
        if abs(time - lastSavedTime) >= 10 { savePosition(); lastSavedTime = time }
    }

    func savePosition() {
        guard let sourceURL, let player else { return }
        preferences?.savePosition(player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? 0, for: sourceURL)
    }

    func detach() {
        savePosition()
        identifier = UUID()
        discoveryTask?.cancel()
        discoveryTask = nil
        if let output = legibleOutput {
            output.setDelegate(nil, queue: nil)
            item?.remove(output)
        }
        legibleOutput = nil
        item = nil
        sourceURL = nil
        pendingResume = nil
        lastSavedTime = 0
        subtitleGroup = nil
        audioGroup = nil
        subtitleTracks = []
        audioTracks = []
        chapters = []
        streams = []
        embeddedText = ""
        externalSubtitleName = ""
        informationError = ""
        isDiscovering = false
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        MainActor.assumeIsolated {
            guard output === legibleOutput, subtitleSelection != "off", subtitleSelection != "external" else { return }
            embeddedText = strings.map(\.string).joined(separator: "\n")
        }
    }

    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated { if output === legibleOutput { embeddedText = "" } }
    }

    nonisolated private static func fourCC(_ value: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii) ?? "Unknown"
    }
    nonisolated private static func kind(_ type: AVMediaType) -> String {
        switch type { case .video: return "Video"; case .audio: return "Audio"; case .subtitle, .text, .closedCaption: return "Subtitle"; default: return "Other" }
    }
}
