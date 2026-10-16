import AudioToolbox
import CoreAudio
import Combine
import Foundation

struct SystemVolumeState {
    var volume: Float?
    var muted = false
    var canSetVolume = false
    var canSetMute = false
}

@MainActor
protocol SystemVolumeBackend: AnyObject {
    var onChange: (() -> Void)? { get set }
    func read() -> SystemVolumeState
    func setVolume(_ value: Float) -> Bool
    func setMuted(_ value: Bool) -> Bool
}

/// One output-device controller is shared by every player window. It reads
/// existing system state at startup; opening the player never changes it.
@MainActor
final class SystemVolumeController: ObservableObject {
    static let shared = SystemVolumeController(backend: CoreAudioVolumeBackend())
    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canSetMute = false
    @Published private(set) var statusMessage = ""
    private let backend: SystemVolumeBackend
    private var nativeMute = false
    private var nativeCanMute = false
    private var lastAudibleVolume: Float = 0.5

    init(backend: SystemVolumeBackend) {
        self.backend = backend
        backend.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        let state = backend.read()
        let value = state.volume.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        let next = value ?? 0
        if volume != next { volume = next }
        nativeMute = state.muted
        nativeCanMute = state.canSetMute
        let muted = nativeMute || value == 0
        if isMuted != muted { isMuted = muted }
        canSetVolume = value != nil && state.canSetVolume
        canSetMute = state.canSetMute || canSetVolume
        if next > 0 { lastAudibleVolume = next }
        statusMessage = canSetVolume ? "" : "System volume is unavailable for this output. Use its hardware volume control."
    }

    func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        refresh()
        guard canSetVolume else { return }
        let target = min(max(value, 0), 1)
        guard backend.setVolume(target) else {
            statusMessage = "The system volume could not be changed."
            return
        }
        let unmuted = target <= 0 || !nativeMute || !nativeCanMute || backend.setMuted(false)
        refresh()
        if !unmuted { statusMessage = "The system mute state could not be changed." }
    }

    func increase() { adjust(by: 0.05) }
    func decrease() { adjust(by: -0.05) }

    private func adjust(by amount: Float) {
        refresh()
        // Preserve arbitrary native levels (e.g. keyboard steps of 1/16),
        // adding exactly five percentage points without accumulated float drift.
        setVolume((volume * 1_000_000 + amount * 1_000_000).rounded() / 1_000_000)
    }

    func setMuted(_ muted: Bool) {
        refresh()
        guard canSetMute else { return }
        if !muted, volume == 0, canSetVolume {
            guard backend.setVolume(lastAudibleVolume) else { return }
        }
        let succeeded = nativeCanMute ? backend.setMuted(muted)
            : muted ? backend.setVolume(0) : true
        refresh()
        if !succeeded { statusMessage = "The system mute state could not be changed." }
    }

    func toggleMute() { refresh(); setMuted(!isMuted) }
}

/// The virtual main control preserves channel balance. Devices without it use
/// their native main scalar control; fixed-volume outputs stay unavailable.
@MainActor
final class CoreAudioVolumeBackend: SystemVolumeBackend {
    var onChange: (() -> Void)?
    private var device: AudioDeviceID = kAudioObjectUnknown
    private var volumeAddress: AudioObjectPropertyAddress?
    private var muteAddress: AudioObjectPropertyAddress?
    nonisolated private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []

    init() {
        listen(AudioObjectID(kAudioObjectSystemObject), address: Self.routeAddress)
        updateRoute()
    }

    private static var routeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                  mElement: kAudioObjectPropertyElementMain)
    }

    private func updateRoute() {
        let next: AudioDeviceID = readValue(AudioObjectID(kAudioObjectSystemObject),
                                           address: Self.routeAddress, initial: kAudioObjectUnknown) ?? kAudioObjectUnknown
        guard next != device else { return }
        for listener in listeners.filter({ $0.object != AudioObjectID(kAudioObjectSystemObject) }) {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
        }
        listeners.removeAll { $0.object != AudioObjectID(kAudioObjectSystemObject) }
        device = next
        volumeAddress = nil
        muteAddress = nil
        guard device != kAudioObjectUnknown else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var address = Self.outputAddress(selector)
            if AudioObjectHasProperty(device, &address), isWritable(address) {
                volumeAddress = address
                listen(device, address: address)
                break
            }
        }
        var mute = Self.outputAddress(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &mute), isWritable(mute) {
            muteAddress = mute
            listen(device, address: mute)
        }
    }

    private func isWritable(_ requested: AudioObjectPropertyAddress) -> Bool {
        var address = requested
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func listen(_ object: AudioObjectID, address requested: AudioObjectPropertyAddress) {
        var address = requested
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append(Listener(object: object, address: requested, block: block))
        }
    }

    private func readValue<T: BitwiseCopyable>(_ object: AudioObjectID, address requested: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = requested, value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    func read() -> SystemVolumeState {
        updateRoute()
        let volume = volumeAddress.flatMap { readValue(device, address: $0, initial: Float(0)) }
        let muted = muteAddress.flatMap { readValue(device, address: $0, initial: UInt32(0)) } ?? 0
        return SystemVolumeState(volume: volume, muted: muted != 0,
            canSetVolume: volumeAddress.map(isWritable) ?? false, canSetMute: muteAddress.map(isWritable) ?? false)
    }

    private func write<T: BitwiseCopyable>(_ value: T, address requested: AudioObjectPropertyAddress?) -> Bool {
        guard var address = requested, device != kAudioObjectUnknown, isWritable(address) else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    func setVolume(_ value: Float) -> Bool {
        guard value.isFinite else { return false }
        updateRoute()
        return write(min(max(value, 0), 1), address: volumeAddress)
    }

    func setMuted(_ value: Bool) -> Bool {
        updateRoute()
        return write(UInt32(value ? 1 : 0), address: muteAddress)
    }

    deinit {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
        }
    }
}
