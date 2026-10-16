import Foundation
import CoreGraphics
import CoreText

nonisolated struct ASSColor: Sendable, Equatable {
    var red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    static func parse(_ raw: String, alpha: Double = 1) -> Self? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let hex = text.replacingOccurrences(of: "&h", with: "").replacingOccurrences(of: "&", with: "")
        let value: UInt32?
        if text.hasPrefix("&h") { value = UInt32(hex, radix: 16) }
        else { value = Int64(text).map { UInt32(truncatingIfNeeded: $0) } }
        guard let value else { return nil }
        let includesAlpha = text.hasPrefix("&h") ? hex.count > 6 : true
        return Self(red: Double(value & 255) / 255, green: Double((value >> 8) & 255) / 255,
            blue: Double((value >> 16) & 255) / 255, alpha: includesAlpha ? Double(255 - (value >> 24)) / 255 : alpha)
    }
}

nonisolated struct ASSStyle: Sendable {
    var font = "Arial", size = 20.0, bold = false, italic = false, underline = false
    var primary = ASSColor(), outlineColor = ASSColor(red: 0, green: 0, blue: 0)
    var shadowColor = ASSColor(red: 0, green: 0, blue: 0, alpha: 0.6)
    var outline = 2.0, shadow = 2.0, alignment = 2, marginL = 10.0, marginR = 10.0, marginV = 10.0
    var scaleX = 1.0, scaleY = 1.0, spacing = 0.0, rotation = 0.0, opaqueBox = false
}

nonisolated struct ASSSubtitle: Sendable {
    struct Run: Sendable { let text: String; let style: ASSStyle }
    struct Motion: Sendable { let from: CGPoint; let to: CGPoint; let start: Double; let end: Double }
    let canvas: CGSize
    let start: Double
    let end: Double
    let layer: Int
    var style: ASSStyle
    var runs: [Run] = []
    var position: CGPoint?
    var motion: Motion?
    var fadeIn = 0.0, fadeOut = 0.0
    var hasUnsupportedEffects = false
    var animated: Bool { motion != nil || fadeIn > 0 || fadeOut > 0 }
}

nonisolated enum ASSSubtitleParser {
    static func parse(_ text: String) -> [SubtitleCue] {
        var canvas = CGSize(width: 384, height: 288), section = ""
        var styles: [String: ASSStyle] = [:]
        var styleFields: [String] = [], eventFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var events: [[String: String]] = [], oldSSA = false
        for raw in text.components(separatedBy: .newlines) {
            if Task.isCancelled { return [] }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { section = line.lowercased(); oldSSA = section == "[v4 styles]"; continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: .whitespaces)
            if section == "[script info]" {
                if let number = Double(value), number.isFinite, number >= 1, number <= 8192 {
                    if key == "playresx" { canvas.width = number }
                    if key == "playresy" { canvas.height = number }
                }
            } else if key == "format" {
                let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if section.contains("styles") { styleFields = fields }
                else if section == "[events]" { eventFields = fields }
            } else if key == "style", section.contains("styles"), styles.count < 256 {
                let row = fields(value, names: styleFields)
                if let name = row["name"] { styles[name.lowercased()] = style(row, oldSSA: oldSSA) }
            } else if key == "dialogue", events.count < 30_000 {
                events.append(fields(value, names: eventFields))
            }
        }
        var totalRuns = 0, totalTextBytes = 0
        let cues: [SubtitleCue] = events.compactMap { row in
            guard let start = time(row["start"]), let end = time(row["end"]), end > start else { return nil }
            let base = styles[row["style"]?.lowercased() ?? "default"] ?? ASSStyle()
            let layer = min(max(Int(row["layer"] ?? "0") ?? 0, -100_000), 100_000)
            var event = ASSSubtitle(canvas: canvas, start: start, end: end, layer: layer, style: base)
            for (key, target) in [("marginl", 0), ("marginr", 1), ("marginv", 2)] {
                if let value = Double(row[key] ?? ""), value.isFinite, value > 0, value <= 8192 {
                    if target == 0 { event.style.marginL = value }
                    if target == 1 { event.style.marginR = value }
                    if target == 2 { event.style.marginV = value }
                }
            }
            event.hasUnsupportedEffects = !(row["effect"] ?? "").isEmpty
            let dialogue = String((row["text"] ?? "").prefix(8192))
            tokenize(dialogue, event: &event, styles: styles, base: base)
            let plain = event.runs.map(\.text).joined()
            totalRuns += event.runs.count; totalTextBytes += plain.utf8.count
            guard totalRuns <= 100_000, totalTextBytes <= 16 * 1024 * 1024 else { return nil }
            guard !plain.isEmpty else { return nil }
            return SubtitleCue(start: start, end: end, text: plain, styled: event)
        }
        return totalRuns <= 100_000 && totalTextBytes <= 16 * 1024 * 1024 ? cues : []
    }

    private static func fields(_ text: String, names: [String]) -> [String: String] {
        guard names.count > 0, names.count <= 64 else { return [:] }
        let parts = text.split(separator: ",", maxSplits: names.count - 1, omittingEmptySubsequences: false)
        guard parts.count == names.count else { return [:] }
        return Dictionary(names.enumerated().map { ($0.element, String(parts[$0.offset]).trimmingCharacters(in: .whitespaces)) }, uniquingKeysWith: { _, last in last })
    }

    private static func time(_ raw: String?) -> Double? {
        guard let raw, raw.count < 24 else { return nil }
        let parts = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Int(parts[0]), h >= 0, h <= 9999,
              let m = Int(parts[1]), (0..<60).contains(m), let s = Double(parts[2]), s.isFinite, s >= 0, s < 60 else { return nil }
        return Double(h * 3600 + m * 60) + s
    }

    private static func style(_ row: [String: String], oldSSA: Bool) -> ASSStyle {
        var result = ASSStyle()
        result.font = String((row["fontname"] ?? "Arial").prefix(128))
        result.size = number(row["fontsize"], fallback: 20, range: 1...256)
        result.primary = ASSColor.parse(row["primarycolour"] ?? "") ?? result.primary
        result.outlineColor = ASSColor.parse(row["outlinecolour"] ?? row["tertiarycolour"] ?? "") ?? result.outlineColor
        result.shadowColor = ASSColor.parse(row["backcolour"] ?? "") ?? result.shadowColor
        result.bold = (Int(row["bold"] ?? "0") ?? 0) != 0
        result.italic = (Int(row["italic"] ?? "0") ?? 0) != 0
        result.underline = (Int(row["underline"] ?? "0") ?? 0) != 0
        result.outline = number(row["outline"], fallback: 2, range: 0...20)
        result.shadow = number(row["shadow"], fallback: 2, range: 0...20)
        result.marginL = number(row["marginl"], fallback: 10, range: 0...8192)
        result.marginR = number(row["marginr"], fallback: 10, range: 0...8192)
        result.marginV = number(row["marginv"], fallback: 10, range: 0...8192)
        result.scaleX = number(row["scalex"], fallback: 100, range: 10...400) / 100
        result.scaleY = number(row["scaley"], fallback: 100, range: 10...400) / 100
        result.spacing = number(row["spacing"], fallback: 0, range: -50...100)
        result.rotation = number(row["angle"], fallback: 0, range: -3600...3600)
        result.opaqueBox = row["borderstyle"] == "3"
        let alignment = Int(row["alignment"] ?? "2") ?? 2
        result.alignment = oldSSA ? legacyAlignment(alignment) : min(max(alignment, 1), 9)
        return result
    }

    private static func number(_ raw: String?, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let raw, let value = Double(raw), value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func legacyAlignment(_ value: Int) -> Int { [1: 1, 2: 2, 3: 3, 5: 7, 6: 8, 7: 9, 9: 4, 10: 5, 11: 6][value] ?? 2 }

    private static func tokenize(_ text: String, event: inout ASSSubtitle, styles: [String: ASSStyle], base: ASSStyle) {
        var current = event.style, index = text.startIndex, drawing = false
        while index < text.endIndex {
            if Task.isCancelled { return }
            if text[index] == "{", let end = text[index...].firstIndex(of: "}") {
                for raw in text[text.index(after: index)..<end].split(separator: "\\") {
                    let tag = String(raw)
                    func numeric(_ prefix: String, _ range: ClosedRange<Double>, _ fallback: Double) -> Double { number(String(tag.dropFirst(prefix.count)), fallback: fallback, range: range) }
                    func arguments(_ prefix: String) -> [Double]? {
                        guard tag.hasPrefix(prefix + "("), tag.hasSuffix(")") else { return nil }
                        let values = tag.dropFirst(prefix.count + 1).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        return values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) ? values : nil
                    }
                    if let values = arguments("pos"), values.count == 2 { event.position = CGPoint(x: values[0], y: values[1]) }
                    else if let v = arguments("move"), v.count == 4 || v.count == 6 {
                        let a = v.count == 6 ? max(0, v[4] / 1000) : 0, b = v.count == 6 ? max(a, v[5] / 1000) : event.end - event.start
                        event.motion = .init(from: CGPoint(x: v[0], y: v[1]), to: CGPoint(x: v[2], y: v[3]), start: a, end: b)
                    } else if let v = arguments("fad"), v.count == 2 { event.fadeIn = max(0, v[0] / 1000); event.fadeOut = max(0, v[1] / 1000) }
                    else if tag.hasPrefix("an") { current.alignment = Int(numeric("an", 1...9, 2)) }
                    else if tag.hasPrefix("alpha") || tag.hasPrefix("1a") || tag.hasPrefix("3a") || tag.hasPrefix("4a") {
                        let prefix = tag.hasPrefix("alpha") ? "alpha" : String(tag.prefix(2))
                        let hex = tag.dropFirst(prefix.count).replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&h", with: "").replacingOccurrences(of: "&", with: "")
                        if let value = UInt8(hex, radix: 16) {
                            let opacity = Double(255 - value) / 255
                            if prefix == "alpha" || prefix == "1a" { current.primary.alpha = opacity }
                            if prefix == "alpha" || prefix == "3a" { current.outlineColor.alpha = opacity }
                            if prefix == "alpha" || prefix == "4a" { current.shadowColor.alpha = opacity }
                        }
                    } else if tag.hasPrefix("1c") || tag.hasPrefix("3c") || tag.hasPrefix("4c") || tag.hasPrefix("c&") || tag == "c" {
                        let prefix = tag.hasPrefix("c") ? 1 : 2
                        let existing = tag.hasPrefix("3c") ? current.outlineColor : tag.hasPrefix("4c") ? current.shadowColor : current.primary
                        let fallback = tag.hasPrefix("3c") ? base.outlineColor : tag.hasPrefix("4c") ? base.shadowColor : base.primary
                        let rawColor = String(tag.dropFirst(prefix))
                        let color = rawColor.isEmpty ? fallback : ASSColor.parse(rawColor, alpha: existing.alpha)
                        if let color {
                            if tag.hasPrefix("3c") { current.outlineColor = color }
                            else if tag.hasPrefix("4c") { current.shadowColor = color }
                            else { current.primary = color }
                        }
                    } else if tag.hasPrefix("fscx") { current.scaleX = numeric("fscx", 10...400, 100) / 100 }
                    else if tag.hasPrefix("fscy") { current.scaleY = numeric("fscy", 10...400, 100) / 100 }
                    else if tag.hasPrefix("fsp") { current.spacing = numeric("fsp", -50...100, 0) }
                    else if tag.hasPrefix("fs") { current.size = numeric("fs", 1...256, base.size) }
                    else if tag.hasPrefix("fn") { current.font = tag.count == 2 ? base.font : String(tag.dropFirst(2).prefix(128)) }
                    else if tag.hasPrefix("frz") { current.rotation = numeric("frz", -3600...3600, 0) }
                    else if tag.hasPrefix("bord") { current.outline = numeric("bord", 0...20, base.outline) }
                    else if tag.hasPrefix("shad") { current.shadow = numeric("shad", 0...20, base.shadow) }
                    else if tag == "b" || tag.hasPrefix("b") && Int(tag.dropFirst()) != nil { current.bold = tag == "b" ? base.bold : tag.dropFirst() != "0" }
                    else if tag == "i" || tag.hasPrefix("i") && Int(tag.dropFirst()) != nil { current.italic = tag == "i" ? base.italic : tag.dropFirst() != "0" }
                    else if tag == "u" || tag.hasPrefix("u") && Int(tag.dropFirst()) != nil { current.underline = tag == "u" ? base.underline : tag.dropFirst() != "0" }
                    else if tag.hasPrefix("r") { current = styles[tag.dropFirst().lowercased()] ?? base }
                    else if tag.hasPrefix("a"), let value = Int(tag.dropFirst()) { current.alignment = legacyAlignment(value) }
                    else if tag.hasPrefix("p"), let value = Int(tag.dropFirst()) { drawing = value != 0; event.hasUnsupportedEffects = true }
                    else if !tag.isEmpty { event.hasUnsupportedEffects = true }
                }
                event.style.alignment = current.alignment
                event.style.rotation = current.rotation
                event.style.shadow = current.shadow
                event.style.shadowColor = current.shadowColor
                event.style.opaqueBox = current.opaqueBox
                index = text.index(after: end)
            } else {
                let end = text[index...].firstIndex(of: "{") ?? text.endIndex
                // Unclosed override braces are literal text, and must still advance.
                let next = end == index ? text.endIndex : end
                let plain = String(text[index..<next]).replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: "\u{00a0}")
                if !drawing, !plain.isEmpty, event.runs.count < 256 { event.runs.append(.init(text: plain, style: current)) }
                index = next
            }
        }
    }
}

nonisolated enum ASSSubtitleRenderer {
    static func render(_ events: [ASSSubtitle], at time: Double) throws -> SubtitleImageFrame {
        guard let canvas = events.first?.canvas, canvas.width > 0, canvas.height > 0 else { throw SubtitleDecodingError.invalid }
        let scale = min(1, 1920 / canvas.width, 1080 / canvas.height)
        let width = max(1, Int(ceil(canvas.width * scale))), height = max(1, Int(ceil(canvas.height * scale)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SubtitleDecodingError.invalid }
        context.scaleBy(x: scale, y: scale)
        var stacking: [Int: CGFloat] = [:]
        var glyphCount = 0
        for event in events.prefix(64).sorted(by: { $0.layer < $1.layer }) {
            try Task.checkCancellation()
            let style = event.style
            let string = NSMutableAttributedString(string: "")
            for run in event.runs {
                glyphCount += run.text.utf16.count
                guard glyphCount <= 32_768 else { throw SubtitleDecodingError.limit }
                let s = run.style
                var matrix = CGAffineTransform(scaleX: s.scaleX, y: s.scaleY)
                let base = CTFontCreateWithName(s.font as CFString, s.size, &matrix)
                var traits: CTFontSymbolicTraits = []
                if s.bold { traits.insert(.boldTrait) }; if s.italic { traits.insert(.italicTrait) }
                let font = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, [.boldTrait, .italicTrait]) ?? base
                var alignment: CTTextAlignment = style.alignment % 3 == 1 ? .left : style.alignment % 3 == 0 ? .right : .center
                let paragraph = withUnsafePointer(to: &alignment) { p in
                    var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: p)
                    return CTParagraphStyleCreate(&setting, 1)
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): s.primary.cgColor,
                    .init(kCTStrokeColorAttributeName as String): s.outlineColor.cgColor,
                    .init(kCTStrokeWidthAttributeName as String): -100 * s.outline / max(1, s.size),
                    .init(kCTKernAttributeName as String): s.spacing,
                    .init(kCTUnderlineStyleAttributeName as String): s.underline ? 1 : 0,
                    .init(kCTParagraphStyleAttributeName as String): paragraph]
                string.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            let setter = CTFramesetterCreateWithAttributedString(string)
            let maxWidth = max(1, canvas.width - style.marginL - style.marginR)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: maxWidth, height: canvas.height), nil)
            let size = CGSize(width: min(maxWidth, ceil(measured.width) + 2), height: min(canvas.height, ceil(measured.height) + 2))
            let column = (style.alignment - 1) % 3, row = (style.alignment - 1) / 3
            var anchor = event.position
            if let motion = event.motion {
                let t = min(max((time - event.start - motion.start) / max(0.001, motion.end - motion.start), 0), 1)
                anchor = CGPoint(x: motion.from.x + (motion.to.x - motion.from.x) * t, y: motion.from.y + (motion.to.y - motion.from.y) * t)
            }
            let key = event.layer * 10 + style.alignment
            let stack = anchor == nil ? stacking[key, default: 0] : 0
            let x = anchor?.x ?? (column == 0 ? style.marginL : column == 2 ? canvas.width - style.marginR : canvas.width / 2)
            let y = anchor?.y ?? (row == 0 ? canvas.height - style.marginV - stack : row == 2 ? style.marginV + stack : canvas.height / 2 + stack)
            let left = x - (column == 0 ? 0 : column == 2 ? size.width : size.width / 2)
            let top = y - (row == 0 ? size.height : row == 2 ? 0 : size.height / 2)
            let rect = CGRect(x: left, y: canvas.height - top - size.height, width: size.width, height: size.height)
            if anchor == nil { stacking[key, default: 0] += size.height + 2 }
            var opacity = 1.0
            if event.fadeIn > 0 { opacity = min(opacity, max(0, (time - event.start) / event.fadeIn)) }
            if event.fadeOut > 0 { opacity = min(opacity, max(0, (event.end - time) / event.fadeOut)) }
            context.saveGState()
            context.setAlpha(opacity)
            context.translateBy(x: x, y: canvas.height - y)
            context.rotate(by: style.rotation * .pi / 180)
            context.translateBy(x: -x, y: -(canvas.height - y))
            if style.opaqueBox { context.setFillColor(style.shadowColor.cgColor); context.fill(rect.insetBy(dx: -style.outline, dy: -style.outline)) }
            context.setShadow(offset: CGSize(width: style.shadow, height: -style.shadow), blur: 0, color: style.shadowColor.cgColor)
            context.textMatrix = .identity
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw SubtitleDecodingError.invalid }
        return SubtitleImageFrame(canvas: canvas, parts: [.init(image: image, bounds: CGRect(origin: .zero, size: canvas))])
    }
}
