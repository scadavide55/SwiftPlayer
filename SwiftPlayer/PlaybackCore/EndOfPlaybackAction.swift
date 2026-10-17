import Foundation

enum EndOfPlaybackAction: String, CaseIterable, Identifiable {
    case stay, repeatFile
    var id: String { rawValue }
    var title: String { self == .stay ? "Stop at End" : "Repeat File" }
}
