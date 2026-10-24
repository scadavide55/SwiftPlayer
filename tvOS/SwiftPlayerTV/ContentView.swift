import SwiftUI

struct ContentView: View {
    @State private var playingItem: MediaItem?

    var body: some View {
        Group {
            if let playingItem {
                PlayerScreen(item: playingItem) {
                    self.playingItem = nil
                }
            } else {
                HomeView { item in
                    playingItem = item
                }
            }
        }
    }
}
