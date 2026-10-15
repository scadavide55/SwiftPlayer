import SwiftUI
import AppKit
import Combine

struct SubtitleSearchFolder: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let reference: SubtitleFileReference
}

@MainActor
final class SubtitleFolderStore: ObservableObject {
    static let shared = SubtitleFolderStore(defaults: .standard)
    @Published private(set) var entries: [SubtitleSearchFolder]
    private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let data = defaults.data(forKey: "subtitleSearchFolders") ?? Data()
        entries = data.count <= 256 * 1024 ? Array((try? JSONDecoder().decode([SubtitleSearchFolder].self, from: data))?.prefix(8) ?? []) : []
    }
    func add(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let reference = SubtitleFileReference.capture(url) else { return }
        entries.removeAll { $0.reference.resolve()?.standardizedFileURL == url.standardizedFileURL }
        entries.insert(SubtitleSearchFolder(id: UUID().uuidString, name: url.lastPathComponent, reference: reference), at: 0)
        entries = Array(entries.prefix(8))
        persist()
    }
    func remove(_ entry: SubtitleSearchFolder) { entries.removeAll { $0.id == entry.id }; persist() }
    private func persist() { defaults.set(try? JSONEncoder().encode(entries), forKey: "subtitleSearchFolders") }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Subtitle Folder"
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { add(url) }
    }
}

@MainActor
final class SubtitleSearchController: ObservableObject {
    @Published private(set) var matches: [SubtitleMatch] = []
    @Published private(set) var isSearching = false
    @Published private(set) var message = ""
    private var task: Task<Void, Never>?
    private var generation = UUID()
    deinit { task?.cancel() }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        matches = []
        message = ""
        isSearching = false
    }

    func start(model: PlayerModel, folders: [SubtitleSearchFolder], languages: [String], automatic: Bool) {
        cancel()
        guard let source = model.sourceURL else { return }
        guard !folders.isEmpty else { message = "Add a subtitle folder in Settings to find matching files."; return }
        isSearching = true
        let identifier = generation
        task = Task { [weak self, weak model] in
            defer { if self?.generation == identifier { self?.isSearching = false; self?.task = nil } }
            do {
                while true {
                    try Task.checkCancellation()
                    guard let current = model, current.sourceURL == source, !current.playbackFailed else { return }
                    if !current.isLoading && !current.mediaControls.isDiscovering { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let revision = model?.mediaControls.subtitleSelectionRevision else { return }
                if automatic && (model?.mediaControls.subtitleSelection != "automatic" || model?.hasPendingSubtitleLoad == true) { return }
                let worker = Task.detached(priority: .utility) {
                    var found: [SubtitleMatch] = []
                    for entry in folders {
                        try Task.checkCancellation()
                        if let folder = entry.reference.resolve() {
                            found += SubtitleMatching.find(in: folder, media: source, preferredLanguages: languages)
                        }
                    }
                    var seen = Set<String>()
                    return Array(found.sorted {
                        $0.rank == $1.rank ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.rank < $1.rank
                    }.filter { seen.insert($0.id).inserted }.prefix(128))
                }
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, let model, self.generation == identifier, model.sourceURL == source, !Task.isCancelled else { return }
                self.matches = found
                self.message = found.isEmpty ? "No matching subtitles were found in the selected folders." : ""
                if automatic, model.mediaControls.subtitleSelectionRevision == revision,
                   model.mediaControls.subtitleSelection == "automatic", !model.hasPendingSubtitleLoad,
                   let match = found.first {
                    model.loadSubtitles(url: match.url, accessing: match.folder)
                }
            } catch { /* Replacement, closing, or a newer search cancels this work. */ }
        }
    }
}

struct SubtitleSearchSettingsView: View {
    @ObservedObject var preferences: PlayerPreferences
    @ObservedObject private var folders = SubtitleFolderStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Automatically find matching subtitles", isOn: $preferences.autoFindSubtitles)
            Text("Search only the folders you add. Matching language-tagged files follow your subtitle language preference. Subfolders are not searched.")
                .font(.callout).foregroundStyle(.secondary)
            List(folders.entries) { entry in
                HStack {
                    Label(entry.name, systemImage: "folder")
                    Spacer()
                    Button { folders.remove(entry) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.name)")
                }
            }
            Button("Add Folder…") { folders.chooseFolder() }
            Text("Access is read-only. Saved folders stay on this device.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct SubtitleMatchesView: View {
    @ObservedObject var search: SubtitleSearchController
    let select: (SubtitleMatch) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Matching Subtitles").font(.title2)
            if search.isSearching { ProgressView("Finding subtitles…") }
            if !search.message.isEmpty { Text(search.message).foregroundStyle(.secondary) }
            List(search.matches) { match in
                Button(match.name) { select(match); dismiss() }.buttonStyle(.plain)
            }
            HStack {
                Button("Add Folder…") { SubtitleFolderStore.shared.chooseFolder() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 480, height: 360)
    }
}
