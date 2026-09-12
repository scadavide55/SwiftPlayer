import SwiftUI

struct ControlsOverlay: View {
    @ObservedObject var model: PlayerModel
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.55))
        )
    }
}
