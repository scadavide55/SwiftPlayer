import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

nonisolated struct FrameCaption: Sendable {
    let text: String
    let fontName: String
    let size: Double
    let color: String
    let outline: Bool
    let backgroundOpacity: Double
    let position: String
    let referenceHeight: Double
}

nonisolated enum FrameCaptureImage {
    static func png(_ image: CGImage, caption: FrameCaption?) throws -> Data {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let caption, !caption.text.isEmpty { draw(caption, in: context, width: CGFloat(image.width), height: CGFloat(image.height)) }
        try Task.checkCancellation()
        guard let rendered = context.makeImage() else { throw failure() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw failure() }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure() }
        try Task.checkCancellation()
        return data as Data
    }

    private static func draw(_ caption: FrameCaption, in context: CGContext, width: CGFloat, height: CGFloat) {
        let scale = height / max(1, caption.referenceHeight)
        let fontSize = min(max(12, caption.size * scale), height * 0.2)
        let font = CTFontCreateWithName(caption.fontName as CFString, fontSize, nil)
        let color: CGColor
        switch caption.color {
        case "Yellow": color = CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        case "Green": color = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        case "Cyan": color = CGColor(red: 0, green: 1, blue: 1, alpha: 1)
        default: color = CGColor(gray: 1, alpha: 1)
        }
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
        if caption.outline {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -3
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: 1)
        }
        let bounded = String(decoding: Array(caption.text.utf16.prefix(8192)), as: UTF16.self)
        let text = NSAttributedString(string: bounded, attributes: attributes)
        let setter = CTFramesetterCreateWithAttributedString(text)
        let padding = max(4, 6 * scale)
        let textWidth = max(1, width * 0.9 - 2 * padding)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: textWidth, height: height * 0.5), nil)
        let boxHeight = min(height * 0.5, ceil(suggested.height) + 2 * padding)
        let boxWidth = min(width * 0.9, ceil(suggested.width) + 2 * padding)
        let y: CGFloat
        switch caption.position {
        case "Top": y = height - height * 0.04 - boxHeight
        case "Center": y = (height - boxHeight) / 2
        default: y = height * 0.04
        }
        let box = CGRect(x: (width - boxWidth) / 2, y: y, width: boxWidth, height: boxHeight)
        context.setFillColor(CGColor(gray: 0, alpha: min(max(caption.backgroundOpacity, 0), 1)))
        context.addPath(CGPath(roundedRect: box, cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: padding, dy: padding), transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private static func failure() -> NSError {
        NSError(domain: "SwiftPlayer.FrameCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The frame could not be encoded as PNG."])
    }
}
