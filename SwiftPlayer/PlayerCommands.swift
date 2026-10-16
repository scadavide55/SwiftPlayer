import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct PlayerWindowContext: Equatable {
    let menus: PlayerMenuState
    let open: (URL) -> Void
    let jump: () -> Void
    let information: () -> Void
    let subtitles: () -> Void
    let findSubtitles: () -> Void
    let appearance: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.menus === rhs.menus }
}

/// Keep the scene's command target stable as its playback view redraws.
struct PlayerCommandFocus: View, Equatable {
    let context: PlayerWindowContext
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .focusedSceneValue(\.playerWindow, context)
            .accessibilityHidden(true)
    }
}
private struct PlayerWindowKey: FocusedValueKey { typealias Value = PlayerWindowContext }
extension FocusedValues {
    var playerWindow: PlayerWindowContext? {
        get { self[PlayerWindowKey.self] }
        set { self[PlayerWindowKey.self] = newValue }
    }
}

struct PlayerCommands: Commands {
    @FocusedValue(\.playerWindow) private var window
    @ObservedObject private var recent = RecentMediaStore.shared
    @StateObject private var inactive = PlayerMenuState()
    @ObservedObject private var preferences = PlayerPreferences.shared
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Player Window") { openWindow(id: "player") }.keyboardShortcut("n")
            Button("Open File…") { pickFile() }.keyboardShortcut("o").disabled(window == nil)
            Menu("Open Recent") {
                if recent.entries.isEmpty { Text("No Recent Files") }
                ForEach(recent.entries) { entry in
                    Button(entry.name) {
                        do { window?.open(try recent.resolve(entry)) }
                        catch {
                            let alert = NSAlert()
                            alert.messageText = "This recent file could not be opened."
                            alert.informativeText = "Use Open File to locate it again."
                            alert.runModal()
                        }
                    }.disabled(window == nil)
                }
                Divider()
                Button("Clear Menu") { recent.clear() }.disabled(recent.entries.isEmpty)
            }
        }
        CommandMenu("Playback") {
            PlaybackMenu(state: window?.menus ?? inactive, preferences: preferences, jump: { window?.jump() })
        }
        CommandMenu("Audio") {
            AudioMenu(state: window?.menus ?? inactive, preferences: preferences)
        }
        CommandMenu("Subtitles") {
            SubtitlesMenu(state: window?.menus ?? inactive, preferences: preferences,
                          load: { window?.subtitles() }, find: { window?.findSubtitles() }, appearance: { window?.appearance() })
                .disabled(window == nil)
        }
        CommandGroup(after: .windowArrangement) {
            MediaInformationCommand(state: window?.menus ?? inactive, action: { window?.information() })
        }
    }
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { window?.open(url) }
    }
}

struct PlaybackMenu: View {
    @ObservedObject var state: PlayerMenuState
    @ObservedObject var preferences: PlayerPreferences
    let jump: () -> Void
    var body: some View {
        Button(state.snapshot.playbackRequested ? "Pause" : "Play") { state.model?.togglePlayPause() }
            .disabled(!state.snapshot.hasMedia)
        Picker("Speed", selection: Binding(get: { state.snapshot.playbackRate }, set: { state.model?.playbackRate = $0 })) {
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { Text(formatPlaybackRate($0)).tag($0) }
        }.disabled(!state.snapshot.hasMedia)
        Divider()
        Button("Jump to Time…", action: jump).keyboardShortcut("j").disabled(!state.snapshot.canNavigate)
        Menu("Chapters") {
            ForEach(state.snapshot.chapters) { chapter in
                Button("\(formatTime(chapter.start)) · \(chapter.title)") { state.model?.seek(to: chapter.start) }
            }
        }.disabled(state.snapshot.chapters.isEmpty)
        Button("Back 10 Seconds") {
            if let model = state.model { model.seek(to: model.currentTime - 10) }
        }.disabled(!state.snapshot.canNavigate)
        Button("Forward 10 Seconds") {
            if let model = state.model { model.seek(to: model.currentTime + 10) }
        }.disabled(!state.snapshot.canNavigate)
        Divider()
        Picker("After Playback", selection: $preferences.afterPlayback) {
            ForEach(EndOfPlaybackAction.allCases) { Text($0.title).tag($0) }
        }
    }
}

struct AudioMenu: View {
    @ObservedObject var state: PlayerMenuState
    @ObservedObject var preferences: PlayerPreferences
    var body: some View {
        Picker("Audio Track", selection: Binding(get: { state.snapshot.audioSelection }, set: { state.model?.mediaControls.audioSelection = $0 })) {
            Text("Automatic").tag("automatic")
            ForEach(state.snapshot.audioTracks) { Text($0.name).tag($0.id) }
        }.disabled(state.snapshot.audioTracks.isEmpty)
        LanguagePreferencePicker(title: "Preferred Language", selection: $preferences.audioLanguage)
        Divider()
        Toggle("Mute", isOn: Binding(get: { state.snapshot.isMuted }, set: { state.model?.isMuted = $0 }))
            .disabled(state.model == nil)
        Button("Increase Volume") { state.model?.volumeUp() }.disabled(state.model == nil)
        Button("Decrease Volume") { state.model?.volumeDown() }.disabled(state.model == nil)
    }
}

struct SubtitlesMenu: View {
    @ObservedObject var state: PlayerMenuState
    @ObservedObject var preferences: PlayerPreferences
    let load: () -> Void
    let find: () -> Void
    let appearance: () -> Void
    var body: some View {
        Picker("Subtitle Track", selection: Binding(get: { state.snapshot.subtitleSelection }, set: { state.model?.mediaControls.subtitleSelection = $0 })) {
            Text("Off").tag("off")
            Text("Automatic").tag("automatic")
            ForEach(state.snapshot.subtitleTracks) { Text($0.name).tag($0.id) }
            if !state.snapshot.externalSubtitleName.isEmpty {
                Text("External: \(state.snapshot.externalSubtitleName)").tag("external")
            }
        }.disabled(!state.snapshot.hasMedia)
        Button("Load Subtitle File…", action: load).disabled(!state.snapshot.hasMedia)
        Button("Find Matching Subtitles…", action: find).disabled(!state.snapshot.hasMedia)
        Picker("External Text Encoding", selection: Binding(get: { state.snapshot.subtitleEncoding },
            set: { state.model?.reloadSubtitles(encoding: $0) })) {
            ForEach(SubtitleEncoding.allCases) { Text($0.title).tag($0) }
        }.disabled(state.snapshot.externalSubtitleName.isEmpty)
        LanguagePreferencePicker(title: "Preferred Language", selection: $preferences.subtitleLanguage)
        Divider()
        Button("Appearance and Fonts…", action: appearance)
        Divider()
        Button("Subtitles Earlier") { state.model?.subtitleOffset -= 0.1 }
            .keyboardShortcut(.leftArrow, modifiers: [.option]).disabled(!state.snapshot.hasMedia)
        Button("Subtitles Later") { state.model?.subtitleOffset += 0.1 }
            .keyboardShortcut(.rightArrow, modifiers: [.option]).disabled(!state.snapshot.hasMedia)
        Button("Reset Subtitle Timing") { state.model?.subtitleOffset = 0 }
            .disabled(!state.snapshot.hasMedia || state.snapshot.subtitleDelay == 0)
    }
}

private struct MediaInformationCommand: View {
    @ObservedObject var state: PlayerMenuState
    let action: () -> Void
    var body: some View {
        Button("Media Information…", action: action).keyboardShortcut("i")
            .disabled(!state.snapshot.hasMedia)
    }
}
