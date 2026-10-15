import Foundation

enum EndOfPlaybackAction: String, CaseIterable, Identifiable {
    case stay, rewind, repeatFile, close
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stay: return "Stay at End"
        case .rewind: return "Rewind and Pause"
        case .repeatFile: return "Repeat File"
        case .close: return "Close File"
        }
    }
}
