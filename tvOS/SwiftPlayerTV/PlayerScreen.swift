import SwiftUI

struct PlayerScreen: View {
    let item: MediaItem
    let onExit: () -> Void

    @StateObject private var model = PlayerModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoPlayerView(player: model.player)
                .ignoresSafeArea()

            if !model.currentSubtitleText.isEmpty {
                Text(model.currentSubtitleText)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 80)
                    .padding(.bottom, 150)
            }
        }
        .onExitCommand(perform: onExit)
        .task {
            if let url = item.url {
                model.load(url: url)
            }
        }
        .onDisappear {
            model.teardown()
        }
    }
}
