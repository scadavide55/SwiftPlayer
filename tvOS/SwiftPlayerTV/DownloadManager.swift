import Foundation
import Combine

/// Downloads remote media into the app's Documents directory so it can be
/// played back locally through `LocalLibrary`.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case downloading
            case finished
            case failed(String)
        }

        let id: UUID
        var name: String
        var progress: Double
        var state: State
    }

    @Published private(set) var items: [Item] = []

    private let directory: URL
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var itemForTask: [Int: UUID] = [:]

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func start(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            addFailure(name: trimmed.isEmpty ? "Invalid URL" : trimmed, reason: "Enter a valid http(s) URL.")
            return
        }

        var name = url.lastPathComponent
        if name.isEmpty { name = url.host ?? "download" }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, supportedExtensions.contains(ext) else {
            addFailure(name: name, reason: "Unsupported file type.")
            return
        }

        let item = Item(id: UUID(), name: name, progress: 0, state: .downloading)
        items.insert(item, at: 0)

        let task = session.downloadTask(with: url)
        tasks[item.id] = task
        itemForTask[task.taskIdentifier] = item.id
        task.resume()
    }

    func cancel(_ item: Item) {
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        items.removeAll { $0.id == item.id }
    }

    func remove(_ item: Item) {
        cancel(item)
    }

    func clearFinished() {
        items.removeAll { $0.state != .downloading }
    }

    // MARK: - Main-actor helpers

    private func addFailure(name: String, reason: String) {
        items.insert(Item(id: UUID(), name: name, progress: 0, state: .failed(reason)), at: 0)
    }

    fileprivate func updateProgress(taskIdentifier: Int, progress: Double) {
        guard let id = itemForTask[taskIdentifier],
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = progress
    }

    fileprivate func complete(taskIdentifier: Int, staging: URL, suggestedName: String) {
        guard let id = itemForTask[taskIdentifier] else {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        itemForTask[taskIdentifier] = nil
        tasks[id] = nil

        guard let index = items.firstIndex(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: staging)
            return
        }

        let name = Self.sanitized(suggestedName, fallback: items[index].name)
        let destination = Self.uniqueURL(for: name, in: directory)
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
            items[index].name = destination.lastPathComponent
            items[index].progress = 1
            items[index].state = .finished
        } catch {
            try? FileManager.default.removeItem(at: staging)
            items[index].state = .failed(error.localizedDescription)
        }
    }

    fileprivate func complete(taskIdentifier: Int, error: Error) {
        guard let id = itemForTask[taskIdentifier],
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        itemForTask[taskIdentifier] = nil
        tasks[id] = nil

        if (error as NSError).code == NSURLErrorCancelled {
            items.remove(at: index)
        } else {
            items[index].state = .failed(error.localizedDescription)
        }
    }

    private static func sanitized(_ name: String, fallback: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = cleaned.isEmpty ? fallback : cleaned
        let ext = (result as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext) ? result : fallback
    }

    private static func uniqueURL(for filename: String, in directory: URL) -> URL {
        let manager = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var index = 1

        while manager.fileExists(atPath: candidate.path) {
            let name = "\(base) (\(index))"
            candidate = ext.isEmpty
                ? directory.appendingPathComponent(name)
                : directory.appendingPathComponent(name).appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let identifier = downloadTask.taskIdentifier
        Task { @MainActor in
            self.updateProgress(taskIdentifier: identifier, progress: progress)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted as soon as this returns, so stage a copy first.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftplayer-\(UUID().uuidString).download")
        try? FileManager.default.copyItem(at: location, to: staging)

        let identifier = downloadTask.taskIdentifier
        let suggested = downloadTask.response?.suggestedFilename ?? downloadTask.originalRequest?.url?.lastPathComponent ?? "download"
        Task { @MainActor in
            self.complete(taskIdentifier: identifier, staging: staging, suggestedName: suggested)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let identifier = task.taskIdentifier
        Task { @MainActor in
            self.complete(taskIdentifier: identifier, error: error)
        }
    }
}
