import XCTest
@testable import SwiftPlayer

@MainActor
final class SystemVolumeTests: XCTestCase {
    private final class Backend: SystemVolumeBackend {
        var onChange: (() -> Void)?
        var state = SystemVolumeState(volume: 0.3125, canSetVolume: true, canSetMute: true)
        var writes: [Float] = []
        var muteWrites: [Bool] = []
        var fails = false
        var muteFails = false
        func read() -> SystemVolumeState { state }
        func setVolume(_ value: Float) -> Bool {
            guard !fails else { return false }
            writes.append(value); state.volume = value; return true
        }
        func setMuted(_ value: Bool) -> Bool {
            guard !fails, !muteFails else { return false }
            muteWrites.append(value); state.muted = value; return true
        }
    }

    func testOpeningReadsSystemStateWithoutChangingItAndKeysUseFivePercentSteps() {
        let backend = Backend()
        let control = SystemVolumeController(backend: backend)
        XCTAssertEqual(control.volume, 0.3125)
        XCTAssertTrue(backend.writes.isEmpty)
        control.increase(); control.increase()
        XCTAssertEqual(control.volume, 0.4125, accuracy: 0.000001)
        control.decrease(); control.decrease()
        XCTAssertEqual(control.volume, 0.3125, accuracy: 0.000001)
        for _ in 0..<100 { control.increase() }
        XCTAssertEqual(control.volume, 1)
        control.setVolume(4)
        XCTAssertEqual(control.volume, 1)
        for _ in 0..<100 { control.decrease() }
        XCTAssertEqual(control.volume, 0)
        XCTAssertTrue(control.isMuted)
        XCTAssertTrue(backend.writes.allSatisfy { (0...1).contains($0) })
        let count = backend.writes.count
        control.setVolume(.nan); control.setVolume(.infinity)
        XCTAssertEqual(backend.writes.count, count)
    }

    func testNativeChangesOutputReplacementAndFailuresAreReflected() {
        let backend = Backend()
        let control = SystemVolumeController(backend: backend)
        backend.state.volume = 0.7; backend.state.muted = true; backend.onChange?()
        XCTAssertEqual(control.volume, 0.7)
        XCTAssertTrue(control.isMuted)
        control.increase()
        XCTAssertEqual(control.volume, 0.75)
        XCTAssertFalse(control.isMuted)
        backend.state.muted = true
        backend.muteFails = true
        control.setVolume(0.75)
        XCTAssertTrue(control.isMuted)
        XCTAssertFalse(control.statusMessage.isEmpty)
        backend.muteFails = false
        backend.fails = true
        control.decrease()
        XCTAssertEqual(control.volume, 0.75)
        XCTAssertFalse(control.statusMessage.isEmpty)
        backend.state = SystemVolumeState()
        backend.onChange?()
        XCTAssertFalse(control.canSetVolume)
        XCTAssertFalse(control.canSetMute)
        let count = backend.writes.count
        control.increase()
        XCTAssertEqual(backend.writes.count, count)
        backend.state = SystemVolumeState(volume: 0.2, canSetVolume: true)
        backend.fails = false; backend.onChange?()
        XCTAssertEqual(control.volume, 0.2)
        XCTAssertTrue(control.statusMessage.isEmpty)
    }

    func testMuteUsesNativeControlOrVolumeFallbackAndRestoresAudibleLevel() {
        for nativeMute in [true, false] {
            let backend = Backend()
            backend.state.canSetMute = nativeMute
            let control = SystemVolumeController(backend: backend)
            control.toggleMute()
            XCTAssertTrue(control.isMuted)
            control.toggleMute()
            XCTAssertFalse(control.isMuted)
            XCTAssertEqual(control.volume, 0.3125)
            control.setVolume(0)
            control.toggleMute()
            XCTAssertEqual(control.volume, 0.3125)
            XCTAssertFalse(control.isMuted)
        }
    }

    func testControllerDoesNotRetainItsOwnerThroughNativeChangeCallbacks() {
        let backend = Backend()
        var control: SystemVolumeController? = SystemVolumeController(backend: backend)
        weak var released = control
        control = nil
        XCTAssertNil(released)
        backend.onChange?()
    }

    func testNativeBackendReadsWithoutWritingOrRetainingAController() {
        var backend: CoreAudioVolumeBackend? = CoreAudioVolumeBackend()
        weak var released = backend
        let state = backend?.read()
        if let volume = state?.volume { XCTAssertTrue(volume.isFinite && (0...1).contains(volume)) }
        backend = nil
        XCTAssertNil(released)
    }

    func testSystemVolumeModeIgnoresOldApplicationAttenuationAndMute() throws {
        let suite = "SystemVolume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.savedVolume = 0.1
        preferences.savedMute = true
        let model = PlayerModel(preferences: preferences, restoreApplicationVolume: false)
        defer { model.teardown() }
        XCTAssertEqual(model.volume, 1)
        XCTAssertEqual(model.player.volume, 1)
        XCTAssertFalse(model.player.isMuted)
        XCTAssertEqual(preferences.savedVolume, 0.1)
        XCTAssertTrue(preferences.savedMute)
    }
}
