import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct PlayerWindowContext {
    let model: PlayerModel
    let open: (URL) -> Void
    let jump: () -> Void
    let information: () -> Void
    let subtitles: () -> Void
    let appearance: () -> Void
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
            if let window {
                PlaybackMenu(model: window.model, media: window.model.mediaControls, jump: window.jump)
            } else { Text("No Active Player") }
        }
        CommandMenu("Audio") {
            if let window {
                AudioMenu(model: window.model, media: window.model.mediaControls, preferences: preferences)
            } else { Text("No Active Player") }
        }
        CommandMenu("Subtitles") {
            if let window {
                SubtitleSelectionPicker(media: window.model.mediaControls)
                    .disabled(window.model.player.currentItem == nil)
                Button("Load Subtitle File…", action: window.subtitles).disabled(window.model.player.currentItem == nil)
                LanguagePreferencePicker(title: "Preferred Language", selection: $preferences.subtitleLanguage)
                Divider()
                Button("Appearance and Fonts…", action: window.appearance)
            } else { Text("No Active Player") }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Media Information…") { window?.information() }.keyboardShortcut("i")
                .disabled(window?.model.player.currentItem == nil)
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

private struct PlaybackMenu: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var media: PlayerMediaControls
    let jump: () -> Void
    var body: some View {
        Button(model.playbackRequested ? "Pause" : "Play") { model.togglePlayPause() }
            .disabled(model.player.currentItem == nil)
        Picker("Speed", selection: $model.playbackRate) {
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { Text(formatPlaybackRate($0)).tag($0) }
        }.disabled(model.player.currentItem == nil)
        Button("Jump to Time…", action: jump).keyboardShortcut("j").disabled(model.duration <= 0)
        Menu("Chapters") {
            ForEach(media.chapters) { chapter in Button("\(formatTime(chapter.start)) · \(chapter.title)") { model.seek(to: chapter.start) } }
        }.disabled(media.chapters.isEmpty)
        Button("Back 10 Seconds") { model.seek(to: model.currentTime - 10) }.disabled(model.duration <= 0)
        Button("Forward 10 Seconds") { model.seek(to: model.currentTime + 10) }.disabled(model.duration <= 0)
    }
}

private struct AudioMenu: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var media: PlayerMediaControls
    @ObservedObject var preferences: PlayerPreferences
    var body: some View {
        AudioSelectionPicker(media: media).disabled(media.audioTracks.isEmpty)
        LanguagePreferencePicker(title: "Preferred Language", selection: $preferences.audioLanguage)
        Divider()
        Toggle("Mute", isOn: $model.isMuted)
        Button("Increase Volume") { model.volumeUp() }
        Button("Decrease Volume") { model.volumeDown() }
    }
}
