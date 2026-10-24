import Foundation
import Darwin

/// A single playable media file that lives inside the app's Documents
/// directory. tvOS has no file picker, so these files arrive through the
/// built-in upload page or via `DownloadManager`.
struct LocalFile: Identifiable, Hashable {
    let url: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }

    /// Wraps the file so it can be handed to the shared player pipeline.
    var mediaItem: MediaItem {
        MediaItem(
            name: url.deletingPathExtension().lastPathComponent,
            urlString: url.absoluteString
        )
    }

    var size: Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var modificationDate: Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

/// Watches the app's Documents directory and publishes the supported media
/// files it contains. A filesystem source keeps the list in sync with uploads
/// made through `LocalFileServer` and downloads without any cross-object wiring.
@MainActor
final class LocalLibrary: ObservableObject {
    enum SortOrder: String, CaseIterable, Identifiable {
        case name
        case date
        case size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "Name"
            case .date: return "Date Added"
            case .size: return "Size"
            }
        }

        var systemImage: String {
            switch self {
            case .name: return "textformat"
            case .date: return "calendar"
            case .size: return "arrow.up.arrow.down"
            }
        }
    }

    @Published private(set) var files: [LocalFile] = []
    @Published var sortOrder: SortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: sortKey)
            refresh()
        }
    }

    let directory: URL

    private let sortKey = "SwiftPlayerTV.localSortOrder"
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        sortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .name
        refresh()
        startMonitoring()
    }

    deinit {
        directoryMonitor?.cancel()
    }

    var totalSize: Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }

    var totalSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let base = contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map(LocalFile.init(url:))

        switch sortOrder {
        case .name:
            files = base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            files = base.sorted { $0.modificationDate > $1.modificationDate }
        case .size:
            files = base.sorted { $0.size > $1.size }
        }
    }

    func delete(_ file: LocalFile) {
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }

    func deleteAll() {
        for file in files {
            try? FileManager.default.removeItem(at: file.url)
        }
        refresh()
    }

    private func startMonitoring() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directoryMonitor = source
        source.resume()
    }

    /// Coalesces the burst of events that a single upload produces.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
