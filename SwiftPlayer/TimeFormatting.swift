import Foundation

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return "\(h):" + String(format: "%02d:%02d", m, s)
    } else {
        return String(format: "%d:%02d", m, s)
    }
}
