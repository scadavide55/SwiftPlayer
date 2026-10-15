import XCTest
import AVFoundation
import AppKit
import Combine
@testable import SwiftPlayer

@MainActor
final class VolumeBoostTests: DebugMatrixTestCase {
    private func preferences() throws -> (PlayerPreferences, UserDefaults, String) {
        let name = "VolumeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (PlayerPreferences(defaults: defaults), defaults, name)
    }

    func testMaximumPersistsClampsAndUpdatesOpenPlayers() async throws {
        let (settings, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(settings.maximumVolume, 2)
        let first = PlayerModel(preferences: settings)
        let second = PlayerModel(preferences: settings)
        defer { first.teardown(); second.teardown() }
        settings.maximumVolume = 4
        first.volume = 3.5
        second.volume = 4
        XCTAssertEqual(first.volume, 3.5)
        XCTAssertEqual(first.player.volume, 1)
        first.isMuted = true
        settings.maximumVolume = 1.5
        XCTAssertEqual(first.volume, 1.5)
        XCTAssertTrue(first.isMuted, "Lowering the configured ceiling must preserve mute")
        XCTAssertEqual(second.volume, 1.5)
        XCTAssertEqual(PlayerPreferences(defaults: defaults).maximumVolume, 1.5)
        XCTAssertEqual(PlayerPreferences(defaults: defaults).savedVolume, 1.5)
        var observedLimits: [Float] = []
        let observation = first.$maximumVolume.sink { observedLimits.append($0) }
        defer { observation.cancel() }
        settings.maximumVolume = .nan
        XCTAssertEqual(settings.maximumVolume, 1.5)
        settings.maximumVolume = 100
        XCTAssertEqual(settings.maximumVolume, 4)
        settings.maximumVolume = -1
        XCTAssertEqual(settings.maximumVolume, 1)
        XCTAssertTrue(observedLimits.allSatisfy { $0.isFinite && (1...4).contains($0) })
    }

    func testVolumeKeysUseFivePercentStepsMuteAtZeroAndReachConfiguredMaximum() throws {
        let (settings, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.maximumVolume = 4
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        let view = KeyEventHandlingView.KeyCatcherView()
        view.onVolumeUp = { model.volumeUp() }
        view.onVolumeDown = { model.volumeDown() }
        defer { KeyEventHandlingView.dismantleNSView(view, coordinator: ()) }
        func key(_ code: UInt16) throws {
            view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
        }
        model.volume = 0.333
        model.volumeUp()
        XCTAssertEqual(model.volume, 0.383, accuracy: 0.00001)
        model.volume = 0
        XCTAssertTrue(model.isMuted)
        for step in 1...80 {
            try key(126)
            XCTAssertEqual(model.volume, Float(step) * 0.05, accuracy: 0.0001)
            XCTAssertFalse(model.isMuted)
        }
        try key(126)
        XCTAssertEqual(model.volume, 4)
        for step in stride(from: 79, through: 0, by: -1) {
            try key(125)
            XCTAssertEqual(model.volume, Float(step) * 0.05, accuracy: 0.0001)
        }
        try key(125)
        XCTAssertEqual(model.volume, 0)
        XCTAssertTrue(model.isMuted)
        XCTAssertTrue(model.player.isMuted)
    }

    func testBoostSurvivesNativeMuteAndLoadReplacement() async throws {
        let model = PlayerModel()
        defer { model.teardown() }
        model.volume = 2
        model.player.isMuted = true
        try await waitUntilCondition { model.isMuted }
        XCTAssertEqual(model.volume, 2)
        model.player.isMuted = false
        try await waitUntilCondition { !model.isMuted }
        XCTAssertEqual(model.volume, 2)
        try await ready(model)
        XCTAssertNotNil(model.player.currentItem?.audioMix)
        XCTAssertEqual(model.volume, 2)
        XCTAssertEqual(model.player.volume, 1)
        try await ready(model, url: audio[0])
        XCTAssertNotNil(model.player.currentItem?.audioMix)
        XCTAssertEqual(model.volume, 2)
        model.player.volume = 0.5
        try await waitUntilCondition { model.volume == 0.5 }
        XCTAssertFalse(model.isMuted)
    }

    private func measuredPeak(gain: Float, amplitude: Float, channels: AVAudioChannelCount) async throws -> Float {
        let source = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = amplitude * sin(Float(frame) * 2 * .pi * 1000 / 48000)
            }
        }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let asset = AVURLAsset(url: source)
        var processor: AudioGainController? = AudioGainController()
        processor?.setVolume(gain)
        let mix = try await processor?.makeMix(for: asset)
        // Taps must own the render state independently of the Swift controller.
        weak var weakProcessor = processor
        processor = nil
        XCTAssertNil(weakProcessor)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = mix
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var peak: Float = 0
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var length = 0
            var bytes: UnsafeMutablePointer<Int8>?
            XCTAssertEqual(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &bytes), kCMBlockBufferNoErr)
            let data = try XCTUnwrap(bytes)
            data.withMemoryRebound(to: Float.self, capacity: length / 4) { values in
                for i in 0..<(length / 4) { peak = max(peak, abs(values[i])) }
            }
            sampleCount += length / 4
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(sampleCount, 0)
        return peak
    }

    func testNativeAudioMixActuallyAmplifiesMonoAndStereoSamplesAndLimitsPeaks() async throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for gain: Float in [1, 2, 4] {
                let peak = try await measuredPeak(gain: gain, amplitude: 0.1, channels: channels)
                XCTAssertEqual(peak, 0.1 * gain, accuracy: 0.002)
            }
            let limited = try await measuredPeak(gain: 4, amplitude: 0.8, channels: channels)
            XCTAssertEqual(limited, 1, accuracy: 0.002)
        }
    }
}
