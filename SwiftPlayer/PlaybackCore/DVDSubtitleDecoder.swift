import Foundation

/// DVD subpictures store alternating scanlines in two nibble-coded fields.
nonisolated enum DVDSubtitleDecoder {
    static func pixels(_ data: Data, width: Int, height: Int, offsets: (Int, Int)) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 8 * 1024 * 1024 else { throw SubtitleDecodingError.limit }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for (field, offset) in [offsets.0, offsets.1].enumerated() {
            guard offset >= 4, offset < data.count else { throw SubtitleDecodingError.invalid }
            var nibble = offset * 2
            func next() throws -> Int {
                guard nibble < data.count * 2 else { throw SubtitleDecodingError.invalid }
                defer { nibble += 1 }
                let byte = data[data.startIndex + nibble / 2]
                return Int(nibble % 2 == 0 ? byte >> 4 : byte & 15)
            }
            for y in stride(from: field, to: height, by: 2) {
                try Task.checkCancellation()
                var x = 0
                while x < width {
                    var code = try next()
                    if code < 4 {
                        code = code * 16 + (try next())
                        if code < 16 {
                            code = code * 16 + (try next())
                            if code < 64 { code = code * 16 + (try next()) }
                        }
                    }
                    let run = code >> 2 == 0 ? width - x : code >> 2
                    guard run <= width - x else { throw SubtitleDecodingError.invalid }
                    for i in 0..<run { pixels[y * width + x + i] = UInt8(code & 3) }
                    x += run
                }
                if nibble % 2 != 0 { nibble += 1 }
            }
        }
        return pixels
    }
}
