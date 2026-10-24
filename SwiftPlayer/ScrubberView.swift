import SwiftUI

struct ScrubberView: View {
    @Binding var currentTime: Double
    let duration: Double
    let onScrubStart: () -> Void
    let onScrubEnd: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private var expanded: Bool { isHovering || isDragging }

    private func fraction(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = expanded ? 6 : 4
            let filled = geo.size.width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: filled, height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: filled - 6)
                    .opacity(expanded ? 1 : 0)
            }
            .frame(height: 20) // generous hit target, thin visual
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: expanded)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onScrubStart()
                        }
                        currentTime = fraction(for: value.location.x, width: geo.size.width) * duration
                    }
                    .onEnded { value in
                        isDragging = false
                        onScrubEnd(fraction(for: value.location.x, width: geo.size.width) * duration)
                    }
            )
        }
        .frame(height: 20)
    }
}
