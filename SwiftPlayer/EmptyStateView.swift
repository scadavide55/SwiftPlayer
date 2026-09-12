import SwiftUI
import UniformTypeIdentifiers

struct EmptyStateView: View {
    let onFileChosen: (URL) -> Void
    @State private var isTargeted: Bool = false
    @State private var showInfoPanel: Bool = false
    
    private var supportedTypesText: String {
        supportedExtensions.map { $0.uppercased() }.joined(separator: ", ")
    }
    
    var body: some View {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        Text("Drag and drop a video or audio file")
                            .font(.title3)
                        Text(supportedTypesText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Select File…") {
                        openFilePicker()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .foregroundStyle(.white)
                .overlay(
                    Rectangle()
                        .stroke(isTargeted ? Color.blue : Color.clear, lineWidth: 3)
                )
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }

                Button {
                    showInfoPanel = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(16)
                .popover(isPresented: $showInfoPanel, arrowEdge: .bottom) {
                    InfoPanelView()
                }
            }
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

// MARK: - Info panel (edit the text below however you like)

struct InfoPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SwiftPlayer 2")
                        .font(.headline)
                    Text("Version 2.1 Build 11")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(.subheadline).bold()
                Text("A minimal, fully native video and audio player built entirely with Apple's own swift frameworks — no third-party libraries or dependencies. Playback runs through AVFoundation, using the Mac's Apple Silicon chip  dedicated hardware decoder for smooth, power-efficient performance. The interface stays intentionally simple: play/pause, a scrubber with elapsed and remaining time, keyboard shortcuts for quick control, and support for SRT, VTT, and ASS/SSA subtitles with an adjustable delay. Nothing else runs in the background — just what's needed to play.")
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
                Text("• Drag a file onto the window, or click Select File…\n• Hover your mouse over the video to show controls\n•  Controls hide automatically after 5 seconds")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
