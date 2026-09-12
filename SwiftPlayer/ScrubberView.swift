import SwiftUI

struct ScrubberView: View {
    @Binding var currentTime: Double
    let duration: Double
    let onScrubStart: () -> Void
    let onScrubEnd: (Double) -> Void
    
    private var progress: Double {
        guard duration > 0 else { return 0 }
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
            .frame(height: 16) // generous hit target, thin visual
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrubStart()
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        currentTime = fraction * duration
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        onScrubEnd(fraction * duration)
                    }
            )
        }
        .frame(height: 16)
    }
}

