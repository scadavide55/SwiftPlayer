import Foundation
import Combine

struct RecentMediaEntry: Codable, Identifiable {
    let id: String
    let name: String
    let bookmark: Data
}

@MainActor
final class RecentMediaStore: ObservableObject {
    static let shared = RecentMediaStore(defaults: .standard)
    @Published private(set) var entries: [RecentMediaEntry]
    private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey: "recentMedia").flatMap { try? JSONDecoder().decode([RecentMediaEntry].self, from: $0) } ?? []
    }
    func record(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        entries.removeAll { entry in
            var stale = false
            let saved = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return saved?.standardizedFileURL == url.standardizedFileURL
        }
        entries.insert(RecentMediaEntry(id: UUID().uuidString, name: url.lastPathComponent, bookmark: bookmark), at: 0)
        entries = Array(entries.prefix(10))
        persist()
    }
    func resolve(_ entry: RecentMediaEntry) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { record(url) }
        return url
    }
    func clear() { entries = []; defaults.removeObject(forKey: "recentMedia") }
    private func persist() { defaults.set(try? JSONEncoder().encode(entries), forKey: "recentMedia") }
}
