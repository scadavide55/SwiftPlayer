import SwiftUI

/// Independent lifetimes keep navigation and volume feedback from dismissing
/// each other. SwiftUI cancels old timers on repeat input and window closure.
struct PlaybackFeedbackOverlay: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var media: PlayerMediaControls
    @ObservedObject var systemVolume: SystemVolumeController
    @State private var navigationVisible = false
    @State private var volumeVisible = false
    @State private var volumeTrigger: UUID?

    private struct NavigationTrigger: Equatable {
        let identifier: UUID?
        let holding: Bool
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatNavigationTime(model.currentTime))
                Text(formatNavigationFrame(model.currentTime, frameRate: media.videoFrameRate))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Navigation position")
            .accessibilityValue("\(formatNavigationTime(model.currentTime)), \(formatNavigationFrame(model.currentTime, frameRate: media.videoFrameRate))")
            .feedbackBadge()
            .opacity(navigationVisible ? 1 : 0)
            .accessibilityHidden(!navigationVisible)
            Spacer(minLength: 12)
            Label(volumeTitle,
                  systemImage: systemVolume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("System volume feedback")
                .accessibilityValue(systemVolume.canSetVolume ? (systemVolume.isMuted ? "Muted, \(volumePercent) percent" : "\(volumePercent) percent") : "Unavailable")
                .feedbackBadge()
                .opacity(volumeVisible ? 1 : 0)
                .accessibilityHidden(!volumeVisible)
        }
        .padding(.horizontal, 16)
        // Leave the title and window controls unobstructed above the badges.
        .padding(.top, 60)
        .allowsHitTesting(false)
        .task(id: NavigationTrigger(identifier: model.navigationFeedbackIdentifier, holding: model.isFastSeeking)) {
            guard model.navigationFeedbackIdentifier != nil else { navigationVisible = false; return }
            navigationVisible = true
            guard !model.isFastSeeking else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            withAnimation(.easeOut(duration: 0.3)) { navigationVisible = false }
        }
        .onChange(of: systemVolume.adjustmentIdentifier) { volumeTrigger = $0 }
        .onChange(of: systemVolume.volume) { _ in volumeTrigger = UUID() }
        .onChange(of: systemVolume.isMuted) { _ in volumeTrigger = UUID() }
        .task(id: volumeTrigger) {
            guard volumeTrigger != nil else { volumeVisible = false; return }
            volumeVisible = true
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            withAnimation(.easeOut(duration: 0.3)) { volumeVisible = false }
        }
    }

    private var volumeTitle: String {
        guard systemVolume.canSetVolume else { return "Volume unavailable" }
        return systemVolume.isMuted ? "Muted · \(volumePercent)%" : "\(volumePercent)%"
    }

    private var volumePercent: Int { Int((systemVolume.volume * 100).rounded()) }
}

private extension View {
    func feedbackBadge() -> some View {
        self.font(.system(size: 16, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }
}
