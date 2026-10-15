import Foundation

struct SubtitleCue: Sendable {
    let start: Double
    let end: Double
    let text: String
}

let supportedSubtitleExtensions: [String] = ["srt", "vtt", "ass", "ssa"]

nonisolated func parseSubtitles(from url: URL) -> [SubtitleCue] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard !Task.isCancelled, let input = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? input.close() }
    let maximumBytes = 16 * 1024 * 1024
    guard let data = try? input.read(upToCount: maximumBytes + 1),
          data.count <= maximumBytes, !Task.isCancelled else { return [] }
    let hasUTF16BOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
    guard let raw = String(data: data, encoding: hasUTF16BOM ? .utf16 : .utf8) else { return [] }
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
        return parseASS(content)
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

nonisolated private func parseASS(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    let lines = content.components(separatedBy: .newlines)
    let timePattern = #"^Dialogue:\s*(?:Marked=)?\d+,(\d+):(\d{2}):(\d{2})[.,](\d{2,3}),(\d+):(\d{2}):(\d{2})[.,](\d{2,3}),"#
    guard let regex = try? NSRegularExpression(pattern: timePattern) else { return [] }

    for line in lines where line.hasPrefix("Dialogue:") {
        if Task.isCancelled { return [] }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { continue }
        func value(_ idx: Int) -> Int? {
            guard let r = Range(match.range(at: idx), in: line) else { return nil }
            return Int(line[r])
        }
        guard let sh = value(1), let sm = value(2), let ss = value(3), let scs = value(4),
              let eh = value(5), let em = value(6), let es = value(7), let ecs = value(8) else { continue }

        let start = timeToSeconds(sh, sm, ss, scs * (match.range(at: 4).length == 2 ? 10 : 1))
        let end = timeToSeconds(eh, em, es, ecs * (match.range(at: 8).length == 2 ? 10 : 1))

        // Text is everything after the 9th comma-separated field.
        let fields = line.components(separatedBy: ",")
        guard fields.count > 9 else { continue }
        let text = fields[9...].joined(separator: ",")
        cues.append(SubtitleCue(start: start, end: end, text: stripASSTags(text)))
    }
    return cues
}

nonisolated private func stripTags(_ text: String) -> String {
    text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
}

nonisolated private func stripASSTags(_ text: String) -> String {
    let noOverrides = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    return noOverrides.replacingOccurrences(of: #"\\N|\\n"#, with: "\n", options: .regularExpression)
}
