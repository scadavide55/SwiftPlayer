import SwiftUI
import UniformTypeIdentifiers

struct EmptyStateView: View {
    let onFileChosen: (URL) -> Void
    let onHistorySelected: (HistoryEntry) -> Void
    @ObservedObject var history: HistoryStore = .shared
    @State private var isTargeted: Bool = false
    @State private var showInfoPanel: Bool = false
    
    private var supportedTypesText: String {
        supportedExtensions.map { $0.uppercased() }.joined(separator: ", ")
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
            
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "play.rectangle.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.white.opacity(0.85))
                    .animation(.easeOut(duration: 0.15), value: isTargeted)

                VStack(spacing: 6) {
                    Text("Drop a video or audio file")
                        .font(.title3.weight(.medium))
                    Text(supportedTypesText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Select File…") {
                    openFilePicker()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                
                if !history.entries.isEmpty {
                    recentList
                        .padding(.top, 6)
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.white.opacity(0.08),
                    style: StrokeStyle(lineWidth: isTargeted ? 3 : 1.5, dash: isTargeted ? [] : [6, 5])
                )
                .padding(10)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: isTargeted)

            Button {
                showInfoPanel = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(20)
            .popover(isPresented: $showInfoPanel, arrowEdge: .bottom) {
                InfoPanelView()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { history.clear() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry) { onHistorySelected(entry) }
                            .contextMenu {
                                Button("Remove from History") { history.remove(id: entry.id) }
                            }
                    }
                }
            }
            .frame(maxHeight: 190)
        }
        .frame(maxWidth: 380)
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

private struct HistoryRow: View {
    let entry: HistoryEntry
    let action: () -> Void
    @State private var isHovering = false
    
    private var detail: String {
        if entry.duration > 0, entry.position >= HistoryStore.minResumePosition,
           entry.position < entry.duration - HistoryStore.finishedMargin {
            return "\(formatTime(entry.position)) of \(formatTime(entry.duration))"
        }
        return entry.duration > 0 ? formatTime(entry.duration) : "Not played yet"
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    HStack(spacing: 8) {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if entry.progress > 0, entry.position >= HistoryStore.minResumePosition {
                            ProgressView(value: entry.progress)
                                .progressViewStyle(.linear)
                                .controlSize(.mini)
                                .frame(width: 60)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.10 : 0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Info panel (edit the text below however you like)

struct InfoPanelView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SwiftPlayer")
                        .font(.headline)
                    Text("Version \(appVersion) Build \(appBuild)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(.subheadline).bold()
                Text("A minimal, fully native video and audio player built entirely with Apple's own swift frameworks — no third-party libraries or dependencies. Playback runs through AVFoundation, using the Mac's Apple Silicon chip  dedicated hardware decoder for smooth, power-efficient performance. The interface stays intentionally simple: play/pause, a scrubber with elapsed and remaining time, keyboard shortcuts for quick control, a recent files list that resumes where you left off, and support for SRT, VTT, and ASS/SSA subtitles with an adjustable delay. Nothing else runs in the background — just what's needed to play.")
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
