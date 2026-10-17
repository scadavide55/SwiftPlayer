import SwiftUI
import AVFoundation

struct ControlsOverlay: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var systemVolume: SystemVolumeController = .shared
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.skip(by: -10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Skip back 10 seconds")
            
            Button {
                model.togglePlayPause()
            } label: {
                    Image(systemName: model.playbackFinished ? "arrow.counterclockwise" : (model.playbackRequested ? "pause.fill" : "play.fill"))
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.playbackFinished ? "Replay" : "Play / Pause (Space)")
            
            Button {
                model.skip(by: 10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Skip forward 10 seconds")
            
            Text(formatTime(model.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 46, alignment: .leading)
            
            ScrubberView(
                currentTime: $model.currentTime,
                duration: model.duration,
                asset: model.player.currentItem?.asset,
                onScrubStart: { model.isScrubbing = true },
                onScrubEnd: { newTime in
                    model.seek(to: newTime)
                    model.isScrubbing = false
                }
            )
            
            Text(formatTime(model.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 46, alignment: .trailing)
            
            HStack(spacing: 8) {
                Button {
                    systemVolume.toggleMute()
                } label: {
                    Image(systemName: systemVolume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(!systemVolume.canSetMute)
                .help("Mute the Mac's system audio")
                
                Slider(value: Binding(get: { systemVolume.volume }, set: { systemVolume.setVolume($0) }),
                       in: 0...1, step: 0.05)
                    .accessibilityLabel("System Volume")
                    .accessibilityValue(systemVolume.canSetVolume ? "\(Int((systemVolume.volume * 100).rounded())) percent" : "Unavailable")
                    .disabled(!systemVolume.canSetVolume)
                    .help(systemVolume.statusMessage.isEmpty ? "Mac system volume · affects all apps" : systemVolume.statusMessage)
                    .frame(width: 70)
                    .controlSize(.mini)
                
                Text(systemVolume.canSetVolume ? "\(Int((systemVolume.volume * 100).rounded()))%" : "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 36, alignment: .trailing)
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            model.playbackRate = Float(rate)
                        } label: {
                            if Float(rate) == model.playbackRate {
                                Label(formatPlaybackRate(Float(rate)), systemImage: "checkmark")
                            } else {
                                Text(formatPlaybackRate(Float(rate)))
                            }
                        }
                    }
                } label: {
                    Text(formatPlaybackRate(model.playbackRate))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 40)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.55))
        )
    }
}
