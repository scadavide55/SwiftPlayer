import SwiftUI
import AppKit

struct StyledSubtitle: View {
    let text: String
    let appearance: SubtitleAppearance
    private var color: Color {
        switch appearance.color { case "Yellow": return .yellow; case "Green": return .green; case "Cyan": return .cyan; default: return .white }
    }
    var body: some View {
        Text(text)
            .font(appearance.fontFamily == "System" ? .system(size: appearance.size, weight: .semibold) : .custom(appearance.fontFamily, size: appearance.size))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .shadow(color: appearance.outline ? .black : .clear, radius: 0, x: -1, y: -1)
            .shadow(color: appearance.outline ? .black : .clear, radius: 0, x: 1, y: -1)
            .shadow(color: appearance.outline ? .black : .clear, radius: 0, x: -1, y: 1)
            .shadow(color: appearance.outline ? .black : .clear, radius: 0, x: 1, y: 1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.black.opacity(appearance.backgroundOpacity), in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
    }
}

struct LanguagePreferencePicker: View {
    let title: String
    @Binding var selection: String
    private var languages: [(String, String)] {
        let codes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + ["zh-Hans", "zh-Hant"])
        return codes.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }
    var body: some View {
        Picker(title, selection: $selection) {
            Text("Automatic").tag("")
            ForEach(languages, id: \.0) { code, name in Text(name).tag(code) }
        }
    }
}

struct SubtitleAppearanceView: View {
    @ObservedObject var preferences: PlayerPreferences
    var body: some View {
        Form {
            Picker("Font", selection: $preferences.appearance.fontFamily) {
                Text("System").tag("System")
                ForEach(Array(Set(NSFontManager.shared.availableFontFamilies + [preferences.appearance.fontFamily])).filter { $0 != "System" }.sorted(), id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Text size")
                Slider(value: $preferences.appearance.size, in: 12...64, step: 1).accessibilityLabel("Subtitle text size")
                Text("\(Int(preferences.appearance.size)) pt").monospacedDigit().frame(width: 45)
            }
            Picker("Text color", selection: $preferences.appearance.color) {
                ForEach(["White", "Yellow", "Green", "Cyan"], id: \.self) { Text($0).tag($0) }
            }
            Toggle("Text outline", isOn: $preferences.appearance.outline)
            HStack {
                Text("Background opacity")
                Slider(value: $preferences.appearance.backgroundOpacity, in: 0...1).accessibilityLabel("Subtitle background opacity")
            }
            Picker("Position", selection: $preferences.appearance.position) {
                ForEach(["Bottom", "Center", "Top"], id: \.self) { Text($0).tag($0) }
            }
            StyledSubtitle(text: "Subtitles look like this", appearance: preferences.appearance)
                .frame(maxWidth: .infinity, minHeight: 90).background(.gray.opacity(0.3))
            Text("Picture in Picture uses the system’s embedded-caption appearance. External subtitle files appear in the main player window.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
    }
}

struct PlayerPreferencesView: View {
    @ObservedObject var preferences: PlayerPreferences
    var body: some View {
        TabView {
            Form {
                Section("Languages") {
                    LanguagePreferencePicker(title: "Subtitle language", selection: $preferences.subtitleLanguage)
                    LanguagePreferencePicker(title: "Audio language", selection: $preferences.audioLanguage)
                    Toggle("Show embedded subtitles automatically", isOn: $preferences.subtitlesByDefault)
                }
                Section("Playback") {
                    Toggle("Keep the display awake while video plays", isOn: $preferences.keepDisplayAwake)
                    HStack {
                        Text("Maximum volume")
                        Slider(value: $preferences.maximumVolume, in: 1...4, step: 0.05)
                            .accessibilityLabel("Maximum volume")
                            .accessibilityValue("\(Int((preferences.maximumVolume * 100).rounded())) percent")
                        Text("\(Int((preferences.maximumVolume * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Toggle("Protect boosted audio peaks", isOn: $preferences.limitAudioPeaks)
                    Toggle("Normalize audio level", isOn: $preferences.normalizeAudio)
                    Text("Normalization balances quiet and loud passages. Peak protection reduces distortion when boosting volume.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Remember tracks and subtitle timing for each file", isOn: $preferences.rememberFileSettings)
                    Toggle("Remember volume and mute", isOn: $preferences.rememberVolume)
                    Picker("After playback", selection: $preferences.afterPlayback) {
                        ForEach(EndOfPlaybackAction.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Resume files from the last position", isOn: $preferences.resumePlayback)
                    Text("Turning automatic resume off clears its saved positions. History progress is controlled separately.").font(.caption).foregroundStyle(.secondary)
                }
                PlaybackHistorySettings()
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            SubtitleSearchSettingsView(preferences: preferences).tabItem { Label("Subtitle Files", systemImage: "folder") }
            SubtitleAppearanceView(preferences: preferences).tabItem { Label("Subtitle Appearance", systemImage: "textformat") }
        }.padding(12).frame(width: 510, height: 490)
    }
}

struct CaptionOverlay: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var media: PlayerMediaControls
    @ObservedObject var preferences: PlayerPreferences
    let controlsVisible: Bool
    let nativeRendering: Bool
    private var text: String {
        if media.subtitleSelection == "off" { return "" }
        if media.subtitleSelection == "external" { return model.currentSubtitleText }
        return nativeRendering ? "" : media.embeddedText
    }
    var body: some View {
        VStack {
            if preferences.appearance.position != "Top" { Spacer(minLength: 0) }
            if !text.isEmpty { StyledSubtitle(text: text, appearance: preferences.appearance) }
            if preferences.appearance.position != "Bottom" { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 20)
        .padding(.top, controlsVisible ? 70 : 24)
        .padding(.bottom, controlsVisible ? 70 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
