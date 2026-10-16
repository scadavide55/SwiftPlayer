import Foundation
import Combine

/// Each window owns an activity. macOS keeps the display awake until every
/// active window releases its activity, without a shared mutable owner registry.
private final class DisplaySleepActivity {
    private let token = ProcessInfo.processInfo.beginActivity(
        options: [.idleDisplaySleepDisabled], reason: "Playing video")
    deinit { ProcessInfo.processInfo.endActivity(token) }
}

@MainActor
final class DisplaySleepController: ObservableObject {
    private var activity: AnyObject?
    private let makeActivity: () -> AnyObject
    private var observations: [AnyCancellable] = []
    private var refreshTask: Task<Void, Never>?
    private weak var model: PlayerModel?
    private weak var preferences: PlayerPreferences?
    var isPreventingSleep: Bool { activity != nil }

    init(makeActivity: @escaping () -> AnyObject = { DisplaySleepActivity() }) {
        self.makeActivity = makeActivity
    }

    func attach(model: PlayerModel, preferences: PlayerPreferences) {
        detach()
        self.model = model
        self.preferences = preferences
        for publisher in [model.objectWillChange, model.mediaControls.objectWillChange, preferences.objectWillChange] {
            observations.append(publisher.sink { [weak self] in self?.scheduleRefresh() })
        }
        refresh()
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    private func refresh() {
        guard let model, let preferences else { activity = nil; return }
        update(playing: model.isPlaying && model.playbackRequested && !model.playbackFailed && !model.isLoading,
               hasVideo: model.mediaControls.streams.contains { $0.kind == "Video" },
               enabled: preferences.keepDisplayAwake)
    }

    func update(playing: Bool, hasVideo: Bool, enabled: Bool) {
        if playing && hasVideo && enabled {
            if activity == nil { activity = makeActivity() }
        } else { activity = nil }
    }

    func detach() {
        refreshTask?.cancel()
        refreshTask = nil
        observations.removeAll()
        model = nil
        preferences = nil
        activity = nil
    }

    deinit { refreshTask?.cancel() }
}
