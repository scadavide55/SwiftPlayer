import SwiftUI
import AppKit

@main
struct MinimalPlayerApp: App {
    @NSApplicationDelegateAdaptor(PlayerApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup(id: "player", for: PlayerOpenRequest.self) { $request in
            ContentView(openRequest: request)
        }
        .windowResizability(.contentSize)
        .commands { PlayerCommands() }
        Settings { PlayerPreferencesView(preferences: PlayerPreferences.shared) }
    }
}


/// AppKit can regenerate a View menu for tabbing and native fullscreen even
/// after SwiftUI's command groups are replaced. Keep the requested menu layout
/// whenever AppKit updates its windows, including opening additional players.
final class PlayerApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillUpdate(_ notification: Notification) {
        guard let menu = NSApp.mainMenu, let view = menu.items.first(where: { $0.title == "View" }) else { return }
        menu.removeItem(view)
    }
}
