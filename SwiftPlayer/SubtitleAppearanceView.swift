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
            Toggle("Use styles and positions from ASS/SSA files", isOn: $preferences.useSubtitleFileStyles)
            Text("Turn this off to use the font and appearance below for ASS/SSA text. Image subtitles retain their original appearance.")
                .font(.caption).foregroundStyle(.secondary)
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
                    Text("The volume keys and slider control Mac system volume for all apps, from 0% to 100%.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Protect audio peaks", isOn: $preferences.limitAudioPeaks)
                    Toggle("Normalize audio level", isOn: $preferences.normalizeAudio)
                    Text("Normalization balances quiet and loud passages. Peak protection reduces distortion during processing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Remember tracks and subtitle timing for each file", isOn: $preferences.rememberFileSettings)
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
    var display = VideoDisplayOptions()
    var videoSize = CGSize.zero
    private var text: String {
        if media.subtitleSelection == "off" { return "" }
        if media.subtitleSelection == "external" { return model.currentSubtitleText }
        return nativeRendering ? "" : media.embeddedText
    }
    var body: some View {
        if media.subtitleSelection == "external", let frame = model.currentSubtitleImage {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let custom = display.frame(in: bounds)
                let ratio = videoSize.width > 0 && videoSize.height > 0 ? videoSize.width / videoSize.height : frame.canvas.width / frame.canvas.height
                let fitted = display.aspect == .original ? subtitleVideoRect(bounds, ratio: ratio, fill: display.fit == .fill) : custom
                Canvas { context, _ in
                    for part in frame.parts {
                        let r = part.bounds
                        context.draw(Image(decorative: part.image, scale: 1), in: CGRect(
                            x: fitted.minX + r.minX / frame.canvas.width * fitted.width,
                            y: fitted.minY + r.minY / frame.canvas.height * fitted.height,
                            width: r.width / frame.canvas.width * fitted.width,
                            height: r.height / frame.canvas.height * fitted.height))
                    }
                }
            }.clipped().allowsHitTesting(false).accessibilityLabel("Image subtitles")
        } else {
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
}

private func subtitleVideoRect(_ bounds: CGRect, ratio: CGFloat, fill: Bool) -> CGRect {
    let useHeight = (bounds.width / max(1, bounds.height) > ratio) != fill
    let size = useHeight ? CGSize(width: bounds.height * ratio, height: bounds.height) : CGSize(width: bounds.width, height: bounds.width / ratio)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
}
