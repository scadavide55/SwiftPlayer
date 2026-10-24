import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: MediaLibrary
    @EnvironmentObject private var localLibrary: LocalLibrary
    let onPlay: (MediaItem) -> Void

    @State private var showAddStream = false
    @State private var showLocalFiles = false
    @State private var showDownloads = false
    @State private var showAddMenu = false

    @State private var pendingDeletion: DeletionTarget?
    @State private var suppressActivation = false

    /// Identifies an item awaiting a long-press delete confirmation.
    private enum DeletionTarget: Identifiable {
        case stream(MediaItem)
        case local(LocalFile)

        var id: String {
            switch self {
            case .stream(let item): return "stream-\(item.id.uuidString)"
            case .local(let file): return "local-\(file.url.absoluteString)"
            }
        }

        var name: String {
            switch self {
            case .stream(let item): return item.name
            case .local(let file): return file.name
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty && localLibrary.files.isEmpty {
                    emptyState
                } else {
                    List {
                        addSection

                        if !library.items.isEmpty {
                            Section("Streams") {
                                ForEach(library.items) { item in
                                    streamRow(item)
                                }
                            }
                        }

                        if !localLibrary.files.isEmpty {
                            Section("Local Files · \(localLibrary.totalSizeDescription)") {
                                ForEach(localLibrary.files) { file in
                                    localRow(file)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("SwiftPlayer")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddMenu = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityLabel("Add media")
                }
            }
            .confirmationDialog("Add Media", isPresented: $showAddMenu, titleVisibility: .visible) {
                Button("Add Stream") { showAddStream = true }
                Button("Download from URL") { showDownloads = true }
                Button("Local Files") { showLocalFiles = true }
            }
            .confirmationDialog(
                "Delete “\(pendingDeletion?.name ?? "")”?",
                isPresented: deletionPresented,
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { target in
                Button("Delete", role: .destructive) { delete(target) }
                Button("Cancel", role: .cancel) { suppressActivation = false }
            } message: { _ in
                Text("This removes the file from this Apple TV.")
            }
            .sheet(isPresented: $showAddStream) {
                AddStreamView()
            }
            .sheet(isPresented: $showLocalFiles) {
                LocalFilesView(onPlay: onPlay)
            }
            .sheet(isPresented: $showDownloads) {
                DownloadView()
            }
            .onAppear { localLibrary.refresh() }
        }
    }

    /// Bridges the optional target to a Bool binding for `confirmationDialog`.
    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented {
                    pendingDeletion = nil
                    suppressActivation = false
                }
            }
        )
    }

    private func delete(_ target: DeletionTarget) {
        switch target {
        case .stream(let item): library.remove(item)
        case .local(let file): localLibrary.delete(file)
        }
        pendingDeletion = nil
        suppressActivation = false
    }

    private var addSection: some View {
        Section("Add Media") {
            Button {
                showAddStream = true
            } label: {
                Label("Add Stream", systemImage: "link")
            }

            Button {
                showDownloads = true
            } label: {
                Label("Download from URL", systemImage: "arrow.down.circle")
            }

            Button {
                showLocalFiles = true
            } label: {
                Label("Local Files", systemImage: "externaldrive")
            }
        }
    }

    /// A row that plays on tap and offers a delete menu after a 1-second hold.
    private func itemRow(
        target: DeletionTarget,
        play: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button {
            if suppressActivation {
                // The press was a long-press to delete; don't start playback.
                suppressActivation = false
            } else {
                play()
            }
        } label: {
            label()
        }
        .onLongPressGesture(minimumDuration: 1.0) {
            suppressActivation = true
            pendingDeletion = target
        }
    }

    private func streamRow(_ item: MediaItem) -> some View {
        itemRow(target: .stream(item), play: { onPlay(item) }) {
            HStack(spacing: 20) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .frame(width: 150, height: 84)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                    Text(item.urlString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func localRow(_ file: LocalFile) -> some View {
        itemRow(target: .local(file), play: { onPlay(file.mediaItem) }) {
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
            .padding(.vertical, 8)
        }
    }

    private func resumeTime(for file: LocalFile) -> Double {
        PlaybackProgressStore.shared.resumeTime(for: file.url)
    }

    private var emptyState: some View {
        VStack(spacing: 28) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No media yet")
                    .font(.title2)
                Text("Add a stream, download a URL, or send files to this Apple TV.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                Button {
                    showAddStream = true
                } label: {
                    Label("Add Stream", systemImage: "link")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showDownloads = true
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    showLocalFiles = true
                } label: {
                    Label("Local Files", systemImage: "externaldrive")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
