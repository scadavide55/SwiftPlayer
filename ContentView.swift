import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @State private var hasLoadedFile: Bool = false
    
    @State private var controlsVisible: Bool = true
    @State private var hideTimer: Timer?
    
    @State private var pendingReplacementURL: URL?
    @State private var showReplaceConfirm: Bool = false
    
    @State private var isTargeted: Bool = false
    @State private var showHomeConfirm: Bool = false
    @State private var fastSeekTimer: Timer?
    @State private var fastSeekDirection: Int = 0 // -1 backward, +1 forward
    @State private var showSubtitlePanel: Bool = false
    var body: some View {
        Group {
            if hasLoadedFile {
                playingState
            } else {
                EmptyStateView { url in
                    load(url: url)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .alert("Replace current video?", isPresented: $showReplaceConfirm, presenting: pendingReplacementURL) { url in
            Button("Replace", role: .destructive) {
                load(url: url)
            }
            Button("Cancel", role: .cancel) {
                pendingReplacementURL = nil
            }
        } message: { url in
            Text("This will stop the current playback and load “\(url.lastPathComponent)”.")
        }
        .onDisappear {
            model.teardown()
        }
    }
    
    private var playingState: some View {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottom) {
                    PlayerLayerView(player: model.player)
                        .ignoresSafeArea()
                    if !model.currentSubtitleText.isEmpty {
                                        Text(model.currentSubtitleText)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.black.opacity(0.6))
                                            .cornerRadius(6)
                                            .padding(.bottom, controlsVisible ? 70:24)
                                            .transition(.opacity)
                                    }

                    if controlsVisible {
                        ControlsOverlay(model: model)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
                .overlay(
                    Rectangle()
                        .stroke(isTargeted ? Color.blue : Color.clear, lineWidth: 3)
                )
                .background(MouseActivityTracker(onActivity: registerActivity))
                .background(KeyEventHandlingView(
                    onSpace: { model.togglePlayPause() },
                    onArrowDown: { direction in handleArrowDown(direction: direction) },
                    onArrowUp: { handleArrowUp() }
                ))
                .onAppear {
                    registerActivity()
                }
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)

                if controlsVisible {
                    Button {
                        showHomeConfirm = true
                    } label: {
                        Image(systemName: "house")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .popover(isPresented: $showHomeConfirm, arrowEdge: .bottom) {
                        VStack(spacing: 12) {
                            Text("Go back to file select screen?")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .frame(width: 220)

                            VStack(spacing: 8) {
                                Button("Yes") {
                                    showHomeConfirm = false
                                    goHome()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .frame(maxWidth: .infinity)

                                Button("No") {
                                    showHomeConfirm = false
                                }
                                .buttonStyle(.bordered)
                                .tint(.gray)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .alert("Couldn't play this file", isPresented: $model.playbackFailed) {
                            Button("OK") {
                                goHome()
                            }
                        } message: {
                            Text("This file's format isn't supported.")
                        }
                        .overlay(alignment: .topTrailing) {
                if controlsVisible {
                    Button {
                        showSubtitlePanel = true
                    } label: {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .popover(isPresented: $showSubtitlePanel, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 14) {
                            Button("Load Subtitles…") {
                                openSubtitlePicker()
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Subtitle Delay")
                                    .font(.subheadline).bold()
                                Text(String(format: "%+.1fs", model.subtitleOffset))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Slider(value: $model.subtitleOffset, in: -5...5, step: 0.5)
                            }
                        }
                        .padding(16)
                        .frame(width: 260)
                    }
                }
            }
        }
    private func goHome() {
            model.teardown()
            hasLoadedFile = false
            model.playbackFailed = false
        }

        private func handleArrowDown(direction: Int) {
            if fastSeekDirection != direction {
                fastSeekDirection = direction
                fastSeekTimer?.invalidate()
                fastSeekTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                    DispatchQueue.main.async {
                        if direction > 0 {
                            model.player.rate = 2.0
                        } else {
                            // Simulated reverse: repeated backward jumps.
                            startReverseScrub()
                        }
                    }
                }
            }
            registerActivity()
            model.seek(to: model.currentTime + Double(direction) * 5)
        }

        private func handleArrowUp() {
            fastSeekTimer?.invalidate()
            fastSeekTimer = nil
            fastSeekDirection = 0
            stopReverseScrub()
            if model.player.rate != 1.0 && model.isPlaying {
                model.player.rate = 1.0
            }
        }
private func openSubtitlePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = supportedSubtitleExtensions.compactMap { UTType(filenameExtension: $0) }

        if panel.runModal() == .OK, let url = panel.url {
            model.loadSubtitles(url: url)
        }
    }

        private func startReverseScrub() {
            fastSeekTimer?.invalidate()
            fastSeekTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                DispatchQueue.main.async {
                    model.seek(to: max(model.currentTime - 1.0, 0))
                }
            }
        }

        private func stopReverseScrub() {
            fastSeekTimer?.invalidate()
            fastSeekTimer = nil
        }
    
    private func load(url: URL) {
        model.load(url: url)
        hasLoadedFile = true
        pendingReplacementURL = nil
        registerActivity()
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { return }
            
            DispatchQueue.main.async {
                if hasLoadedFile {
                    pendingReplacementURL = url
                    showReplaceConfirm = true
                } else {
                    load(url: url)
                }
            }
        }
        return true
    }
    
    // MARK: - Idle / auto-hide logic
    
    private func registerActivity() {
        if !controlsVisible {
            controlsVisible = true
        }
        NSCursor.unhide()
        
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            DispatchQueue.main.async {
                controlsVisible = false
                NSCursor.hide()
            }
        }
    }
}

/// Bridges raw NSView mouse-moved tracking into SwiftUI, since SwiftUI alone
/// doesn't give a clean "mouse moved anywhere in this view" signal without
/// a tracking area.
struct MouseActivityTracker: NSViewRepresentable {
    let onActivity: () -> Void
    
    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onActivity = onActivity
        return view
    }
    
    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onActivity = onActivity
    }
    
    final class TrackingNSView: NSView {
        var onActivity: (() -> Void)?
        private var trackingArea: NSTrackingArea?
        
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }
        
        override func mouseMoved(with event: NSEvent) {
            onActivity?()
        }
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Never intercept clicks/drags — this view only exists for tracking.
            nil
        }
    }
}
struct KeyEventHandlingView: NSViewRepresentable {
    let onSpace: () -> Void
    let onArrowDown: (Int) -> Void // -1 left, +1 right
    let onArrowUp: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onSpace = onSpace
        view.onArrowDown = onArrowDown
        view.onArrowUp = onArrowUp
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onArrowDown = onArrowDown
        nsView.onArrowUp = onArrowUp
    }

    final class KeyCatcherView: NSView {
        var onSpace: (() -> Void)?
        var onArrowDown: ((Int) -> Void)?
        var onArrowUp: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 49: // space
                onSpace?()
            case 123: // left arrow
                onArrowDown?(-1)
            case 124: // right arrow
                onArrowDown?(1)
            default:
                super.keyDown(with: event)
            }
        }

        override func keyUp(with event: NSEvent) {
            switch event.keyCode {
            case 123, 124:
                onArrowUp?()
            default:
                super.keyUp(with: event)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil // never intercept clicks/drags
        }
    }
}

