import SwiftUI

struct ControlsOverlay: View {
    @ObservedObject var model: PlayerModel
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.seek(to: max(model.currentTime - 10, 0))
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
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            
            Button {
                model.seek(to: min(model.currentTime + 10, model.duration))
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
                    model.isMuted.toggle()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                
                Slider(value: $model.volume, in: 0...1)
                    .frame(width: 70)
                    .controlSize(.mini)
                
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            model.playbackRate = Float(rate)
                        } label: {
                            if Float(rate) == model.playbackRate {
                                Label("\(rate, specifier: "%.2g")×", systemImage: "checkmark")
                            } else {
                                Text("\(rate, specifier: "%.2g")×")
                            }
                        }
                    }
                } label: {
                    Text("\(Double(model.playbackRate), specifier: "%.2g")×")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 28)
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
