import AVFoundation
import MediaToolbox

/// Applies boost in the item's audio graph; AVPlayer retains its native 0…1
/// attenuation, mute, transport, pitch processing, and synchronization.
@MainActor
final class AudioGainController {
    private let state: OpaquePointer

    init() {
        guard let state = SPAudioGainCreate(1) else { preconditionFailure("Audio gain initialization failed") }
        self.state = state
    }
    deinit { SPAudioGainRelease(state) }

    func setVolume(_ volume: Float) { SPAudioGainSet(state, max(1, volume)) }

    func makeMix(for asset: AVAsset) async throws -> AVAudioMix? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if tracks.isEmpty { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = try tracks.map { track in
            try Task.checkCancellation()
            guard let tap = SPAudioGainMakeTap(state) else {
                throw NSError(domain: "SwiftPlayerAudioGain", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Audio amplification could not be prepared."])
            }
            let input = AVMutableAudioMixInputParameters(track: track)
            input.audioTapProcessor = tap
            input.audioTimePitchAlgorithm = .spectral
            return input
        }
        return mix
    }
}
