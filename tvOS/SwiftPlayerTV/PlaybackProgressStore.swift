import Foundation
import Combine

/// Remembers how far into each item playback reached, so a movie can be
/// resumed after the app is closed. Entries are keyed by URL and cleaned up
/// once playback finishes or the item is barely started.
@MainActor
final class PlaybackProgressStore: ObservableObject {
    static let shared = PlaybackProgressStore()

    private let defaultsKey = "SwiftPlayerTV.playbackProgress"
    private let minimumPosition: Double = 5
    private let completionWindow: Double = 15

    private var positions: [String: Double]

    private init() {
        positions = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }

    func position(for url: URL) -> Double {
        positions[url.absoluteString] ?? 0
    }

    /// Returns the saved position only when it is meaningful to resume.
    func resumeTime(for url: URL) -> Double {
        let value = position(for: url)
        return value >= minimumPosition ? value : 0
    }

    /// Returns a 0...1 fraction if there is a meaningful resume point.
    func progress(for url: URL, duration: Double) -> Double? {
        let value = position(for: url)
        guard value >= minimumPosition, duration > 0, value < duration - completionWindow else { return nil }
        return value / duration
    }

    func save(time: Double, duration: Double, for url: URL) {
        let key = url.absoluteString
        if duration > 0, time >= duration - completionWindow || time < minimumPosition {
            positions.removeValue(forKey: key)
        } else {
            positions[key] = time
        }
        persist()
    }

    func clear(for url: URL) {
        positions.removeValue(forKey: url.absoluteString)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(positions, forKey: defaultsKey)
    }
}
