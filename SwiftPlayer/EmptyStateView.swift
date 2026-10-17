import SwiftUI
import UniformTypeIdentifiers

struct EmptyStateView: View {
    let onFileChosen: (URL) -> Void
    @State private var isTargeted: Bool = false
    @State private var showInfoPanel: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 18) {
                Button(action: openFilePicker) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 112, weight: .regular))
                        .frame(width: 144, height: 144)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Open Video")
                .accessibilityIdentifier("home.open")
                .help("Choose a video file")

                VStack(spacing: 7) {
                    Text("Open a video").font(.system(size: 17, weight: .medium))
                    Text("or drag a file here")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
            HStack(spacing: 28) {
                settingsButton
                Button { showInfoPanel = true } label: { utilityIcon("info.circle") }
                    .accessibilityLabel("About SwiftPlayer")
                    .accessibilityIdentifier("home.info")
                    .help("About this version")
                    .popover(isPresented: $showInfoPanel, arrowEdge: .bottom) {
                        InfoPanelView()
                    }
                Link(destination: URL(string: "https://sample.com")!) {
                    utilityIcon("heart")
                }
                .accessibilityLabel("Donate")
                .accessibilityIdentifier("home.donate")
                .help("Donate")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.bottom, 30)
        }
        .frame(width: 480, height: 640)
        .background(Color(red: 0.10, green: 0.11, blue: 0.12))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(isTargeted ? Color.accentColor : .clear, lineWidth: 3))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    private func utilityIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private var settingsButton: some View {
        Group {
            if #available(macOS 14.0, *) {
                SettingsLink { utilityIcon("gearshape") }
            } else {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: { utilityIcon("gearshape") }
            }
        }
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("home.settings")
        .help("Settings")
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { return }
            DispatchQueue.main.async {
                onFileChosen(url)
            }
        }
        return true
    }
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        
        if panel.runModal() == .OK, let url = panel.url {
            onFileChosen(url)
        }
    }
}

// MARK: - Version information

struct InfoPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SwiftPlayer")
                        .font(.headline)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(.subheadline).bold()
                Text("A native video and audio player using Apple’s AVFoundation. Choose audio and subtitle tracks, load external subtitles, customize caption fonts and appearance, jump to chapters or a time, and reopen recent files. Settings remember your language and appearance choices, with optional playback resume. Mac system volume is shared by all apps. Available codecs and resolutions depend on your device.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Supported formats")
                    .font(.subheadline).bold()
                Text(supportedExtensions.map { $0.uppercased() }.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("How to use")
                    .font(.subheadline).bold()
                Text("• Click the large play icon to choose a file, or drag a file onto the home panel\n• Hover your mouse over the video to show controls\n•  Controls hide automatically after 5 seconds")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
