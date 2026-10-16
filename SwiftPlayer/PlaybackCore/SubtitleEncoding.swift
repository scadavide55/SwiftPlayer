import Foundation
import CoreFoundation

nonisolated enum SubtitleEncoding: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, utf8, utf16, big5, gb18030, shiftJIS
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic (Unicode)"
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16 (BOM)"
        case .big5: return "Traditional Chinese (Big5)"
        case .gb18030: return "Simplified Chinese (GB18030)"
        case .shiftJIS: return "Japanese (Shift-JIS)"
        }
    }

    func decode(_ data: Data) -> String? {
        let hasUTF16BOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
        switch self {
        case .automatic: return String(data: data, encoding: hasUTF16BOM ? .utf16 : .utf8)
        case .utf8: return String(data: data, encoding: .utf8)
        case .utf16: return hasUTF16BOM ? String(data: data, encoding: .utf16) : nil
        case .big5, .gb18030, .shiftJIS:
            let cfEncoding: CFStringEncodings
            switch self {
            case .big5: cfEncoding = .big5
            case .gb18030: cfEncoding = .GB_18030_2000
            default: cfEncoding = .shiftJIS
            }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue)))
            return String(data: data, encoding: encoding)
        }
    }
}
