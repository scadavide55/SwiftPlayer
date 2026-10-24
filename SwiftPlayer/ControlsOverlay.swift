import SwiftUI

struct ControlsOverlay: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.seek(to: model.currentTime - 10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 16))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(ControlIconButtonStyle())
            .help("Skip back 10 seconds")

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(ControlIconButtonStyle())

            Button {
                model.seek(to: model.currentTime + 10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 16))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(ControlIconButtonStyle())
            .help("Skip forward 10 seconds")

            Text(formatTime(model.currentTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
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
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 46, alignment: .trailing)

            HStack(spacing: 8) {
                Button {
                    model.isMuted.toggle()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .frame(width: 18)
                }
                .buttonStyle(ControlIconButtonStyle())

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
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 30)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassPanel()
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
