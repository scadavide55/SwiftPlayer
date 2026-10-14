import AVKit
import Combine

@MainActor
final class PiPController: NSObject, ObservableObject {
    @Published var isActive: Bool = false
    @Published var isPossible: Bool = false
    
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    
    /// Called by PlayerLayerView when its AVPlayerLayer is ready.
    func attach(to playerLayer: AVPlayerLayer) {
        detach()
        
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }
        
        let newController = AVPictureInPictureController(playerLayer: playerLayer)
        newController?.delegate = self
        controller = newController
        
        // Watch whether PiP is currently available (e.g. video loaded and ready).
        possibleObservation = newController?.observe(
            \.isPictureInPicturePossible,
            options: [.new, .initial]
        ) { [weak self] observedController, _ in
            let value = observedController.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard self?.controller === observedController else { return }
                self?.isPossible = value
            }
        }
    }
    
    func toggle() {
        guard let controller else { return }
        if isActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }
    
    func stop() {
        controller?.stopPictureInPicture()
        isActive = false
    }

    func detach() {
        possibleObservation = nil
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        controller = nil
        isActive = false
        isPossible = false
    }

    deinit {
        controller?.delegate = nil
        controller?.stopPictureInPicture()
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self, self.controller === controller else { return }
            self.isActive = true
        }
    }
    
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self, self.controller === controller else { return }
            self.isActive = false
        }
    }
    
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.controller === controller else { return }
            self.isActive = false
        }
    }
}
