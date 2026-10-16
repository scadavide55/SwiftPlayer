import Foundation

struct SubtitleCue: Sendable {
    let start: Double
    var end: Double
    let text: String
    var bitmap: BitmapSubtitle? = nil
    var styled: ASSSubtitle? = nil
}

nonisolated let supportedSubtitleExtensions: [String] = ["srt", "vtt", "ass", "ssa", "sup", "idx", "sub"]

nonisolated func parseSubtitles(from url: URL, encoding: SubtitleEncoding = .automatic, companion: URL? = nil,
                               track: Int? = nil, preferredLanguages: [String] = []) -> [SubtitleCue] {
    let scoped = url.startAccessingSecurityScopedResource()
    let companionScoped = companion?.startAccessingSecurityScopedResource() ?? false
    defer {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if companionScoped { companion?.stopAccessingSecurityScopedResource() }
    }
    if url.pathExtension.lowercased() == "sup" { return (try? PGSSubtitleParser.load(url)) ?? [] }
    if ["idx", "sub"].contains(url.pathExtension.lowercased()) {
        return (try? VobSubParser.load(index: url, companion: companion, track: track, preferred: preferredLanguages).cues) ?? []
    }
    guard !Task.isCancelled, let input = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? input.close() }
    let maximumBytes = 16 * 1024 * 1024
    guard let data = try? input.read(upToCount: maximumBytes + 1),
          data.count <= maximumBytes, !Task.isCancelled else { return [] }
    guard let raw = encoding.decode(data) else { return [] }
    let content = raw.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "srt":
        return parseSRT(content)
    case "vtt":
        return parseVTT(content)
    case "ass", "ssa":
        return ASSSubtitleParser.parse(content)
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
        if Task.isCancelled { return [] }
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
    let h: Int
    if match.range(at: groups.lowerBound).location == NSNotFound {
        h = 0 // WebVTT permits timestamps without an hours field.
    } else {
        guard let hours = value(groups.lowerBound) else { return nil }
        h = hours
    }
    guard let m = value(groups.lowerBound + 1),
          let s = value(groups.lowerBound + 2),
          let ms = value(groups.lowerBound + 3) else { return nil }
    return timeToSeconds(h, m, s, ms)
}

nonisolated private func parseVTT(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    let blocks = content.components(separatedBy: "\n\n")
    let timePattern = #"(?:(\d{2,}):)?(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*(?:(\d{2,}):)?(\d{2}):(\d{2})[.,](\d{3})"#
    guard let regex = try? NSRegularExpression(pattern: timePattern) else { return [] }

    for block in blocks {
        if Task.isCancelled { return [] }
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

nonisolated private func stripTags(_ text: String) -> String {
    let plain = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    guard plain.contains("&") else { return plain }
    let escapes = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                   ("&nbsp;", "\u{00a0}"), ("&lrm;", "\u{200e}"), ("&rlm;", "\u{200f}")]
    var result = ""
    result.reserveCapacity(plain.utf8.count)
    let scalars = plain.unicodeScalars
    var index = scalars.startIndex
    while index < scalars.endIndex {
        if scalars[index] == "&", let escape = escapes.first(where: { scalars[index...].starts(with: $0.0.unicodeScalars) }) {
            result.append(contentsOf: escape.1)
            index = scalars.index(index, offsetBy: escape.0.utf8.count)
        } else {
            result.unicodeScalars.append(scalars[index])
            index = scalars.index(after: index)
        }
    }
    // Decode once, after stripping markup, so escaped literal tags stay visible.
    return result
}
