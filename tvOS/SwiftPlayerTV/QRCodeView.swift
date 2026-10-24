import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a QR code for the upload address so a phone can connect without
/// anyone typing an IP address.
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 200

    var body: some View {
        Group {
            if let image = Self.makeQRCode(from: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: size / 4))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .accessibilityLabel("Upload address QR code")
    }

    private static func makeQRCode(from text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
