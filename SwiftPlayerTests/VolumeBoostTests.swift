import XCTest
import AVFoundation
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

    func testRememberedZeroVolumeStartsWithConsistentMuteState() throws {
        let (settings, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.savedVolume = 0
        settings.savedMute = false // Valid legacy settings from before zero-volume automute.
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        XCTAssertEqual(model.volume, 0)
        XCTAssertTrue(model.player.isMuted)
        XCTAssertTrue(model.isMuted, "The mute button must reflect the native zero-volume mute state at startup.")
        XCTAssertTrue(PlayerMenuState(model: model).snapshot.isMuted)
        model.volume = 0.05
        XCTAssertEqual(model.volume, 0.05, accuracy: 0.001)
        XCTAssertFalse(model.isMuted)
        XCTAssertFalse(model.player.isMuted)
    }

    private func renderedSamples(gain: Float, amplitude: Float, channels: AVAudioChannelCount,
                                 limiter: Bool = true, normalization: Bool = false, seconds: Double = 0.1) async throws -> [Float] {
        let source = directory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48000)))
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
        processor?.configure(limiter: limiter, normalization: normalization)
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
        var rendered: [Float] = []
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var length = 0
            var bytes: UnsafeMutablePointer<Int8>?
            XCTAssertEqual(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &bytes), kCMBlockBufferNoErr)
            let data = try XCTUnwrap(bytes)
            data.withMemoryRebound(to: Float.self, capacity: length / 4) { values in
                rendered.append(contentsOf: UnsafeBufferPointer(start: values, count: length / 4))
            }
            sampleCount += length / 4
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(sampleCount, 0)
        return rendered
    }

    private func measuredPeak(gain: Float, amplitude: Float, channels: AVAudioChannelCount) async throws -> Float {
        try await renderedSamples(gain: gain, amplitude: amplitude, channels: channels).map(abs).max() ?? 0
    }

    func testNativeAudioMixActuallyAmplifiesMonoAndStereoSamplesAndLimitsPeaks() async throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for gain: Float in [1, 2, 4] {
                let peak = try await measuredPeak(gain: gain, amplitude: 0.1, channels: channels)
                XCTAssertEqual(peak, 0.1 * gain, accuracy: 0.002)
            }
            let limited = try await measuredPeak(gain: 4, amplitude: 0.8, channels: channels)
            XCTAssertEqual(limited, 0.98, accuracy: 0.002)
        }
    }
    func testLimiterAvoidsClippedPlateausAndCanBeDisabled() async throws {
        let protected = try await renderedSamples(gain: 4, amplitude: 0.8, channels: 2)
        let unprotected = try await renderedSamples(gain: 4, amplitude: 0.8, channels: 2, limiter: false)
        XCTAssertLessThanOrEqual(protected.map(abs).max() ?? 0, 0.981)
        XCTAssertFalse(protected.contains { abs($0) >= 0.999 })
        XCTAssertTrue(unprotected.contains { abs($0) >= 0.999 })
        // Block-wide stereo linking must preserve equal channels.
        for frame in 0..<(protected.count / 2) { XCTAssertEqual(protected[frame * 2], protected[frame * 2 + 1]) }
    }

    func testNormalizationBalancesLevelsAndDoesNotBoostNoiseOrSilence() async throws {
        func rms(_ samples: [Float]) -> Double {
            let tail = samples.suffix(48000)
            return sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count))
        }
        let quiet = try await renderedSamples(gain: 1, amplitude: 0.05, channels: 1, normalization: true, seconds: 5)
        let loud = try await renderedSamples(gain: 1, amplitude: 0.8, channels: 1, normalization: true, seconds: 5)
        XCTAssertEqual(rms(quiet), 0.14, accuracy: 0.01)
        XCTAssertEqual(rms(loud), 0.14, accuracy: 0.01)
        let noise = try await renderedSamples(gain: 1, amplitude: 0.001, channels: 1, normalization: true)
        XCTAssertLessThanOrEqual(noise.map(abs).max() ?? 0, 0.00101)
        let silence = try await renderedSamples(gain: 4, amplitude: 0, channels: 2, normalization: true)
        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
    }

    func testAudioProcessingPreferencesPersistAndUpdateWithoutReplacingMedia() async throws {
        let (settings, defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(settings.limitAudioPeaks)
        XCTAssertFalse(settings.normalizeAudio)
        let model = PlayerModel(preferences: settings)
        defer { model.teardown() }
        try await ready(model)
        let item = try XCTUnwrap(model.player.currentItem)
        settings.limitAudioPeaks = false
        settings.normalizeAudio = true
        XCTAssertTrue(model.player.currentItem === item)
        XCTAssertEqual(model.player.rate, 0)
        let restored = PlayerPreferences(defaults: defaults)
        XCTAssertFalse(restored.limitAudioPeaks)
        XCTAssertTrue(restored.normalizeAudio)
    }

}
