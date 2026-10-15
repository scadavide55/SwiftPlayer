import Foundation
import Combine

struct SubtitleAppearance: Codable, Equatable {
    var fontFamily = "System"
    var size: Double = 24
    var color = "White"
    var outline = true
    var backgroundOpacity: Double = 0.6
    var position = "Bottom"

    var normalized: Self {
        var value = self
        value.size = size.isFinite ? min(max(size, 12), 64) : 24
        value.backgroundOpacity = backgroundOpacity.isFinite ? min(max(backgroundOpacity, 0), 1) : 0.6
        if !["White", "Yellow", "Green", "Cyan"].contains(color) { value.color = "White" }
        if !["Bottom", "Center", "Top"].contains(position) { value.position = "Bottom" }
        return value
    }
}

@MainActor
final class PlayerPreferences: ObservableObject {
    static let shared = PlayerPreferences(defaults: .standard)
    private let defaults: UserDefaults
    @Published var subtitleLanguage: String { didSet { defaults.set(subtitleLanguage, forKey: "subtitleLanguage") } }
    @Published var audioLanguage: String { didSet { defaults.set(audioLanguage, forKey: "audioLanguage") } }
    @Published var subtitlesByDefault: Bool { didSet { defaults.set(subtitlesByDefault, forKey: "subtitlesByDefault") } }
    @Published var maximumVolume: Float {
        didSet {
            let normalized = maximumVolume.isFinite ? min(max(maximumVolume, 1), 4) : oldValue
            if maximumVolume != normalized { maximumVolume = normalized; return }
            defaults.set(maximumVolume, forKey: "maximumVolume")
        }
    }
    @Published var limitAudioPeaks: Bool { didSet { defaults.set(limitAudioPeaks, forKey: "limitAudioPeaks") } }
    @Published var normalizeAudio: Bool { didSet { defaults.set(normalizeAudio, forKey: "normalizeAudio") } }
    @Published var rememberVolume: Bool { didSet { defaults.set(rememberVolume, forKey: "rememberVolume") } }
    @Published var resumePlayback: Bool {
        didSet {
            defaults.set(resumePlayback, forKey: "resumePlayback")
            if !resumePlayback { defaults.removeObject(forKey: "resumePositions") }
        }
    }
    @Published var appearance: SubtitleAppearance {
        didSet {
            if appearance != appearance.normalized { appearance = appearance.normalized; return }
            defaults.set(try? JSONEncoder().encode(appearance), forKey: "subtitleAppearance")
        }
    }
    var savedVolume: Float {
        get { let value = defaults.object(forKey: "savedVolume") as? Float ?? 1; return value.isFinite ? min(max(value, 0), maximumVolume) : 1 }
        set { guard newValue.isFinite else { return }; defaults.set(min(max(newValue, 0), maximumVolume), forKey: "savedVolume") }
    }
    var savedMute: Bool {
        get { defaults.bool(forKey: "savedMute") }
        set { defaults.set(newValue, forKey: "savedMute") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        subtitleLanguage = defaults.string(forKey: "subtitleLanguage") ?? ""
        audioLanguage = defaults.string(forKey: "audioLanguage") ?? ""
        subtitlesByDefault = defaults.object(forKey: "subtitlesByDefault") as? Bool ?? true
        let savedMaximum = defaults.object(forKey: "maximumVolume") as? Float ?? 2
        maximumVolume = savedMaximum.isFinite ? min(max(savedMaximum, 1), 4) : 2
        limitAudioPeaks = defaults.object(forKey: "limitAudioPeaks") as? Bool ?? true
        normalizeAudio = defaults.object(forKey: "normalizeAudio") as? Bool ?? false
        rememberVolume = defaults.object(forKey: "rememberVolume") as? Bool ?? true
        resumePlayback = defaults.object(forKey: "resumePlayback") as? Bool ?? false
        appearance = (defaults.data(forKey: "subtitleAppearance").flatMap { try? JSONDecoder().decode(SubtitleAppearance.self, from: $0) } ?? SubtitleAppearance()).normalized
    }

    func resumeTime(for url: URL) -> Double? {
        guard resumePlayback else { return nil }
        return (defaults.dictionary(forKey: "resumePositions") as? [String: Double])?[url.standardizedFileURL.absoluteString]
    }

    func savePosition(_ seconds: Double, duration: Double, for url: URL) {
        guard resumePlayback, seconds.isFinite, duration.isFinite, duration > 0 else { return }
        var positions = defaults.dictionary(forKey: "resumePositions") as? [String: Double] ?? [:]
        let key = url.standardizedFileURL.absoluteString
        if seconds < 5 || seconds >= duration - 5 { positions.removeValue(forKey: key) }
        else { positions[key] = min(seconds, duration) }
        if positions.count > 100, let other = positions.keys.first(where: { $0 != key }) { positions.removeValue(forKey: other) }
        defaults.set(positions, forKey: "resumePositions")
    }
}
