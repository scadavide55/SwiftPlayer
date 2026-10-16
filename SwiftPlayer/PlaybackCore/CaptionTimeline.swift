import Foundation

/// Bounded subtitle transitions support delayed/early display without retaining
/// an entire media file's decoded captions. A flush discards the old seek sequence.
struct CaptionTimeline {
    struct Event { let time: Double; let text: String }
    private(set) var events: [Event] = []
    static let maximumEvents = 512

    mutating func insert(time: Double, text: String) {
        guard time.isFinite else { return }
        let bounded = String(decoding: Array(text.utf16.prefix(8192)), as: UTF16.self)
        if let existing = events.firstIndex(where: { $0.time == time }) { events.remove(at: existing) }
        let index = events.firstIndex(where: { $0.time > time }) ?? events.endIndex
        events.insert(Event(time: time, text: bounded), at: index)
        if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
    }

    mutating func text(at time: Double) -> String {
        guard time.isFinite else { return "" }
        // Retain one predecessor so long cues survive the history window.
        if let predecessor = events.lastIndex(where: { $0.time < time - 90 }), predecessor > 0 {
            events.removeFirst(predecessor)
        }
        return events.last(where: { $0.time <= time })?.text ?? ""
    }

    mutating func reset() { events.removeAll(keepingCapacity: false) }
}
