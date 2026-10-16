import Foundation

struct SubtitleFileReference: Codable, Equatable, Sendable {
    let bookmark: Data
    var companionBookmark: Data?
    var subtitleTrack: Int?

    nonisolated static func capture(_ url: URL, companion: URL? = nil, subtitleTrack: Int? = nil) -> Self? {
        guard url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil),
              data.count <= 16 * 1024 else { return nil }
        let second = companion.flatMap { Self.capture($0)?.bookmark }
        if companion != nil, second == nil { return nil }
        return Self(bookmark: data, companionBookmark: second, subtitleTrack: subtitleTrack)
    }

    nonisolated func resolve() -> URL? {
        guard bookmark.count <= 16 * 1024 else { return nil }
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options,
                                 relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL else { return nil }
        return url
    }

    nonisolated func resolveCompanion() -> URL? {
        companionBookmark.flatMap { Self(bookmark: $0).resolve() }
    }
}

struct MediaFileMemory: Codable, Equatable {
    var audioOption: Data?
    var subtitleMode = "automatic"
    var subtitleOption: Data?
    var externalSubtitle: SubtitleFileReference?
    var subtitleDelay: Double = 0
    var subtitleEncoding: SubtitleEncoding?

    var normalized: Self {
        var value = self
        if !["automatic", "off", "track", "external"].contains(subtitleMode) { value.subtitleMode = "automatic" }
        value.subtitleDelay = subtitleDelay.isFinite ? min(max(subtitleDelay, -30), 30) : 0
        if audioOption?.count ?? 0 > 16 * 1024 { value.audioOption = nil }
        if subtitleOption?.count ?? 0 > 16 * 1024 { value.subtitleOption = nil }
        if externalSubtitle?.bookmark.count ?? 0 > 16 * 1024 || externalSubtitle?.companionBookmark?.count ?? 0 > 16 * 1024 {
            value.externalSubtitle = nil
        }
        return value
    }
}

struct StoredMediaFileMemory: Codable {
    var settings: MediaFileMemory
    var updated: Date
}
