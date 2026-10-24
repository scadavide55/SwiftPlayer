import SwiftUI

/// Sheet for downloading remote media straight to the Apple TV.
struct DownloadView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""

    private var isValid: Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Media URL")
                        .font(.headline)
                    TextField("https://example.com/video.mp4", text: $urlString)
                }

                Button {
                    downloads.start(urlString: urlString)
                    urlString = ""
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)

                if downloads.items.isEmpty {
                    Spacer()
                    Text("Downloads appear here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    List {
                        ForEach(downloads.items) { item in
                            row(item)
                        }
                    }
                }
            }
            .padding(60)
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: DownloadManager.Item) -> some View {
        HStack(spacing: 16) {
            stateIcon(item.state)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)

                switch item.state {
                case .downloading:
                    ProgressView(value: item.progress)
                        .frame(maxWidth: 420)
                case .finished:
                    Text("Saved to this Apple TV")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            switch item.state {
            case .downloading:
                Button("Cancel", role: .destructive) {
                    downloads.cancel(item)
                }
            case .finished, .failed:
                Button("Remove", role: .destructive) {
                    downloads.remove(item)
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stateIcon(_ state: DownloadManager.Item.State) -> some View {
        switch state {
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.red)
        }
    }
}
