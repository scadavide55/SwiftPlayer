import XCTest
import AVFoundation
import Combine
@testable import SwiftPlayer

@MainActor
final class PlayerMenuStateTests: XCTestCase {
    private func settle() async {
        // The menu adapter reads @Published values after their assignments.
        for _ in 0..<5 { await Task.yield() }
    }

    func testPlaybackTicksCaptionsAndApplicationMuteDoNotInvalidateMenus() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        let state = PlayerMenuState(model: model)
        let item = AVPlayerItem(asset: AVMutableComposition())
        model.mediaControls.attach(to: item, sourceURL: URL(fileURLWithPath: "/generated-caption-fixture"))
        let output = try XCTUnwrap(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.first)
        await settle()
        var playbackChanges = 0
        let liveObservation = model.objectWillChange.sink { playbackChanges += 1 }
        defer { liveObservation.cancel() }
        var changes = 0
        let observation = state.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for round in 1...100 {
            model.currentTime = Double(round)
            model.currentSubtitleText = "Caption \(round)"
            model.mediaControls.legibleOutput(output, didOutputAttributedStrings: [NSAttributedString(string: "Embedded \(round)")],
                nativeSampleBuffers: [], forItemTime: CMTime(seconds: Double(round), preferredTimescale: 600))
            model.mediaControls.tick(time: Double(round), duration: 200)
            await settle()
        }
        XCTAssertGreaterThanOrEqual(playbackChanges, 200, "The live player must still deliver time and caption updates")
        XCTAssertEqual(model.mediaControls.embeddedText, "Embedded 100")
        XCTAssertEqual(changes, 0, "Continuous playback updates must not rebuild an open menu")
        model.playbackRate = 1.25
        await settle()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(state.snapshot.playbackRate, 1.25)
        model.isMuted = true
        await settle()
        XCTAssertEqual(changes, 1, "Application mute is not a menu input in system-volume mode")
        model.mediaControls.subtitleSelection = "off"
        await settle()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(state.snapshot.subtitleSelection, "off")
        // Duplicate assignments are common during native state synchronization.
        model.playbackRate = 1.25
        model.isMuted = true
        await settle()
        XCTAssertEqual(changes, 2)
    }

    func testWindowTargetsRemainDistinctAndDoNotRetainClosedPlayers() async {
        var model: PlayerModel? = PlayerModel()
        var state: PlayerMenuState? = PlayerMenuState(model: model)
        weak var weakModel = model
        weak var weakState = state
        func context(_ menus: PlayerMenuState) -> PlayerWindowContext {
            PlayerWindowContext(menus: menus, viewing: PlayerWindowControls(), capture: FrameCaptureController(), open: { _ in }, history: {}, jump: {}, information: {}, subtitles: {}, findSubtitles: {})
        }
        XCTAssertEqual(context(state!), context(state!))
        XCTAssertNotEqual(context(state!), context(PlayerMenuState(model: PlayerModel())))
        model?.currentTime = 10
        model?.teardown()
        model = nil
        state = nil
        await settle()
        XCTAssertNil(weakState)
        XCTAssertNil(weakModel)
    }

    func testInactiveMenuStateDisablesMediaCommands() {
        let state = PlayerMenuState()
        XCTAssertFalse(state.snapshot.hasMedia)
        XCTAssertFalse(state.snapshot.canNavigate)
        XCTAssertTrue(state.snapshot.chapters.isEmpty)
        XCTAssertTrue(state.snapshot.audioTracks.isEmpty)
        XCTAssertEqual(state.snapshot.subtitleSelection, "automatic")
    }
}
