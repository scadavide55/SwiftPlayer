import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @StateObject private var pipController = PiPController()
    @State private var hasLoadedFile: Bool = false
    
    @State private var controlsVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isPointerInside = false
    
    @State private var pendingReplacementURL: URL?
    @State private var showReplaceConfirm: Bool = false
    
    @State private var isTargeted: Bool = false
    @State private var showHomeConfirm: Bool = false
    @State private var showSubtitlePanel: Bool = false
    @State private var isFullScreen: Bool = false
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
            stopInteractions()
            pipController.detach()
            model.teardown()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopInteractions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopInteractions()
        }
        .onChange(of: isInteracting) { _ in
            registerActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }
    
    private var playingState: some View {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottom) {
                    PlayerLayerView(player: model.player) { layer in
                        pipController.attach(to: layer)
                    }
                    .ignoresSafeArea()
                    if model.isLoading {
                        ProgressView("Opening video…")
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
                    onArrowUp: { handleArrowUp() },
                    onVolumeUp: { model.volumeUp() },
                    onVolumeDown: { model.volumeDown() }
                ))
                .onAppear {
                    registerActivity()
                }
                .onHover { hovering in
                    isPointerInside = hovering
                    if hovering {
                        registerActivity()
                    } else {
                        hideTask?.cancel()
                        hideTask = nil
                        NSCursor.setHiddenUntilMouseMoves(false)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)

                if controlsVisible {
                    HStack(spacing: 10) {
                        Button {
                            showHomeConfirm = true
                        } label: {
                            Image(systemName: "house")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Color.black.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
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
                        
                        Text(model.currentFileName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(16)
                      }
                }
            
            .alert("Couldn't play this file", isPresented: $model.playbackFailed) {
                            Button("OK") {
                                goHome()
                            }
                        } message: {
                            Text(model.playbackErrorMessage)
                        }
                        .alert("Finished playing", isPresented: $model.playbackFinished) {
                            Button("Go Home") {
                                goHome()
                            }
                            Button("Stay", role: .cancel) {
                                model.seek(to: 0)
                            }
                        } message: {
                            Text("Do you want to go back to the file select screen?")
                        }
                        .overlay(alignment: .topTrailing) {
                            if controlsVisible {
                                HStack(spacing: 8) {
                                    Button {
                                        toggleFullScreen()
                                    } label: {
                                        Image(systemName: isFullScreen
                                              ? "arrow.down.right.and.arrow.up.left"
                                              : "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 32, height: 32)
                                            .background(Circle().fill(Color.black.opacity(0.4)))
                                    }
                                    HStack(spacing: 8) {
                                        Button {
                                            pipController.toggle()
                                        } label: {
                                            Image(systemName: pipController.isActive ? "pip.exit" : "pip.enter")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(pipController.isPossible ? .white : .white.opacity(0.35))
                                                .frame(width: 32, height: 32)
                                                .background(Circle().fill(Color.black.opacity(0.4)))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!pipController.isPossible)
                                        .help(pipController.isActive ? "Exit Picture in Picture" : "Enter Picture in Picture")

                                    }
                                    .buttonStyle(.plain)
                                    .help(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")

                                    Button {
                                        showSubtitlePanel = true
                                    } label: {
                                        Image(systemName: "captions.bubble")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 32, height: 32)
                                            .background(Circle().fill(Color.black.opacity(0.4)))
                                    }
                                    .buttonStyle(.plain)
                                    .buttonStyle(.plain)
                                    .popover(isPresented: $showSubtitlePanel, arrowEdge: .bottom) {
                                        VStack(alignment: .leading, spacing: 14) {
                                            Button("Load Subtitles…") {
                                                openSubtitlePicker()
                                            }

                                            Divider()

                                            Toggle("Show Subtitles", isOn: $model.subtitlesEnabled)
                                                .disabled(model.subtitleCues.isEmpty)

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
                                .padding(16)
                            }
                        }
        }
    private var isInteracting: Bool {
        model.isScrubbing || model.isLoading || model.playbackFailed || model.playbackFinished
            || showSubtitlePanel || showHomeConfirm || showReplaceConfirm
    }

    private func goHome() {
        stopInteractions()
        pipController.detach()
        model.teardown()
        hasLoadedFile = false
        showSubtitlePanel = false
        pendingReplacementURL = nil
    }

    private func toggleFullScreen() {
        NSApplication.shared.keyWindow?.toggleFullScreen(nil)
    }

    private func handleArrowDown(direction: Int) {
        registerActivity()
        model.beginFastSeeking(direction: direction)
    }

    private func handleArrowUp() {
        model.endFastSeeking()
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

    private func load(url: URL) {
        stopInteractions()
        pipController.stop()
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
        controlsVisible = true
        NSCursor.setHiddenUntilMouseMoves(false)
        hideTask?.cancel()
        hideTask = nil
        guard hasLoadedFile, !isInteracting else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard !Task.isCancelled, hasLoadedFile, !isInteracting, NSApplication.shared.isActive else { return }
            controlsVisible = false
            if isPointerInside { NSCursor.setHiddenUntilMouseMoves(true) }
            hideTask = nil
        }
    }

    private func stopInteractions() {
        hideTask?.cancel()
        hideTask = nil
        model.endFastSeeking()
        controlsVisible = true
        NSCursor.setHiddenUntilMouseMoves(false)
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

    static func dismantleNSView(_ nsView: TrackingNSView, coordinator: ()) {
        nsView.onActivity = nil
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
    let onVolumeUp: () -> Void
    let onVolumeDown: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onSpace = onSpace
        view.onArrowDown = onArrowDown
        view.onArrowUp = onArrowUp
        view.onVolumeUp = onVolumeUp
        view.onVolumeDown = onVolumeDown
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onArrowDown = onArrowDown
        nsView.onArrowUp = onArrowUp
        nsView.onVolumeUp = onVolumeUp
        nsView.onVolumeDown = onVolumeDown
    }

    static func dismantleNSView(_ nsView: KeyCatcherView, coordinator: ()) {
        nsView.onArrowUp?()
        nsView.onSpace = nil
        nsView.onArrowDown = nil
        nsView.onArrowUp = nil
        nsView.onVolumeUp = nil
        nsView.onVolumeDown = nil
    }

    final class KeyCatcherView: NSView {
        var onSpace: (() -> Void)?
        var onArrowDown: ((Int) -> Void)?
        var onArrowUp: (() -> Void)?
        var onVolumeUp: (() -> Void)?
        var onVolumeDown: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onArrowUp?() }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            switch event.keyCode {
            case 49: // space
                if !event.isARepeat { onSpace?() }
            case 123: // left arrow
                onArrowDown?(-1)
            case 124: // right arrow
                onArrowDown?(1)
            case 126: // up arrow
                onVolumeUp?()
            case 125: // down arrow
                onVolumeDown?()
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
            nil
        }
    }
}
