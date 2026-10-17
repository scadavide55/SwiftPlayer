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

func parsePlaybackTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), !parts.contains(where: { $0.isEmpty }) else { return nil }
    var result: Double = 0
    for (index, part) in parts.enumerated() {
        guard part.allSatisfy({ $0.isNumber || $0 == "." }), let value = Double(part), value.isFinite, value >= 0,
              index == parts.count - 1 || value.rounded(.down) == value,
              index == 0 || value < 60 else { return nil }
        result = result * 60 + value
    }
    return result.isFinite ? result : nil
}

func formatPlaybackRate(_ rate: Float) -> String {
    String(format: "%g×", rate)
}

func formatNavigationTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) / 1_000 else { return "0:00.000" }
    let milliseconds = Int((seconds * 1_000).rounded())
    return formatTime(Double(milliseconds / 1_000)) + String(format: ".%03d", milliseconds % 1_000)
}

func formatNavigationFrame(_ seconds: Double, frameRate: Double?) -> String {
    guard seconds.isFinite, seconds >= 0, let rate = frameRate, rate.isFinite, rate > 0,
          seconds * rate < Double(Int.max - 1) else { return "Frame —" }
    // Nominal FPS cannot identify the exact sample index in variable-rate media.
    return "Frame ≈ \(Int((seconds * rate).rounded(.down)) + 1)"
}
