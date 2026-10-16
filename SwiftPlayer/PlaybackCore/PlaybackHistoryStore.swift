import Foundation
import Combine

struct PlaybackHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var key: String
    var name: String
    var reference: SubtitleFileReference
    var lastPlayed: Date
    var position: Double
    var duration: Double
    var finished: Bool

    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    var isFinished: Bool { finished || (duration > 0 && progress >= 0.98 && duration - position <= 5) }
    var continuePosition: Double { !isFinished && position >= 5 ? position : 0 }
}

@MainActor
final class PlaybackHistoryStore: ObservableObject {
    struct Session {
        fileprivate let entry: UUID
        fileprivate let generation: UUID
    }
    static let shared = PlaybackHistoryStore(defaults: .standard)
    static let maximumEntries = 200
    @Published private(set) var entries: [PlaybackHistoryEntry] = []
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "recordPlaybackHistory")
            if !enabled { clear() }
        }
    }
    @Published var retentionDays: Int {
        didSet {
            if ![30, 90, 365].contains(retentionDays) { retentionDays = oldValue; return }
            defaults.set(retentionDays, forKey: "playbackHistoryRetention")
            prune()
            persist()
        }
    }
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private var generation = UUID()
    private var lastUpdates: [UUID: Date] = [:]

    init(defaults: UserDefaults, now: @escaping @MainActor () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        enabled = defaults.object(forKey: "recordPlaybackHistory") as? Bool ?? true
        let days = defaults.integer(forKey: "playbackHistoryRetention")
        retentionDays = [30, 90, 365].contains(days) ? days : 90
        if enabled, let data = defaults.data(forKey: "playbackHistory"), data.count <= 8 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) {
            var seen = Set<String>()
            var seenIDs = Set<UUID>()
            entries = decoded.filter {
                $0.key.utf16.count <= 8192 && $0.key.hasPrefix("file:") && $0.name.utf16.count <= 512 &&
                $0.reference.bookmark.count <= 16 * 1024 && $0.position.isFinite && $0.position >= 0 &&
                $0.duration.isFinite && $0.duration >= 0 && ($0.duration == 0 || $0.position <= $0.duration) &&
                seen.insert($0.key).inserted && seenIDs.insert($0.id).inserted
            }.map { value in
                var value = value
                value.lastPlayed = min(value.lastPlayed, now())
                return value
            }
            prune()
            persist()
        } else { defaults.removeObject(forKey: "playbackHistory") }
    }

    func begin(_ url: URL, duration: Double) -> Session? {
        guard enabled, url.isFileURL, url.absoluteString.utf16.count <= 8192,
              let reference = SubtitleFileReference.capture(url) else { return nil }
        prune()
        let key = url.standardizedFileURL.absoluteString
        let previous = entries.first { $0.key == key }
        let entry = PlaybackHistoryEntry(id: previous?.id ?? UUID(), key: key,
            name: String(url.lastPathComponent.prefix(512)), reference: reference, lastPlayed: now(),
            position: 0, duration: duration.isFinite ? max(0, duration) : 0, finished: false)
        entries.removeAll { $0.key == key }
        entries.insert(entry, at: 0)
        prune()
        lastUpdates[entry.id] = now()
        persist()
        return Session(entry: entry.id, generation: generation)
    }

    func update(_ session: Session, position: Double, duration: Double, finished: Bool = false, force: Bool = false) {
        guard enabled, session.generation == generation, position.isFinite, position >= 0,
              duration.isFinite, duration > 0, let index = entries.firstIndex(where: { $0.id == session.entry }) else { return }
        let date = now()
        guard force || date.timeIntervalSince(lastUpdates[session.entry] ?? .distantPast) >= 10 else { return }
        var entry = entries[index]
        entry.position = min(position, duration)
        entry.duration = duration
        entry.finished = finished
        entry.lastPlayed = date
        entries.remove(at: index)
        entries.insert(entry, at: 0)
        lastUpdates[entry.id] = date
        prune()
        persist()
    }

    func resolve(_ entry: PlaybackHistoryEntry) throws -> URL {
        guard let url = entry.reference.resolve() else { throw unavailable() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw unavailable() }
        return url
    }

    func remove(_ entry: PlaybackHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        lastUpdates.removeValue(forKey: entry.id)
        persist()
    }

    func clear() {
        generation = UUID()
        entries = []
        lastUpdates = [:]
        defaults.removeObject(forKey: "playbackHistory")
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        entries = Array(entries.filter { $0.lastPlayed >= cutoff }.sorted { $0.lastPlayed > $1.lastPlayed }.prefix(Self.maximumEntries))
        let ids = Set(entries.map(\.id))
        lastUpdates = lastUpdates.filter { ids.contains($0.key) }
    }

    private func persist() {
        guard enabled else { return }
        defaults.set(try? JSONEncoder().encode(entries), forKey: "playbackHistory")
    }

    private func unavailable() -> NSError {
        NSError(domain: "SwiftPlayer.History", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "This file is unavailable. Use Open File to locate it again."])
    }
}
