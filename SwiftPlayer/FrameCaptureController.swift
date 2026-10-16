import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class FrameCaptureCoordinator: ObservableObject {
    static let shared = FrameCaptureCoordinator()
    @Published private(set) var isBusy = false
    func begin() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }
    func finish() { isBusy = false }
}

@MainActor
final class FrameCaptureController: ObservableObject {
    @Published var includeSubtitles = false
    @Published private(set) var isCapturing = false
    @Published var errorMessage: String?
    @Published private(set) var statusMessage = ""
    private let coordinator = FrameCaptureCoordinator.shared
    private weak var model: PlayerModel?
    private weak var preferences: PlayerPreferences?
    private weak var viewing: PlayerWindowControls?
    private weak var pendingItem: AVPlayerItem?
    private var itemObservation: NSKeyValueObservation?
    private var generator: AVAssetImageGenerator?
    private var task: Task<Void, Never>?
    private var identifier = UUID()
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard? = nil) { self.pasteboard = pasteboard ?? .general }

    func attach(model: PlayerModel, preferences: PlayerPreferences, viewing: PlayerWindowControls) {
        detach()
        self.model = model
        self.preferences = preferences
        self.viewing = viewing
        itemObservation = model.player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCapturing else { return }
                if self.model?.player.currentItem == nil || self.model?.player.currentItem !== self.pendingItem { self.cancel() }
            }
        }
    }

    private struct Request {
        let item: AVPlayerItem
        let time: CMTime
        let caption: FrameCaption?
        let subtitles: SubtitleRenderRequest?
    }

    private func request() -> Request? {
        guard let model, let preferences, let viewing, viewing.hasVideo, !model.isScrubbing,
              let item = model.player.currentItem, item.status == .readyToPlay else { return nil }
        let clock = model.player.currentTime()
        guard clock.seconds.isFinite, clock.seconds >= 0 else { return nil }
        var caption: FrameCaption?
        let external = model.externalSubtitleSnapshot(at: clock.seconds)
        if includeSubtitles {
            let media = model.mediaControls
            let text: String
            switch media.subtitleSelection {
            case "off": text = ""
            case "external": text = external.text
            default: text = media.subtitleTextForCapture(at: clock.seconds)
            }
            let appearance = preferences.appearance.normalized
            let font = appearance.fontFamily == "System" ? NSFont.systemFont(ofSize: 24, weight: .semibold)
                : NSFont(name: appearance.fontFamily, size: 24) ?? NSFont.systemFont(ofSize: 24, weight: .semibold)
            caption = FrameCaption(text: text, fontName: font.fontName, size: appearance.size, color: appearance.color,
                outline: appearance.outline, backgroundOpacity: appearance.backgroundOpacity, position: appearance.position,
                referenceHeight: viewing.subtitleReferenceHeight)
        }
        let subtitles = includeSubtitles ? external.image : nil
        if subtitles != nil { caption = nil }
        return Request(item: item, time: clock, caption: caption, subtitles: subtitles)
    }

    func saveFrame() {
        guard !coordinator.isBusy, let request = request() else { return }
        let panel = NSSavePanel()
        panel.title = "Save Current Frame"
        panel.message = "Save the original video frame as PNG. Window scaling is not included."
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Frame.png"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { start(request, file: url) }
    }

    func copyFrame() {
        guard let request = request() else { return }
        start(request, file: nil)
    }

    /// Also used by native export tests without opening a system save panel.
    func capture(to url: URL) {
        guard let request = request() else { return }
        start(request, file: url)
    }

    private func start(_ request: Request, file: URL?) {
        guard model?.player.currentItem === request.item else { return }
        guard coordinator.begin() else {
            errorMessage = "Another frame capture is in progress. Try again shortly."
            return
        }
        cancel()
        isCapturing = true
        errorMessage = nil
        statusMessage = ""
        pendingItem = request.item
        let generation = identifier
        let generator = AVAssetImageGenerator(asset: request.item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 8192, height: 8192)
        // Capturing a particular frame is an explicit operation. Ordinary
        // playback seeks and interactive thumbnails retain relaxed tolerance.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.generator = generator
        let time = request.time
        let caption = request.caption
        let subtitles = request.subtitles
        task = Task { [weak self, weak item = request.item] in
            defer {
                FrameCaptureCoordinator.shared.finish()
                if let self, self.identifier == generation {
                    self.isCapturing = false
                    self.generator = nil
                    self.pendingItem = nil
                    self.task = nil
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await withTaskCancellationHandler {
                    try await generator.image(at: time)
                } onCancel: { generator.cancelAllCGImageGeneration() }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    try autoreleasepool {
                        let renderedSubtitles = try subtitles?.render()
                        let data = try FrameCaptureImage.png(result.image, caption: caption, subtitles: renderedSubtitles)
                        try Task.checkCancellation()
                        if let file {
                            let scoped = file.startAccessingSecurityScopedResource()
                            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                            try data.write(to: file, options: .atomic)
                        }
                        return file == nil ? data : Data()
                    }
                }
                let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, let item, self.identifier == generation, self.model?.player.currentItem === item else { return }
                if file == nil {
                    self.pasteboard.clearContents()
                    guard self.pasteboard.setData(data, forType: .png) else {
                        throw NSError(domain: "SwiftPlayer.FrameCapture", code: 2)
                    }
                }
                self.statusMessage = file == nil ? "Frame copied" : "Frame saved"
            } catch {
                guard let self, self.identifier == generation, !Task.isCancelled else { return }
                self.errorMessage = "The frame could not be captured. Try another position or check the save location."
            }
        }
    }

    func cancel() {
        identifier = UUID()
        task?.cancel()
        task = nil
        generator?.cancelAllCGImageGeneration()
        generator = nil
        pendingItem = nil
        isCapturing = false
        statusMessage = ""
        errorMessage = nil
    }

    func detach() {
        cancel()
        itemObservation = nil
        model = nil
        preferences = nil
        viewing = nil
    }

    deinit { task?.cancel(); generator?.cancelAllCGImageGeneration() }
}
