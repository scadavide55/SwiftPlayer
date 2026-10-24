import Foundation

/// A playable entry referenced by a URL (a remote stream or a local network
/// address). Media stored on the device itself is handled separately by
/// `LocalLibrary` / `LocalFile`.
struct MediaItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var urlString: String

    var url: URL? { URL(string: urlString) }
}

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []

    private let storageKey = "SwiftPlayerTV.library"

    init() {
        load()
    }

    func add(name: String, urlString: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme != nil else { return }

        let fallbackName = url.lastPathComponent.isEmpty ? trimmedURL : url.lastPathComponent
        items.append(MediaItem(name: trimmedName.isEmpty ? fallbackName : trimmedName, urlString: trimmedURL))
        save()
    }

    func remove(_ item: MediaItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        items = (try? JSONDecoder().decode([MediaItem].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
