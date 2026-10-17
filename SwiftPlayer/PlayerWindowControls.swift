import AppKit
import AVFoundation
import Combine

nonisolated enum VideoFit: String, CaseIterable, Identifiable {
    case fit, fill
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit" : "Fill" }
}

nonisolated struct VideoDisplayOptions: Equatable {
    var fit: VideoFit = .fit
}

@MainActor
final class PlayerWindowControls: ObservableObject {
    @Published var display = VideoDisplayOptions()
    @Published var alwaysOnTop = false { didSet { applyLevel() } }
    @Published private(set) var isFullScreen = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var isAttached = false
    @Published private(set) var videoSize = CGSize.zero
    private weak var window: NSWindow?
    private var originalLevel: NSWindow.Level = .normal
    private var windowObservers: [NSObjectProtocol] = []
    private var itemObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private weak var player: AVPlayer?
    private var generation = UUID()

    var hasVideo: Bool { videoSize.width.isFinite && videoSize.height.isFinite && videoSize.width > 0 && videoSize.height > 0 }
    var subtitleReferenceHeight: Double {
        guard hasVideo else { return 360 }
        let bounds = window?.contentView?.bounds.size ?? CGSize(width: 640, height: 360)
        return max(1, min(bounds.height, bounds.width * videoSize.height / videoSize.width))
    }

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        if let old = self.window { old.level = originalLevel }
        removeWindowObservers()
        self.window = window
        isAttached = window != nil
        isTransitioning = false
        isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        guard let window else { return }
        originalLevel = window.level
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? NSWindow === self.window else { return }
                    switch notification.name {
                    case NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification:
                        self.isTransitioning = true
                        self.window?.level = self.originalLevel
                    case NSWindow.didEnterFullScreenNotification: self.fullScreenChanged(true)
                    default: self.fullScreenChanged(false)
                    }
                }
            })
        }
        applyLevel()
    }

    func fullScreenChanged(_ fullScreen: Bool) {
        isFullScreen = fullScreen
        isTransitioning = false
        applyLevel()
    }

    private func applyLevel() {
        window?.level = alwaysOnTop && !isFullScreen && !isTransitioning ? .floating : originalLevel
    }

    func toggleFullScreen() {
        guard let window, window.styleMask.contains(.resizable), !isTransitioning else { return }
        isTransitioning = true
        window.level = originalLevel
        window.toggleFullScreen(nil)
    }

    func observe(_ player: AVPlayer) {
        generation = UUID()
        self.player = player
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeItem() }
        }
    }

    private func observeItem() {
        sizeObservation = nil
        videoSize = .zero
        guard let item = player?.currentItem else { return }
        let identifier = generation
        sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == identifier, self.player?.currentItem === item else { return }
                let size = item.presentationSize
                self.videoSize = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 ? size : .zero
            }
        }
    }

    private func removeWindowObservers() {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers.removeAll()
    }

    func detach() {
        attach(nil)
        itemObservation = nil
        sizeObservation = nil
        player = nil
        videoSize = .zero
        generation = UUID()
    }

    deinit {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
    }
}
