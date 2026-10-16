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
    @State private var bitmapPreview: SubtitleImageFrame?
    private var isBitmap: Bool { url.pathExtension.lowercased() == "sup" }
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
            if !isBitmap { Picker("Text encoding", selection: $encoding) {
                ForEach(SubtitleEncoding.allCases) { Text($0.title).tag($0) }
            } }
            if loading || previewEncoding != encoding { ProgressView("Reading preview…") }
            else if cueCount == 0 {
                Text(isBitmap ? "No readable image subtitles were found. Choose another file." : "No readable captions were found. Try another encoding or choose another file.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(cueCount) captions · First caption").font(.caption).foregroundStyle(.secondary)
                if let bitmapPreview {
                    Canvas { context, size in
                        for part in bitmapPreview.parts {
                            let r = part.bounds
                            context.draw(Image(decorative: part.image, scale: 1), in: CGRect(x: r.minX / bitmapPreview.canvas.width * size.width,
                                y: r.minY / bitmapPreview.canvas.height * size.height, width: r.width / bitmapPreview.canvas.width * size.width,
                                height: r.height / bitmapPreview.canvas.height * size.height))
                        }
                    }.aspectRatio(bitmapPreview.canvas, contentMode: .fit).frame(height: 120).background(.black)
                } else { ScrollView { Text(preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 90).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text(isBitmap ? "Image subtitles retain their original colors and placement. Font settings do not apply." : "Automatic reads UTF-8 or BOM-marked UTF-16. The selected encoding is remembered with this media file when per-file memory is enabled.")
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
            let bitmapFormat = isBitmap
            let worker = Task.detached(priority: .userInitiated) {
                let cues = parseSubtitles(from: url, encoding: selected)
                let image = try? cues.first?.bitmap?.render()
                return (bitmapFormat && image == nil ? 0 : cues.count, String((cues.first?.text ?? "").prefix(8192)), image)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            cueCount = result.0
            preview = result.1
            bitmapPreview = result.2
            previewEncoding = selected
            loading = false
        }
    }
}
