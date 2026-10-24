import SwiftUI
import AVFoundation
import UIKit

/// Generates and caches still frames for local videos so lists can show a
/// preview image instead of a generic icon.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var cache: [URL: UIImage] = [:]

    func image(for url: URL) async -> UIImage? {
        if let cached = cache[url] {
            return cached
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let time = CMTime(seconds: 3, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }

        let image = UIImage(cgImage: result.image)
        cache[url] = image
        return image
    }
}

/// A small 16:9 thumbnail with a placeholder that resolves asynchronously.
struct AsyncThumbnailView: View {
    let url: URL
    var width: CGFloat = 160

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "film")
                            .font(.system(size: width / 5))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            image = await ThumbnailProvider.shared.image(for: url)
        }
    }
}
