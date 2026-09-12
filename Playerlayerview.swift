import SwiftUI
import AVFoundation
import AppKit

/// A bare NSView backed by an AVPlayerLayer.
/// We deliberately avoid AVPlayerView / AVKit's built-in controls so the
/// only UI on screen is exactly what we draw ourselves.
final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    
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
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }
    
    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

