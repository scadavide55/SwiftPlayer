import SwiftUI

struct SubtitleSelectionPicker: View {
    @ObservedObject var media: PlayerMediaControls
    var body: some View {
        Picker("Subtitle track", selection: $media.subtitleSelection) {
            Text("Off").tag("off")
            Text("Automatic").tag("automatic")
            ForEach(media.subtitleTracks) { Text($0.name).tag($0.id) }
            if !media.externalSubtitleName.isEmpty { Text("External: \(media.externalSubtitleName)").tag("external") }
        }
    }
}

struct AudioSelectionPicker: View {
    @ObservedObject var media: PlayerMediaControls
    var body: some View {
        Picker("Audio track", selection: $media.audioSelection) {
            Text("Automatic").tag("automatic")
            ForEach(media.audioTracks) { Text($0.name).tag($0.id) }
        }
    }
}

struct SubtitlePanel: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var media: PlayerMediaControls
    @ObservedObject var preferences: PlayerPreferences
    let openFile: () -> Void
    let appearance: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SubtitleSelectionPicker(media: media)
            Button("Load Subtitle File…", action: openFile)
            LanguagePreferencePicker(title: "Preferred language", selection: $preferences.subtitleLanguage)
            Button("Appearance and Fonts…", action: appearance)
            if media.subtitleSelection == "external" {
                Divider()
                Toggle("Show external subtitles", isOn: $model.subtitlesEnabled)
                Text("Subtitle delay: \(model.subtitleOffset, specifier: "%+.1f") s").monospacedDigit()
                Slider(value: $model.subtitleOffset, in: -30...30, step: 0.1).accessibilityLabel("External subtitle delay")
            }
            if !media.subtitleStatusMessage.isEmpty { Text(media.subtitleStatusMessage).font(.caption).foregroundStyle(.secondary) }
            if media.isDiscovering { ProgressView("Finding tracks…") }
        }.padding(16).frame(width: 340)
    }
}

struct JumpToTimeView: View {
    let duration: Double
    let jump: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool
    private var target: Double? {
        guard let value = parsePlaybackTime(input), value <= duration else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Jump to Time").font(.headline)
            TextField("Hours:minutes:seconds", text: $input).focused($focused)
            Text("Enter seconds, minutes:seconds, or hours:minutes:seconds. Duration: \(formatTime(duration)).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Jump") { if let target { jump(target); dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(target == nil)
            }
        }.padding(24).frame(width: 380).onAppear { focused = true }
    }
}

struct MediaInformationView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var media: PlayerMediaControls
    @Environment(\.dismiss) private var dismiss
    private func codec(_ value: String) -> String {
        switch value { case "hvc1", "hev1": return "HEVC (H.265)"; case "avc1": return "H.264"; case "mp4a", "aac ", "aac": return "AAC"; case "tx3g": return "Timed text"; case "wvtt": return "WebVTT"; default: return value }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Media Information").font(.title2)
            Text(model.currentFileName).font(.headline).textSelection(.enabled)
            Text("Duration: \(formatTime(model.duration))")
            if media.isDiscovering { ProgressView("Reading media information…") }
            if !media.informationError.isEmpty { Text(media.informationError).foregroundStyle(.secondary) }
            List(media.streams) { stream in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stream.kind) · \(codec(stream.codec))").font(.headline)
                    Text(stream.details).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 480, height: 400)
    }
}
