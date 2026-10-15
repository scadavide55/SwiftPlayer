import SwiftUI

@main
struct MinimalPlayerApp: App {
    var body: some Scene {
        WindowGroup(id: "player") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands { PlayerCommands() }
        Settings { PlayerPreferencesView(preferences: PlayerPreferences.shared) }
    }
}

