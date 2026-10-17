import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var menuState = PlayerMenuState(model: PlayerModel(preferences: PlayerPreferences.shared,
        history: .shared, restoreApplicationVolume: false))

    var body: some View {
        if let model = menuState.model {
            PlayerContentView(model: model, menuState: menuState)
        }
    }
}

private struct PlayerContentView: View {
    @ObservedObject var model: PlayerModel
    let menuState: PlayerMenuState
    @ObservedObject private var preferences = PlayerPreferences.shared
    @ObservedObject private var systemVolume = SystemVolumeController.shared
    @StateObject private var pipController = PiPController()
    @StateObject private var subtitleSearch = SubtitleSearchController()
    @StateObject private var displaySleep = DisplaySleepController()
    @StateObject private var windowControls = PlayerWindowControls()
    @StateObject private var frameCapture = FrameCaptureController()
    @ObservedObject private var subtitleFolders = SubtitleFolderStore.shared
    @State private var showSubtitleMatches = false
    @State private var hasLoadedFile: Bool = false
    
    @State private var controlsVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isPointerInside = false
    
    @State private var pendingReplacementURL: URL?
    @State private var pendingReplacementPosition: Double?
    @State private var showReplaceConfirm: Bool = false
    
    @State private var isTargeted: Bool = false
    @State private var showHomeConfirm: Bool = false
    @State private var showSubtitlePanel: Bool = false
    @State private var subtitleImport: SubtitleImportRequest?
    @State private var showAppearance = false
    @State private var showJump = false
    @State private var showInformation = false
    @State private var showHistory = false
    @State private var pendingHistoryOpen: (URL, Double)?
    @State private var activeSourceURL: URL?
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
        .background(PlayerCommandFocus(context: PlayerWindowContext(menus: menuState, viewing: windowControls, capture: frameCapture,
            open: { requestOpen($0) }, history: { pendingHistoryOpen = nil; showHistory = true },
            jump: { showJump = true }, information: { showInformation = true },
            subtitles: openSubtitlePicker, findSubtitles: {
                showSubtitleMatches = true
                startSubtitleSearch(automatic: false)
            }, appearance: { showAppearance = true })).equatable())
        .sheet(isPresented: $showAppearance) {
            VStack {
                SubtitleAppearanceView(preferences: preferences)
                Button("Done") { showAppearance = false }.keyboardShortcut(.defaultAction).padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showSubtitleMatches) {
            SubtitleMatchesView(search: subtitleSearch) { model.loadSubtitles(url: $0.url, accessing: $0.folder) }
        }
        .sheet(item: $subtitleImport) { request in
            SubtitleImportView(url: request.url, encoding: .automatic, companion: request.companion,
                               preferredLanguages: preferences.subtitleLanguage.isEmpty ? Locale.preferredLanguages : [preferences.subtitleLanguage]) { encoding, track in
                model.loadSubtitles(url: request.url, encoding: encoding, companion: request.companion, track: track)
            }
        }
        .sheet(isPresented: $showJump) { JumpToTimeView(duration: model.duration) { model.seek(to: $0) } }
        .sheet(isPresented: $showInformation) { MediaInformationView(model: model, media: model.mediaControls) }
        .sheet(isPresented: $showHistory, onDismiss: {
            guard let request = pendingHistoryOpen else { return }
            pendingHistoryOpen = nil
            requestOpen(request.0, startAt: request.1)
        }) {
            PlaybackHistoryView(history: .shared) { pendingHistoryOpen = ($0, $1) }
        }
        .onChange(of: model.isLoading) { loading in
            if !loading, !model.playbackFailed, model.player.currentItem?.status == .readyToPlay, let url = activeSourceURL {
                RecentMediaStore.shared.record(url)
            }
        }
        .onChange(of: model.sourceURL) { _ in frameCapture.cancel(); startSubtitleSearch(automatic: true) }
        .onChange(of: subtitleFolders.entries.map(\.id)) { _ in startSubtitleSearch(automatic: !showSubtitleMatches) }
        .onChange(of: preferences.autoFindSubtitles) { _ in startSubtitleSearch(automatic: true) }
        .onChange(of: preferences.subtitleLanguage) { _ in startSubtitleSearch(automatic: true) }
        .onChange(of: model.closedAtEnd) { closed in if closed { goHome() } }
        .onAppear {
            displaySleep.attach(model: model, preferences: preferences)
            windowControls.observe(model.player)
            frameCapture.attach(model: model, preferences: preferences, viewing: windowControls)
        }
        .onChange(of: pipController.isActive) { active in model.mediaControls.nativeSubtitleRendering = active }
        .frame(minWidth: 480, minHeight: 320)
        .overlay(alignment: .bottomTrailing) {
            if frameCapture.isCapturing {
                ProgressView("Capturing frame…").controlSize(.small).padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .alert("Couldn't capture the frame", isPresented: Binding(get: { frameCapture.errorMessage != nil },
            set: { if !$0 { frameCapture.errorMessage = nil } })) {
            Button("OK") { frameCapture.errorMessage = nil }
        } message: { Text(frameCapture.errorMessage ?? "") }
        .background(PlayerWindowObserver(onResignKey: { stopInteractions() },
                                         onWindowChanged: { windowControls.attach($0) }))
        .alert("Replace current video?", isPresented: $showReplaceConfirm, presenting: pendingReplacementURL) { url in
            Button("Replace", role: .destructive) {
                load(url: url, startAt: pendingReplacementPosition)
            }
            Button("Cancel", role: .cancel) {
                pendingReplacementURL = nil
                pendingReplacementPosition = nil
            }
        } message: { url in
            Text("This will stop the current playback and load “\(url.lastPathComponent)”.")
        }
        .onDisappear {
            pendingHistoryOpen = nil
            displaySleep.detach()
            windowControls.detach()
            frameCapture.detach()
            subtitleSearch.cancel()
            stopInteractions()
            pipController.detach()
            model.teardown()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopInteractions()
            model.mediaControls.savePosition()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.teardown()
        }
        .onChange(of: isInteracting) { _ in
            registerActivity()
        }
    }
    
    private var playingState: some View {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottom) {
                    PlayerLayerView(player: model.player, display: windowControls.display,
                                    onDoubleClick: { registerActivity(); toggleFullScreen() }) { layer in
                        pipController.attach(to: layer)
                    }
                    .ignoresSafeArea()
                    if model.isLoading {
                        ProgressView("Opening video…")
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    CaptionOverlay(model: model, media: model.mediaControls, preferences: preferences,
                                   controlsVisible: controlsVisible, nativeRendering: pipController.isActive,
                                   display: windowControls.display, videoSize: windowControls.videoSize)

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
                    onSpace: { registerActivity(); model.togglePlayPause() },
                    onArrowDown: { direction, mode in handleArrowDown(direction: direction, mode: mode) },
                    onArrowUp: { handleArrowUp() },
                    onVolumeUp: { registerActivity(); systemVolume.increase() },
                    onVolumeDown: { registerActivity(); systemVolume.decrease() },
                    onFrameStep: { direction in model.stepFrame(direction: direction); registerActivity() },
                    onSpeedChange: { direction in model.adjustPlaybackSpeed(direction: direction); registerActivity() }
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
            
            .overlay(alignment: .top) {
                PlaybackFeedbackOverlay(model: model, media: model.mediaControls, systemVolume: systemVolume)
                    .id(model.sourceURL)
            }
            .alert("Couldn't play this file", isPresented: $model.playbackFailed) {
                            Button("OK") {
                                goHome()
                            }
                        } message: {
                            Text(model.playbackErrorMessage)
                        }
                        .overlay(alignment: .topTrailing) {
                            if controlsVisible {
                                HStack(spacing: 8) {
                                    Button {
                                        toggleFullScreen()
                                    } label: {
                                        Image(systemName: windowControls.isFullScreen
                                              ? "arrow.down.right.and.arrow.up.left"
                                              : "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 32, height: 32)
                                            .background(Circle().fill(Color.black.opacity(0.4)))
                                    }
                                    .buttonStyle(.plain)
                                    .help(windowControls.isFullScreen ? "Exit Full Screen" : "Enter Full Screen")

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
                                    .popover(isPresented: $showSubtitlePanel, arrowEdge: .bottom) {
                                        SubtitlePanel(model: model, media: model.mediaControls, preferences: preferences,
                                                      openFile: openSubtitlePicker, appearance: {
                                                          showSubtitlePanel = false
                                                          showAppearance = true
                                                      })
                                    }
                                }
                                .padding(16)
                            }
                        }
        }
    private var isInteracting: Bool {
        model.isScrubbing || model.isLoading || model.playbackFailed || model.playbackFinished
            || showSubtitlePanel || showHomeConfirm || showReplaceConfirm || showAppearance || showJump || showInformation
            || subtitleImport != nil
            || showHistory
    }

    private func goHome() {
        pendingHistoryOpen = nil
        stopInteractions()
        pipController.detach()
        model.teardown()
        hasLoadedFile = false
        activeSourceURL = nil
        showSubtitlePanel = false
        subtitleImport = nil
        pendingReplacementURL = nil
        pendingReplacementPosition = nil
    }

    private func toggleFullScreen() {
        windowControls.toggleFullScreen()
    }

    private func handleArrowDown(direction: Int, mode: ArrowSeekMode) {
        registerActivity()
        model.beginFastSeeking(direction: direction, mode: mode)
    }

    private func handleArrowUp() {
        model.endFastSeeking()
    }

    private func startSubtitleSearch(automatic: Bool) {
        subtitleSearch.cancel()
        guard model.sourceURL != nil else { showSubtitleMatches = false; return }
        guard !automatic || preferences.autoFindSubtitles else { return }
        let languages = preferences.subtitleLanguage.isEmpty ? Locale.preferredLanguages : [preferences.subtitleLanguage]
        subtitleSearch.start(model: model, folders: subtitleFolders.entries, languages: languages, automatic: automatic)
    }

    private func openSubtitlePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = supportedSubtitleExtensions.compactMap { UTType(filenameExtension: $0) }

        if panel.runModal() == .OK, let url = panel.url {
            showSubtitlePanel = false
            var companion: URL?
            if ["idx", "sub"].contains(url.pathExtension.lowercased()) {
                let pair = NSOpenPanel()
                let ext = url.pathExtension.lowercased() == "idx" ? "sub" : "idx"
                pair.title = "Choose the Companion .\(ext) File"
                pair.message = "VobSub subtitles require both the .idx index and .sub image file."
                pair.directoryURL = url.deletingLastPathComponent()
                pair.allowedContentTypes = [UTType(filenameExtension: ext)].compactMap { $0 }
                pair.allowsMultipleSelection = false
                pair.canChooseDirectories = false
                guard pair.runModal() == .OK, let chosen = pair.url else { return }
                companion = chosen
            }
            subtitleImport = SubtitleImportRequest(url: url, companion: companion)
        }
    }

    private func requestOpen(_ url: URL, startAt: Double? = nil) {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
        if hasLoadedFile {
            pendingReplacementURL = url
            pendingReplacementPosition = startAt
            showReplaceConfirm = true
        } else { load(url: url, startAt: startAt) }
    }

    private func load(url: URL, startAt: Double? = nil) {
        subtitleImport = nil
        stopInteractions()
        pipController.stop()
        activeSourceURL = url
        model.load(url: url, startAt: startAt)
        hasLoadedFile = true
        pendingReplacementURL = nil
        pendingReplacementPosition = nil
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
                    pendingReplacementPosition = nil
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
    let onArrowDown: (Int, ArrowSeekMode) -> Void
    let onArrowUp: () -> Void
    let onVolumeUp: () -> Void
    let onVolumeDown: () -> Void
    let onFrameStep: (Int) -> Void
    var onSpeedChange: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onSpace = onSpace
        view.onArrowDown = onArrowDown
        view.onArrowUp = onArrowUp
        view.onVolumeUp = onVolumeUp
        view.onVolumeDown = onVolumeDown
        view.onFrameStep = onFrameStep
        view.onSpeedChange = onSpeedChange
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onSpace = onSpace
        nsView.onArrowDown = onArrowDown
        nsView.onArrowUp = onArrowUp
        nsView.onVolumeUp = onVolumeUp
        nsView.onVolumeDown = onVolumeDown
        nsView.onFrameStep = onFrameStep
        nsView.onSpeedChange = onSpeedChange
    }

    static func dismantleNSView(_ nsView: KeyCatcherView, coordinator: ()) {
        nsView.invalidateKeyMonitor()
        nsView.onArrowUp?()
        nsView.onSpace = nil
        nsView.onArrowDown = nil
        nsView.onArrowUp = nil
        nsView.onVolumeUp = nil
        nsView.onVolumeDown = nil
        nsView.onFrameStep = nil
        nsView.onSpeedChange = nil
    }

    final class KeyCatcherView: NSView {
        var onSpace: (() -> Void)?
        var onArrowDown: ((Int, ArrowSeekMode) -> Void)?
        var onArrowUp: (() -> Void)?
        var onVolumeUp: (() -> Void)?
        var onVolumeDown: (() -> Void)?
        var onFrameStep: ((Int) -> Void)?
        var onSpeedChange: ((Int) -> Void)?
        private var keyMonitor: Any?
        private var hasActiveArrow = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if hasActiveArrow { onArrowUp?() }
            invalidateKeyMonitor()
            if window != nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                    guard let self, let window = self.window, event.window === window,
                          window.attachedSheet == nil else { return event }
                    if let editor = window.firstResponder as? NSTextView, editor.isEditable,
                       !(event.type == .keyUp && self.hasActiveArrow) { return event }
                    return self.handlePlaybackKey(event) ? nil : event
                }
            }
            window?.makeFirstResponder(self)
        }

        func invalidateKeyMonitor() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            hasActiveArrow = false
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { hasActiveArrow = false; onArrowUp?() }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            if !handlePlaybackKey(event) { super.keyDown(with: event) }
        }

        private func handlePlaybackKey(_ event: NSEvent) -> Bool {
            if event.type == .keyUp {
                guard event.keyCode == 123 || event.keyCode == 124 else { return false }
                hasActiveArrow = false
                onArrowUp?()
                return true
            }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .control, event.keyCode == 123 || event.keyCode == 124 {
                onFrameStep?(event.keyCode == 123 ? -1 : 1)
                return true
            }
            if modifiers == .control, event.keyCode == 126 || event.keyCode == 125 {
                onSpeedChange?(event.keyCode == 126 ? 1 : -1)
                return true
            }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            switch event.keyCode {
            case 49: // space
                if !event.isARepeat { onSpace?() }
            case 123, 124: // left/right arrows; the player owns hold timing.
                guard !event.isARepeat else { return true }
                hasActiveArrow = true
                let mode: ArrowSeekMode = modifiers.contains(.shift) ? .shuttle : .jump
                onArrowDown?(event.keyCode == 123 ? -1 : 1, mode)
            case 126: // up arrow
                onVolumeUp?()
            case 125: // down arrow
                onVolumeDown?()
            default:
                return false
            }
            return true
        }

        override func keyUp(with event: NSEvent) {
            if !handlePlaybackKey(event) { super.keyUp(with: event) }
        }

        deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
