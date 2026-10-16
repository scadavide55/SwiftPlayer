import AppKit
import AVFoundation
import Combine

nonisolated enum VideoFit: String, CaseIterable, Identifiable {
    case fit, fill
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit" : "Fill" }
}

nonisolated enum VideoAspect: String, CaseIterable, Identifiable {
    case original, widescreen, classic, cinema, square
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .widescreen: return "16:9"
        case .classic: return "4:3"
        case .cinema: return "21:9"
        case .square: return "1:1"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .widescreen: return 16 / 9
        case .classic: return 4 / 3
        case .cinema: return 21 / 9
        case .square: return 1
        }
    }
}

nonisolated struct VideoDisplayOptions: Equatable {
    var fit: VideoFit = .fit
    var aspect: VideoAspect = .original

    func frame(in bounds: CGRect) -> CGRect {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return .zero }
        guard let ratio = aspect.ratio else { return bounds }
        let width: CGFloat
        let height: CGFloat
        if (bounds.width / bounds.height > ratio) == (fit == .fit) {
            height = bounds.height
            width = height * ratio
        } else {
            width = bounds.width
            height = width / ratio
        }
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
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
    var canResize: Bool { isAttached && hasVideo && !isFullScreen && !isTransitioning }
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

    /// 100% maps decoded pixels to display pixels, accounting for Retina scale.
    /// Screen fitting uses the visible area and includes the window's title bar.
    func resize(scale: CGFloat?) {
        guard canResize, let window, let screen = window.screen ?? NSScreen.main else { return }
        let raw = CGSize(width: display.aspect.ratio.map { videoSize.height * $0 } ?? videoSize.width,
                         height: videoSize.height)
        guard let content = Self.contentSize(video: raw, scale: scale, backingScale: window.backingScaleFactor,
            available: window.contentRect(forFrameRect: screen.visibleFrame).size, minimum: window.contentMinSize) else { return }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: content))
        frame.origin = CGPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    static func contentSize(video: CGSize, scale: CGFloat?, backingScale: CGFloat,
                            available: CGSize, minimum: CGSize) -> CGSize? {
        guard video.width.isFinite, video.height.isFinite, video.width > 0, video.height > 0,
              backingScale.isFinite, backingScale > 0,
              available.width.isFinite, available.height.isFinite, available.width > 0, available.height > 0,
              minimum.width.isFinite, minimum.height.isFinite, minimum.width >= 0, minimum.height >= 0,
              scale == nil || (scale!.isFinite && scale! > 0) else { return nil }
        let maximum = min(available.width / video.width, available.height / video.height)
        let factor = min(scale.map { $0 / backingScale } ?? maximum, maximum)
        return CGSize(width: min(available.width, max(minimum.width, video.width * factor)),
                      height: min(available.height, max(minimum.height, video.height * factor)))
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
