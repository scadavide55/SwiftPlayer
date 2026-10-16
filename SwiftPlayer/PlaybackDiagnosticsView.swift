import SwiftUI

struct PlaybackDiagnosticsView: View {
    let model: PlayerModel
    @StateObject private var diagnostics = PlaybackDiagnostics()

    private func time(_ value: Double?) -> String { value.map(formatTime) ?? "Not reported" }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "Not reported" }
    private func flag(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "Not reported" }
    private func rate(_ value: Float?) -> String { value.map(formatPlaybackRate) ?? "Not reported" }
    private var memory: String {
        guard let bytes = diagnostics.snapshot.memoryBytes, bytes <= UInt64(Int64.max) else { return "Not reported" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    var body: some View {
        let snapshot = diagnostics.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                    row("Playback", snapshot.state.rawValue)
                    if let reason = snapshot.waitingReason { row("Waiting reason", reason) }
                    row("Position", time(snapshot.position))
                    row("Duration", time(snapshot.duration))
                    row("Selected speed", rate(snapshot.selectedRate))
                    row("Actual speed", rate(snapshot.actualRate))
                    row("Buffered ahead", seconds(snapshot.buffer.ahead))
                    row(snapshot.buffer.isTruncated ? "Loaded time (sample)" : "Reported loaded time", time(snapshot.buffer.total))
                    row("Buffer empty", flag(snapshot.bufferEmpty))
                    row("Buffer full", flag(snapshot.bufferFull))
                    row("Likely to keep up", flag(snapshot.likelyToKeepUp))
                    if let width = snapshot.width, let height = snapshot.height { row("Presentation size", "\(width) × \(height)") }
                    row("App memory (all windows)", memory)
                }
                if !snapshot.buffer.ranges.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reported loaded ranges").font(.headline)
                        ForEach(Array(snapshot.buffer.ranges.prefix(8).enumerated()), id: \.offset) { _, range in
                            Text("\(formatTime(range.start)) – \(formatTime(range.end))").monospacedDigit()
                        }
                        if snapshot.buffer.ranges.count > 8 { Text("\(snapshot.buffer.ranges.count - 8) more ranges") }
                        if snapshot.buffer.isTruncated { Text("Limited to the first 256 native ranges.") }
                    }.font(.caption)
                }
                Text("Updates once per second while this panel is visible. Buffer values are AVFoundation reports; local files may provide limited buffering information. App memory includes all windows and framework buffers.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Frame rate in Streams is the file's nominal rate. Live renderer and dropped-frame counters are not collected.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { diagnostics.start(model) }
        .onDisappear { diagnostics.stop() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }
}
