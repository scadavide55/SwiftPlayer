import SwiftUI
import AVFoundation

struct ScrubberView: View {
    @Binding var currentTime: Double
    let duration: Double
    var asset: AVAsset? = nil
    @StateObject private var preview = SeekPreviewController()
    @State private var previewPosition: CGFloat?
    @State private var previewTarget: Double = 0
    let onScrubStart: () -> Void
    let onScrubEnd: (Double) -> Void
    
    private var progress: Double {
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.4))
                    .frame(height: 4)
                
                Capsule()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * progress, height: 4)
            }
            .overlay(alignment: .bottomLeading) {
                if let position = previewPosition {
                    VStack(spacing: 4) {
                        if let image = preview.image {
                            Image(decorative: image, scale: 2).resizable().scaledToFit()
                                .frame(width: 160, height: 90)
                        } else if preview.isLoading {
                            ProgressView().controlSize(.small).frame(width: 160, height: 90)
                        }
                        Text(formatTime(preview.imageTime ?? previewTarget))
                            .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    }
                    .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .offset(x: min(max(position - 86, -40), max(-40, geo.size.width - 132)), y: -24)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): showPreview(at: point.x, width: geo.size.width)
                case .ended: hidePreview()
                }
            }
            .frame(height: 16) // generous hit target, thin visual
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geo.size.width > 0, duration.isFinite, duration > 0 else { return }
                        onScrubStart()
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        currentTime = fraction * duration
                        showPreview(at: value.location.x, width: geo.size.width)
                    }
                    .onEnded { value in
                        guard geo.size.width > 0, duration.isFinite, duration > 0 else { return }
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        onScrubEnd(fraction * duration)
                        hidePreview()
                    }
            )
        }
        .frame(height: 16)
        .onAppear { preview.attach(asset) }
        .onChange(of: asset.map { ObjectIdentifier($0) }) { _ in preview.attach(asset); hidePreview() }
        .onDisappear { preview.detach() }
    }

    private func showPreview(at x: CGFloat, width: CGFloat) {
        guard width > 0, duration.isFinite, duration > 0 else { return }
        previewPosition = min(max(x, 0), width)
        previewTarget = Double(min(max(x / width, 0), 1)) * duration
        preview.request(time: previewTarget, duration: duration)
    }
    private func hidePreview() { previewPosition = nil; preview.hide() }
}

