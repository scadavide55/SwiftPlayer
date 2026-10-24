import SwiftUI

struct AddStreamView: View {
    @EnvironmentObject private var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlString = ""

    private var isValidURL: Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Name")
                        .font(.headline)
                    TextField("Optional", text: $name)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Stream URL")
                        .font(.headline)
                    TextField("https://example.com/video.mp4", text: $urlString)
                }

                Spacer()

                Button {
                    library.add(name: name, urlString: urlString)
                    dismiss()
                } label: {
                    Text("Save")
                        .frame(maxWidth: 480)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValidURL)
            }
            .padding(80)
            .navigationTitle("Add Stream")
        }
    }
}
