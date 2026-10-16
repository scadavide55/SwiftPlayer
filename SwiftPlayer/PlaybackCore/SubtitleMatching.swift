import Foundation

struct SubtitleMatch: Identifiable, Sendable {
    let url: URL
    let folder: URL
    let rank: Int
    nonisolated var id: String { url.standardizedFileURL.absoluteString }
    nonisolated var name: String { url.lastPathComponent }
}

nonisolated enum SubtitleMatching {
    private static let knownLanguages = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier))
    static func rank(candidate: URL, media: URL, preferredLanguages: [String]) -> Int? {
        guard supportedSubtitleExtensions.contains(candidate.pathExtension.lowercased()) else { return nil }
        let base = media.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        let stem = candidate.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        if stem == base { return 3 }
        guard stem.hasPrefix(base + ".") else { return nil }
        let parts = stem.dropFirst(base.count + 1).split(separator: ".").map(String.init)
        let forced = parts.contains("forced")
        let language = parts.filter { !["forced", "sdh", "cc"].contains($0) }.joined(separator: "-")
        if language.isEmpty { return forced ? 12 : 4 }
        let code = Locale.Language(identifier: language).languageCode?.identifier ?? ""
        guard knownLanguages.contains(code) else { return nil }
        let preferred = preferredLanguageIndex(in: [language], preferred: preferredLanguages) != nil
        return (preferred ? 0 : 5) + (forced ? 10 : 0)
    }

    static func find(in folder: URL, media: URL, preferredLanguages: [String]) -> [SubtitleMatch] {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        var matches: [SubtitleMatch] = []
        for case let url as URL in enumerator.prefix(2000) {
            if Task.isCancelled { return [] }
            guard let score = rank(candidate: url, media: media, preferredLanguages: preferredLanguages),
                  let resource = try? url.resourceValues(forKeys: Set(keys)),
                  resource.isRegularFile == true, resource.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "sub" { continue } // Show the index once for a paired VobSub document.
            if ext == "idx" {
                let pair = url.deletingPathExtension().appendingPathExtension("sub")
                guard let companion = try? pair.resourceValues(forKeys: Set(keys)),
                      companion.isRegularFile == true, companion.isSymbolicLink != true else { continue }
            }
            matches.append(SubtitleMatch(url: url, folder: folder, rank: score))
            if matches.count >= 128 { break }
        }
        return matches.sorted { $0.rank == $1.rank ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.rank < $1.rank }
    }
}
