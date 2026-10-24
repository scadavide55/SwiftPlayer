import SwiftUI

/// Manages media stored on the Apple TV itself: starts/stops the upload
/// server (with a PIN and QR code) and lists the files that have been sent over.
struct LocalFilesView: View {
    @EnvironmentObject private var localLibrary: LocalLibrary
    @EnvironmentObject private var server: LocalFileServer
    @Environment(\.dismiss) private var dismiss

    let onPlay: (MediaItem) -> Void

    @State private var showDeleteAllConfirm = false
    @State private var pendingDelete: LocalFile?
    @State private var suppressActivation = false

    var body: some View {
        NavigationStack {
            List {
                serverSection
                filesSection
            }
            .navigationTitle("Local Files")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $localLibrary.sortOrder) {
                            ForEach(LocalLibrary.SortOrder.allCases) { order in
                                Label(order.title, systemImage: order.systemImage)
                                    .tag(order)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete all local files?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    localLibrary.deleteAll()
                }
            } message: {
                Text("This removes every file stored on this Apple TV.")
            }
            .confirmationDialog(
                "Delete “\(pendingDelete?.name ?? "")”?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { presented in
                        if !presented {
                            pendingDelete = nil
                            suppressActivation = false
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { file in
                Button("Delete", role: .destructive) {
                    localLibrary.delete(file)
                    pendingDelete = nil
                    suppressActivation = false
                }
                Button("Cancel", role: .cancel) {
                    suppressActivation = false
                }
            } message: { _ in
                Text("This removes the file from this Apple TV.")
            }
            .onAppear { localLibrary.refresh() }
        }
    }

    private var serverSection: some View {
        Section {
            if server.isRunning {
                HStack(alignment: .top, spacing: 40) {
                    if let qrText = server.authenticatedURL {
                        QRCodeView(text: qrText)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 12, height: 12)
                            Text("Upload server running")
                                .font(.headline)
                        }

                        if let url = server.serverURL {
                            Text(url)
                                .font(.system(.title3, design: .monospaced))
                                .foregroundStyle(.tint)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("PIN")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(server.accessToken)
                                .font(.system(.title2, design: .monospaced).bold())
                                .tracking(6)
                        }

                        Text("Scan the QR code or open the address on your phone or computer, then enter the PIN.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 520, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 16) {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upload server stopped")
                            .font(.headline)
                        Text("Start the server to send files from a browser on the same network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage = server.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                if server.isRunning {
                    server.stop()
                } else {
                    server.start()
                }
            } label: {
                Label(server.isRunning ? "Stop Server" : "Start Server",
                      systemImage: server.isRunning ? "stop.circle" : "play.circle")
            }
        } header: {
            Text("Upload Server")
        }
    }

    private var filesSection: some View {
        Section {
            if localLibrary.files.isEmpty {
                Text("No files yet. Start the server and upload from a browser.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(localLibrary.files) { file in
                    fileRow(file)
                }

                Button("Delete All", role: .destructive) {
                    showDeleteAllConfirm = true
                }
            }
        } header: {
            Text("On This Apple TV · \(localLibrary.files.count) · \(localLibrary.totalSizeDescription)")
        }
    }

    private func fileRow(_ file: LocalFile) -> some View {
        Button {
            if suppressActivation {
                suppressActivation = false
            } else {
                onPlay(file.mediaItem)
                dismiss()
            }
        } label: {
            HStack(spacing: 20) {
                AsyncThumbnailView(url: file.url, width: 150)

                VStack(alignment: .leading, spacing: 6) {
                    Text(file.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(file.fileExtension) · \(file.sizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if resumeTime(for: file) > 0 {
                        Text("Resume at \(formatTime(resumeTime(for: file)))")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .onLongPressGesture(minimumDuration: 1.0) {
            suppressActivation = true
            pendingDelete = file
        }
    }

    private func resumeTime(for file: LocalFile) -> Double {
        PlaybackProgressStore.shared.resumeTime(for: file.url)
    }
}
