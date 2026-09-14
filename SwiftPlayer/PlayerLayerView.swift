import SwiftUI
import AVFoundation
import AppKit

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    
    /// Called once the layer is set up and laid out, so we can hand it to a PiP controller.
    var onLayerReady: ((AVPlayerLayer) -> Void)?
    private var didNotifyLayerReady = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        
        if !didNotifyLayerReady, let onLayerReady {
            didNotifyLayerReady = true
            onLayerReady(playerLayer)
        }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var onLayerReady: ((AVPlayerLayer) -> Void)?
    
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        view.onLayerReady = onLayerReady
        return view
    }
    
    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.onLayerReady = onLayerReady
    }
}
