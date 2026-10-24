import Foundation
import Combine

/// One previously opened file plus where playback stopped.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var name: String
    /// Security-scoped bookmark so the sandboxed app can reopen the file on a later launch.
    var bookmark: Data?
    var lastPlayed: Date
    var position: Double
    var duration: Double

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// Persists the recently played list in `UserDefaults`.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxEntries = 20

    /// Positions closer than this to the start are not worth resuming.
    static let minResumePosition: Double = 5
    /// Positions closer than this to the end count as finished.
    static let finishedMargin: Double = 10

    @Published private(set) var entries: [HistoryEntry] = []

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "videoHistory.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    /// Adds `url` to the top of the list, or moves the existing entry there keeping its saved position.
    @discardableResult
    func record(url: URL) -> HistoryEntry {
        let path = url.standardizedFileURL.path
        let bookmark = makeBookmark(for: url)

        var entry: HistoryEntry
        if let index = entries.firstIndex(where: { $0.path == path }) {
            entry = entries.remove(at: index)
            entry.lastPlayed = Date()
            if let bookmark { entry.bookmark = bookmark }
        } else {
            entry = HistoryEntry(
                id: UUID(),
                path: path,
                name: url.lastPathComponent,
                bookmark: bookmark,
                lastPlayed: Date(),
                position: 0,
                duration: 0
            )
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
        return entry
    }

    func updatePosition(id: UUID, position: Double, duration: Double) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].position != position || entries[index].duration != duration else { return }
        entries[index].position = position
        entries[index].duration = duration
        save()
    }

    /// Position to resume from, or nil when the file should start from the beginning.
    func resumePosition(for entry: HistoryEntry) -> Double? {
        guard entry.position >= Self.minResumePosition else { return nil }
        if entry.duration > 0, entry.position >= entry.duration - Self.finishedMargin { return nil }
        return entry.position
    }

    /// Resolves the stored bookmark. The caller must call `startAccessingSecurityScopedResource()`
    /// on the result before reading it. Returns nil when the file no longer exists.
    func resolve(_ entry: HistoryEntry) -> URL? {
        if let bookmark = entry.bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if stale, let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    entries[index].bookmark = makeBookmark(for: url) ?? bookmark
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    save()
                }
                return url
            }
        }
        let fallback = URL(fileURLWithPath: entry.path)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
