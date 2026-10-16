import SwiftUI

struct SubtitleImportRequest: Identifiable {
    let id = UUID()
    let url: URL
}

struct SubtitleImportView: View {
    let url: URL
    let load: (SubtitleEncoding) -> Void
    @State private var encoding: SubtitleEncoding
    @State private var preview = ""
    @State private var cueCount = 0
    @State private var previewEncoding: SubtitleEncoding?
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    init(url: URL, encoding: SubtitleEncoding, load: @escaping (SubtitleEncoding) -> Void) {
        self.url = url
        self.load = load
        _encoding = State(initialValue: encoding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Load Subtitles").font(.title2)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Picker("Text encoding", selection: $encoding) {
                ForEach(SubtitleEncoding.allCases) { Text($0.title).tag($0) }
            }
            if loading || previewEncoding != encoding { ProgressView("Reading preview…") }
            else if cueCount == 0 {
                Text("No readable captions were found. Try another encoding or choose another file.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(cueCount) captions · First caption").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 90).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Automatic reads UTF-8 or BOM-marked UTF-16. The selected encoding is remembered with this media file when per-file memory is enabled.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Load") { load(encoding); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(loading || previewEncoding != encoding || cueCount == 0)
            }
        }
        .padding(24).frame(width: 450)
        .task(id: encoding) {
            loading = true
            let selected = encoding
            let worker = Task.detached(priority: .userInitiated) {
                let cues = parseSubtitles(from: url, encoding: selected)
                return (cues.count, String((cues.first?.text ?? "").prefix(8192)))
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            cueCount = result.0
            preview = result.1
            previewEncoding = selected
            loading = false
        }
    }
}
