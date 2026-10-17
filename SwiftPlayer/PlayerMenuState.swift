import AVFoundation
import Combine
import Foundation

/// Only changes that affect menu commands should invalidate a tracked menu.
/// Playback time and decoded caption text change continuously during playback.
@MainActor
final class PlayerMenuState: ObservableObject {
    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
    }
    struct Chapter: Identifiable, Equatable {
        let id: Int
        let title: String
        let start: Double
    }
    struct Snapshot: Equatable {
        var hasMedia = false
        var canNavigate = false
        var canStepBackward = false
        var canStepForward = false
        var playbackRequested = false
        var playbackRate: Float = 1
        var subtitleSelection = "automatic"
        var audioSelection = "automatic"
        var subtitleDelay: Double = 0
        var subtitleTracks: [Choice] = []
        var audioTracks: [Choice] = []
        var chapters: [Chapter] = []
        var externalSubtitleName = ""
        var subtitleEncoding: SubtitleEncoding = .automatic
    }

    @Published private(set) var snapshot = Snapshot()
    let model: PlayerModel?
    private var observations: [AnyCancellable] = []
    private var refreshTask: Task<Void, Never>?

    init(model: PlayerModel? = nil) {
        self.model = model
        guard let model else { return }
        refresh()
        for publisher in [model.objectWillChange, model.mediaControls.objectWillChange] {
            observations.append(publisher.sink { [weak self] in
                // @Published sends before assignment. Coalesce the synchronous
                // changes from loading/teardown and read their completed state.
                guard let self, self.refreshTask == nil else { return }
                self.refreshTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshTask = nil
                    self.refresh()
                }
            })
        }
    }

    deinit { refreshTask?.cancel() }

    private func refresh() {
        guard let model else { return }
        let media = model.mediaControls
        let hasMedia = model.player.currentItem != nil && !model.playbackFailed
        let updated = Snapshot(
            hasMedia: hasMedia,
            canNavigate: hasMedia && model.duration.isFinite && model.duration > 0,
            canStepBackward: model.canStepFrame(direction: -1),
            canStepForward: model.canStepFrame(direction: 1),
            playbackRequested: model.playbackRequested,
            playbackRate: model.playbackRate,
            subtitleSelection: media.subtitleSelection,
            audioSelection: media.audioSelection,
            subtitleDelay: media.subtitleDelay,
            subtitleTracks: media.subtitleTracks.map { Choice(id: $0.id, name: $0.name) },
            audioTracks: media.audioTracks.map { Choice(id: $0.id, name: $0.name) },
            chapters: media.chapters.map { Chapter(id: $0.id, title: $0.title, start: $0.start) },
            externalSubtitleName: media.externalSubtitleName,
            subtitleEncoding: media.externalSubtitleEncoding)
        if updated != snapshot { snapshot = updated }
    }
}
