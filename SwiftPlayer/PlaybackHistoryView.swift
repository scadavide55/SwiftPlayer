import SwiftUI

struct PlaybackHistoryView: View {
    @ObservedObject var history: PlaybackHistoryStore
    let open: (URL, Double) -> Void
    @State private var query = ""
    @State private var filter = "All"
    @State private var confirmClear = false
    @State private var errorMessage = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let visible = history.entries.filter {
            (query.isEmpty || $0.name.localizedStandardContains(query)) &&
            (filter == "All" || (filter == "Finished" ? $0.isFinished : !$0.isFinished))
        }
        VStack(alignment: .leading, spacing: 14) {
            Text("Playback History").font(.title2)
            TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
            Picker("Show", selection: $filter) {
                ForEach(["All", "Unfinished", "Finished"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            if !history.enabled { Text("History recording is turned off in Settings.").foregroundStyle(.secondary) }
            else if visible.isEmpty { Text(query.isEmpty ? "No playback history to show." : "No matching files.").foregroundStyle(.secondary) }
            if !errorMessage.isEmpty { Text(errorMessage).font(.callout).foregroundStyle(.secondary) }
            List(visible) { entry in
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
                        if entry.duration > 0 {
                            ProgressView(value: entry.progress).accessibilityLabel("Playback progress")
                            Text(entry.isFinished ? "Finished" : "\(formatTime(entry.position)) / \(formatTime(entry.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.lastPlayed, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(entry.continuePosition > 0 ? "Continue" : "Play") {
                        do {
                            let url = try history.resolve(entry)
                            open(url, entry.continuePosition)
                            dismiss()
                        } catch { errorMessage = "This file is unavailable. Use Open File to locate it again, or remove it from history." }
                    }
                    Button { history.remove(entry) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.name) from history")
                }.padding(.vertical, 5)
            }
            Text("History stays on this Mac. Up to 200 files are kept for \(history.retentionDays) days. Continue works independently of automatic resume.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Clear History…", role: .destructive) { confirmClear = true }.disabled(history.entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 620, height: 520)
        .confirmationDialog("Clear playback history and its saved progress?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        }
    }
}

struct PlaybackHistorySettings: View {
    @ObservedObject private var history = PlaybackHistoryStore.shared
    @State private var confirmClear = false
    var body: some View {
        Section("Playback History") {
            Toggle("Record playback history", isOn: $history.enabled)
            Picker("Keep history for", selection: $history.retentionDays) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
            }.disabled(!history.enabled)
            Text("Stored only on this Mac, up to 200 files. Turning recording off clears this list and its progress.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear History…", role: .destructive) { confirmClear = true }.disabled(history.entries.isEmpty)
        }.confirmationDialog("Clear playback history and its saved progress?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        }
    }
}
