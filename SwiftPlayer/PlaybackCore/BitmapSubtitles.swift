import Foundation
import CoreGraphics

nonisolated struct SubtitleImagePart: Sendable {
    let image: CGImage
    let bounds: CGRect
}

nonisolated struct SubtitleImageFrame: Sendable {
    let id = UUID()
    let canvas: CGSize
    let parts: [SubtitleImagePart]

    func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        for part in parts {
            let r = part.bounds
            context.draw(part.image, in: CGRect(x: rect.minX + r.minX / canvas.width * rect.width,
                y: rect.minY + (canvas.height - r.maxY) / canvas.height * rect.height,
                width: r.width / canvas.width * rect.width, height: r.height / canvas.height * rect.height))
        }
        context.restoreGState()
    }
}

nonisolated struct BitmapSubtitle: Sendable {
    struct Part: Sendable {
        let bounds: CGRect
        let width: Int
        let height: Int
        let bytes: Data
        let palette: [UInt8] // straight RGBA
        var crop: CGRect?
        var dvdOffsets: (Int, Int)?
        var window: CGRect?
    }
    let canvas: CGSize
    let parts: [Part]

    func render() throws -> SubtitleImageFrame {
        var images: [SubtitleImagePart] = []
        var pixels = 0
        for part in parts {
            try Task.checkCancellation()
            guard part.width > 0, part.height > 0, part.width <= 8192, part.height <= 8192,
                  part.width * part.height <= 8 * 1024 * 1024 - pixels else { throw SubtitleDecodingError.invalid }
            pixels += part.width * part.height
            let indices = try part.dvdOffsets.map { try DVDSubtitleDecoder.pixels(part.bytes, width: part.width, height: part.height, offsets: $0) }
                ?? Self.pgsPixels(part.bytes, width: part.width, height: part.height)
            var rgba = Data(count: indices.count * 4)
            rgba.withUnsafeMutableBytes { (dest: UnsafeMutableRawBufferPointer) in
                for (i, index) in indices.enumerated() {
                    let c = Int(index) * 4
                    guard c + 3 < part.palette.count else { continue }
                    let alpha = UInt16(part.palette[c + 3])
                    for channel in 0..<3 { dest[i * 4 + channel] = UInt8(UInt16(part.palette[c + channel]) * alpha / 255) }
                    dest[i * 4 + 3] = UInt8(alpha)
                }
            }
            guard let provider = CGDataProvider(data: rgba as CFData), let color = CGColorSpace(name: CGColorSpace.sRGB),
                  var image = CGImage(width: part.width, height: part.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: part.width * 4, space: color, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw SubtitleDecodingError.invalid }
            var bounds = part.bounds
            if let crop = part.crop {
                guard crop.width > 0, crop.height > 0, CGRect(x: 0, y: 0, width: part.width, height: part.height).contains(crop),
                      let cropped = image.cropping(to: crop) else { throw SubtitleDecodingError.invalid }
                image = cropped
                bounds.size = crop.size
            }
            let clipped = bounds.intersection(part.window ?? CGRect(origin: .zero, size: canvas)).intersection(CGRect(origin: .zero, size: canvas))
            if clipped.isNull || clipped.isEmpty { continue }
            if clipped != bounds {
                guard let cropped = image.cropping(to: CGRect(x: clipped.minX - bounds.minX, y: clipped.minY - bounds.minY, width: clipped.width, height: clipped.height)) else { throw SubtitleDecodingError.invalid }
                image = cropped; bounds = clipped
            }
            images.append(SubtitleImagePart(image: image, bounds: bounds))
        }
        return SubtitleImageFrame(canvas: canvas, parts: images)
    }

    static func pgsPixels(_ data: Data, width: Int, height: Int) throws -> [UInt8] {
        var reader = SubtitleBytes(data)
        var result = [UInt8](repeating: 0, count: width * height)
        var x = 0, y = 0
        while y < height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let value = try reader.byte()
            var count = 1, color = value
            if value == 0 {
                let flags = try reader.byte()
                if flags == 0 {
                    guard x == width else { throw SubtitleDecodingError.invalid }
                    x = 0; y += 1
                    continue
                }
                count = Int(flags & 0x3f)
                if flags & 0x40 != 0 { count = count * 256 + Int(try reader.byte()) }
                color = flags & 0x80 != 0 ? try reader.byte() : 0
            }
            guard count > 0, count <= width - x else { throw SubtitleDecodingError.invalid }
            for i in 0..<count { result[y * width + x + i] = color }
            x += count
            // Some encoders omit the final end-of-line marker.
            if y == height - 1, x == width, reader.remaining == 0 { break }
        }
        return result
    }
}

nonisolated enum SubtitleDecodingError: Error { case invalid, limit }

nonisolated struct SubtitleBytes {
    let data: Data
    var offset = 0
    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - offset }
    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw SubtitleDecodingError.invalid }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func uint(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count { value = value * 256 + Int(try byte()) }
        return value
    }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SubtitleDecodingError.invalid }
        defer { offset += count }
        return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
    }
}

nonisolated enum PGSSubtitleParser {
    private struct Object {
        var width: Int
        var height: Int
        var expected: Int
        var bytes: Data
    }
    private struct Placement {
        let id: Int
        let x: Int
        let y: Int
        let crop: CGRect?
        let windowID: Int
    }
    static func load(_ url: URL) throws -> [SubtitleCue] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var objects: [Int: Object] = [:], palettes: [Int: [UInt8]] = [:]
        var placements: [Placement] = []
        var windows: [Int: CGRect] = [:]
        var canvas = CGSize.zero, time = 0.0, paletteID = 0
        var cues: [SubtitleCue] = []
        var inputBytes = 0, retainedBytes = 0, packets = 0
        var previousPTS: UInt64 = 0, wraps: UInt64 = 0
        var pending = false
        while true {
            try Task.checkCancellation()
            let header = try file.read(upToCount: 13) ?? Data()
            if header.isEmpty { break }
            guard header.count == 13 else { throw SubtitleDecodingError.invalid }
            var h = SubtitleBytes(header)
            guard try h.uint(2) == 0x5047 else { throw SubtitleDecodingError.invalid }
            let pts = UInt64(try h.uint(4))
            _ = try h.uint(4)
            let type = try h.byte(), length = try h.uint(2)
            inputBytes += 13 + length; packets += 1
            guard inputBytes <= 128 * 1024 * 1024, packets <= 200_000 else { throw SubtitleDecodingError.limit }
            let payload = try file.read(upToCount: length) ?? Data()
            guard payload.count == length else { throw SubtitleDecodingError.invalid }
            var r = SubtitleBytes(payload)
            switch type {
            case 0x16:
                guard !pending else { throw SubtitleDecodingError.invalid }
                let w = try r.uint(2), height = try r.uint(2)
                guard w > 0, height > 0, w <= 8192, height <= 8192 else { throw SubtitleDecodingError.invalid }
                canvas = CGSize(width: w, height: height)
                _ = try r.byte(); _ = try r.uint(2)
                let state = try r.byte()
                if state & 0xc0 != 0 { objects.removeAll(); palettes.removeAll(); windows.removeAll() }
                _ = try r.byte(); paletteID = Int(try r.byte())
                let count = try r.byte()
                guard count <= 2 else { throw SubtitleDecodingError.invalid }
                placements = []
                for _ in 0..<count {
                    let id = try r.uint(2)
                    let windowID = Int(try r.byte())
                    let flags = try r.byte(), x = try r.uint(2), y = try r.uint(2)
                    var crop: CGRect?
                    if flags & 0x80 != 0 { crop = CGRect(x: try r.uint(2), y: try r.uint(2), width: try r.uint(2), height: try r.uint(2)) }
                    placements.append(Placement(id: id, x: x, y: y, crop: crop, windowID: windowID))
                }
                if pts < previousPTS, previousPTS - pts > 0x80000000 { wraps += 1 }
                previousPTS = pts
                let nextTime = Double(pts + wraps * 0x100000000) / 90_000
                guard nextTime >= time else { throw SubtitleDecodingError.invalid }
                time = nextTime
                pending = true
            case 0x14:
                let id = Int(try r.byte()); _ = try r.byte()
                var colors = palettes[id] ?? [UInt8](repeating: 0, count: 1024)
                while r.remaining > 0 {
                    let i = Int(try r.byte()) * 4
                    let y = Double(try r.byte()) - 16, cr = Double(try r.byte()) - 128, cb = Double(try r.byte()) - 128
                    colors[i] = UInt8(min(max((1.164 * y + 1.793 * cr).rounded(), 0), 255))
                    colors[i + 1] = UInt8(min(max((1.164 * y - 0.213 * cb - 0.533 * cr).rounded(), 0), 255))
                    colors[i + 2] = UInt8(min(max((1.164 * y + 2.112 * cb).rounded(), 0), 255))
                    colors[i + 3] = try r.byte()
                }
                palettes[id] = colors
                guard palettes.count <= 8 else { throw SubtitleDecodingError.limit }
            case 0x15:
                let id = try r.uint(2); _ = try r.byte()
                let flags = try r.byte()
                if flags & 0x80 != 0 {
                    let expected = try r.uint(3) - 4, w = try r.uint(2), height = try r.uint(2)
                    guard expected > 0, expected <= 8 * 1024 * 1024, w > 0, height > 0,
                          w <= 8192, height <= 8192, w * height <= 8 * 1024 * 1024 else { throw SubtitleDecodingError.limit }
                    objects[id] = Object(width: w, height: height, expected: expected, bytes: Data())
                }
                guard var object = objects[id], r.remaining <= object.expected - object.bytes.count else { throw SubtitleDecodingError.invalid }
                object.bytes.append(try r.take(r.remaining))
                if flags & 0x40 != 0, object.bytes.count != object.expected { throw SubtitleDecodingError.invalid }
                objects[id] = object
                guard objects.count <= 64, objects.values.reduce(0, { $0 + $1.bytes.count }) <= 16 * 1024 * 1024 else { throw SubtitleDecodingError.limit }
            case 0x80:
                guard pending else { throw SubtitleDecodingError.invalid }
                pending = false
                if cues.last?.end == .infinity { cues[cues.count - 1].end = time }
                if placements.isEmpty { continue }
                guard let palette = palettes[paletteID] else { throw SubtitleDecodingError.invalid }
                var parts: [BitmapSubtitle.Part] = []
                for p in placements {
                    guard let o = objects[p.id], o.bytes.count == o.expected,
                          p.x < Int(canvas.width), p.y < Int(canvas.height) else { throw SubtitleDecodingError.invalid }
                    retainedBytes += o.bytes.count + palette.count
                    parts.append(.init(bounds: CGRect(x: p.x, y: p.y, width: o.width, height: o.height),
                        width: o.width, height: o.height, bytes: o.bytes, palette: palette, crop: p.crop, window: windows[p.windowID]))
                }
                guard retainedBytes <= 64 * 1024 * 1024, cues.count < 30_000 else { throw SubtitleDecodingError.limit }
                cues.append(SubtitleCue(start: time, end: .infinity, text: "", bitmap: BitmapSubtitle(canvas: canvas, parts: parts)))
            case 0x17:
                let count = try r.byte()
                guard count <= 2 else { throw SubtitleDecodingError.invalid }
                for _ in 0..<count {
                    let id = Int(try r.byte())
                    windows[id] = CGRect(x: try r.uint(2), y: try r.uint(2), width: try r.uint(2), height: try r.uint(2))
                }
                guard windows.count <= 2 else { throw SubtitleDecodingError.limit }
            default: throw SubtitleDecodingError.invalid
            }
        }
        guard !pending else { throw SubtitleDecodingError.invalid }
        return cues
    }
}
