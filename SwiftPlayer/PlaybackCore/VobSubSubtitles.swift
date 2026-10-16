import Foundation
import CoreGraphics

nonisolated struct VobSubTrack: Identifiable, Sendable {
    let id: Int
    let language: String
    var entries: [(time: Double, offset: UInt64)] = []
    var title: String { Locale.current.localizedString(forLanguageCode: language) ?? language }
}

nonisolated struct VobSubIndex: Sendable {
    var canvas = CGSize(width: 720, height: 480)
    var palette: [UInt32] = []
    var tracks: [VobSubTrack] = []
    var defaultTrack = 0

    static func load(_ url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw SubtitleDecodingError.limit }
        var result = Self(), track: Int?, delay = 0.0, entryCount = 0
        for raw in text.components(separatedBy: .newlines) {
            try Task.checkCancellation()
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if line.hasPrefix("size:") {
                let fields = line.dropFirst(5).split(separator: "x", omittingEmptySubsequences: false)
                let parts = fields.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard fields.count == 2, parts.count == 2, parts.allSatisfy({ $0 > 0 && $0 <= 4096 }) else { throw SubtitleDecodingError.invalid }
                result.canvas = CGSize(width: parts[0], height: parts[1])
            } else if line.hasPrefix("palette:") {
                let fields = line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false)
                result.palette = fields.compactMap { UInt32($0.trimmingCharacters(in: .whitespaces), radix: 16) }
                guard fields.count == 16, result.palette.count == 16, result.palette.allSatisfy({ $0 <= 0xffffff }) else { throw SubtitleDecodingError.invalid }
            } else if line.hasPrefix("langidx:") {
                result.defaultTrack = Int(line.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("id:") {
                let parts = line.dropFirst(3).components(separatedBy: ", index:")
                guard parts.count == 2, let id = Int(parts[1].trimmingCharacters(in: .whitespaces)), (0..<32).contains(id),
                      !result.tracks.contains(where: { $0.id == id }), result.tracks.count < 32 else { throw SubtitleDecodingError.invalid }
                result.tracks.append(VobSubTrack(id: id, language: String(parts[0].trimmingCharacters(in: .whitespaces).prefix(64))))
                track = result.tracks.count - 1; delay = 0
            } else if line.hasPrefix("delay:") {
                var value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                let negative = value.hasPrefix("-")
                if value.hasPrefix("+") || negative { value.removeFirst() }
                delay = try timestamp(value) * (negative ? -1 : 1)
            } else if line.hasPrefix("timestamp:") {
                let parts = line.dropFirst(10).components(separatedBy: ", filepos:")
                guard parts.count == 2, let track, let offset = UInt64(parts[1].trimmingCharacters(in: .whitespaces), radix: 16) else { throw SubtitleDecodingError.invalid }
                let time = max(0, try timestamp(parts[0].trimmingCharacters(in: .whitespaces)) + delay)
                guard result.tracks[track].entries.last.map({ time >= $0.time && offset > $0.offset }) ?? true else { throw SubtitleDecodingError.invalid }
                result.tracks[track].entries.append((time, offset)); entryCount += 1
                guard entryCount <= 30_000 else { throw SubtitleDecodingError.limit }
            } else if line.hasPrefix("custom colors:"), line.contains("on") {
                throw SubtitleDecodingError.invalid // Unsupported overrides must not silently produce incorrect colors.
            }
        }
        guard result.palette.count == 16, !result.tracks.isEmpty else { throw SubtitleDecodingError.invalid }
        return result
    }

    private static func timestamp(_ text: String) throws -> Double {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        let values = fields.compactMap { Int($0) }
        guard fields.count == 4, values.count == 4, (0...999).contains(values[0]), (0..<60).contains(values[1]),
              (0..<60).contains(values[2]), (0..<1000).contains(values[3]) else { throw SubtitleDecodingError.invalid }
        return Double(values[0] * 3600 + values[1] * 60 + values[2]) + Double(values[3]) / 1000
    }
}

nonisolated enum VobSubParser {
    static func load(index url: URL, companion: URL?, track requested: Int?, preferred: [String]) throws -> (cues: [SubtitleCue], track: Int) {
        let idxURL = url.pathExtension.lowercased() == "idx" ? url : companion ?? url.deletingPathExtension().appendingPathExtension("idx")
        let subURL = url.pathExtension.lowercased() == "sub" ? url : companion ?? url.deletingPathExtension().appendingPathExtension("sub")
        guard idxURL.pathExtension.lowercased() == "idx", subURL.pathExtension.lowercased() == "sub",
              idxURL.isFileURL, subURL.isFileURL else { throw SubtitleDecodingError.invalid }
        let index = try VobSubIndex.load(idxURL)
        let language = preferredLanguageIndex(in: index.tracks.map(\.language), preferred: preferred)
        let track = index.tracks.first(where: { $0.id == requested }) ?? language.map { index.tracks[$0] }
            ?? index.tracks.first(where: { $0.id == index.defaultTrack }) ?? index.tracks[0]
        let file = try FileHandle(forReadingFrom: subURL)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length <= 512 * 1024 * 1024 else { throw SubtitleDecodingError.limit }
        var cues: [SubtitleCue] = [], retainedBytes = 0, readBytes = 0
        for (entryIndex, entry) in track.entries.enumerated() {
            try Task.checkCancellation()
            guard entry.offset < length else { throw SubtitleDecodingError.invalid }
            try file.seek(toOffset: entry.offset)
            let nextOffset = entryIndex + 1 < track.entries.count ? track.entries[entryIndex + 1].offset : length
            guard nextOffset > entry.offset, nextOffset <= length else { throw SubtitleDecodingError.invalid }
            let decoded = try autoreleasepool {
                // Discard PES read/padding buffers between entries while keeping
                // the decoded cue's independently owned compressed subpicture.
                let data = try file.read(upToCount: Int(min(128 * 1024, nextOffset - entry.offset))) ?? Data()
                readBytes += data.count
                guard readBytes <= 1024 * 1024 * 1024 else { throw SubtitleDecodingError.limit }
                let packet = try subpicture(data, stream: 0x20 + track.id)
                return try decode(packet, at: entry.time, canvas: index.canvas, palette: index.palette)
            }
            if let previous = cues.last, previous.end > entry.time { cues[cues.count - 1].end = entry.time }
            for cue in decoded { retainedBytes += cue.bitmap?.parts.reduce(0, { $0 + $1.bytes.count + $1.palette.count }) ?? 0 }
            cues += decoded
            guard cues.count <= 30_000, retainedBytes <= 64 * 1024 * 1024 else { throw SubtitleDecodingError.limit }
        }
        return (cues, track.id)
    }

    static func subpicture(_ data: Data, stream: Int) throws -> Data {
        var position = 0, result = Data()
        let bytes = [UInt8](data)
        while position + 6 <= bytes.count {
            try Task.checkCancellation()
            guard bytes[position] == 0, bytes[position + 1] == 0, bytes[position + 2] == 1 else { position += 1; continue }
            let code = bytes[position + 3]
            if code == 0xba {
                guard position + 14 <= bytes.count else { throw SubtitleDecodingError.invalid }
                if bytes[position + 4] & 0xc0 == 0x40 { position += 14 + Int(bytes[position + 13] & 7) }
                else if bytes[position + 4] & 0xf0 == 0x20 { position += 12 }
                else { throw SubtitleDecodingError.invalid }
                continue
            }
            let end = position + 6 + Int(bytes[position + 4]) * 256 + Int(bytes[position + 5])
            guard end <= bytes.count, end > position + 6 else { throw SubtitleDecodingError.invalid }
            if code == 0xbd {
                var payload = position + 6
                if bytes[payload] & 0xc0 == 0x80 {
                    guard payload + 3 <= end else { throw SubtitleDecodingError.invalid }
                    payload += 3 + Int(bytes[payload + 2])
                } else {
                    while payload < end, bytes[payload] == 0xff { payload += 1 }
                    guard payload < end else { throw SubtitleDecodingError.invalid }
                    if bytes[payload] & 0xc0 == 0x40 { payload += 2 }
                    guard payload < end else { throw SubtitleDecodingError.invalid }
                    switch bytes[payload] >> 4 {
                    case 2: payload += 5
                    case 3: payload += 10
                    default:
                        guard bytes[payload] == 0x0f else { throw SubtitleDecodingError.invalid }
                        payload += 1
                    }
                }
                guard payload < end else { throw SubtitleDecodingError.invalid }
                if Int(bytes[payload]) == stream {
                    result.append(contentsOf: bytes[(payload + 1)..<end])
                    if result.count >= 2 {
                        let expected = Int(result[0]) * 256 + Int(result[1])
                        guard expected >= 10, expected <= 65_535 else { throw SubtitleDecodingError.invalid }
                        if result.count >= expected { return Data(result.prefix(expected)) }
                    }
                }
            }
            position = end
        }
        throw SubtitleDecodingError.invalid
    }

    static func decode(_ data: Data, at timestamp: Double, canvas: CGSize, palette: [UInt32]) throws -> [SubtitleCue] {
        var header = SubtitleBytes(data)
        guard try header.uint(2) == data.count, palette.count == 16 else { throw SubtitleDecodingError.invalid }
        let controlStart = try header.uint(2)
        guard controlStart >= 4, controlStart <= data.count - 4 else { throw SubtitleDecodingError.invalid }
        let pixels = data.subdata(in: 0..<controlStart)
        var control = controlStart, visited = Set<Int>(), visible = false
        var colors = [0, 0, 0, 0], alpha = [0, 0, 0, 0], bounds = CGRect.zero
        var offsets: (Int, Int)?, cues: [SubtitleCue] = [], lastDate = 0
        while true {
            try Task.checkCancellation()
            guard !visited.contains(control), visited.count < 128, control >= controlStart, control <= data.count - 4 else { throw SubtitleDecodingError.invalid }
            visited.insert(control)
            var r = SubtitleBytes(data); r.offset = control
            let date = try r.uint(2), next = try r.uint(2)
            guard date >= lastDate else { throw SubtitleDecodingError.invalid }
            lastDate = date
            let time = timestamp + Double(date) * 1024 / 90_000
            var ended = false, changed = false
            for _ in 0..<128 {
                let command = try r.byte()
                switch command {
                case 0, 1: visible = true; changed = true
                case 2: visible = false; changed = true
                case 3, 4:
                    let value = try r.uint(2)
                    let nibbles = (0..<4).map { (value >> ($0 * 4)) & 15 }
                    if command == 3 { colors = nibbles } else { alpha = nibbles }
                    changed = true
                case 5:
                    let x = try r.uint(3), y = try r.uint(3)
                    let x1 = x >> 12, x2 = x & 0xfff, y1 = y >> 12, y2 = y & 0xfff
                    guard x2 >= x1, y2 >= y1 else { throw SubtitleDecodingError.invalid }
                    bounds = CGRect(x: x1, y: y1, width: x2 - x1 + 1, height: y2 - y1 + 1); changed = true
                case 6: offsets = (try r.uint(2), try r.uint(2)); changed = true
                case 0xff: ended = true
                default: throw SubtitleDecodingError.invalid
                }
                if ended { break }
            }
            guard ended else { throw SubtitleDecodingError.invalid }
            if changed {
                if cues.last?.end == .infinity { cues[cues.count - 1].end = time }
                if visible {
                    guard let offsets, offsets.0 >= 4, offsets.1 >= 4, offsets.0 < controlStart, offsets.1 < controlStart,
                          bounds.width > 0, bounds.height > 0, bounds.width * bounds.height <= 8 * 1024 * 1024 else { throw SubtitleDecodingError.invalid }
                    var rgba: [UInt8] = []
                    for i in 0..<4 {
                        let color = palette[colors[i]]
                        rgba += [UInt8((color >> 16) & 255), UInt8((color >> 8) & 255), UInt8(color & 255), UInt8(alpha[i] * 17)]
                    }
                    let part = BitmapSubtitle.Part(bounds: bounds, width: Int(bounds.width), height: Int(bounds.height), bytes: pixels,
                        palette: rgba, dvdOffsets: offsets)
                    cues.append(SubtitleCue(start: time, end: .infinity, text: "", bitmap: BitmapSubtitle(canvas: canvas, parts: [part])))
                }
            }
            if next == control { break }
            control = next
        }
        return cues.filter { $0.end > $0.start }
    }
}
