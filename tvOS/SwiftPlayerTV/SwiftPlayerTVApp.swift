import SwiftUI

@main
struct SwiftPlayerTVApp: App {
    @StateObject private var library = MediaLibrary()
    @StateObject private var localLibrary = LocalLibrary()
    @StateObject private var server = LocalFileServer()
    @StateObject private var downloads = DownloadManager(
        directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(localLibrary)
                .environmentObject(server)
                .environmentObject(downloads)
        }
    }
}
