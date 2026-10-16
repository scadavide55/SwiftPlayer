import SwiftUI
import AVFoundation
import AppKit

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    
    /// Called once the layer is set up and laid out, so we can hand it to a PiP controller.
    var onLayerReady: ((AVPlayerLayer) -> Void)?
    private var didNotifyLayerReady = false
    var display = VideoDisplayOptions() { didSet { needsLayout = true } }
    var onDoubleClick: (() -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .leftMouseDown, event.clickCount == 2, modifiers.isEmpty {
            onDoubleClick?()
        } else { super.mouseDown(with: event) }
    }
    
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.videoGravity = display.aspect == .original ? (display.fit == .fit ? .resizeAspect : .resizeAspectFill) : .resize
        playerLayer.frame = display.frame(in: bounds)
        CATransaction.commit()
        
        if !didNotifyLayerReady, let onLayerReady {
            didNotifyLayerReady = true
            onLayerReady(playerLayer)
        }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var display = VideoDisplayOptions()
    var onDoubleClick: (() -> Void)?
    var onLayerReady: ((AVPlayerLayer) -> Void)?
    
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        view.display = display
        view.onDoubleClick = onDoubleClick
        view.onLayerReady = onLayerReady
        return view
    }
    
    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.onLayerReady = onLayerReady
        nsView.onDoubleClick = onDoubleClick
        if nsView.display != display { nsView.display = display }
    }

    static func dismantleNSView(_ nsView: PlayerLayerNSView, coordinator: ()) {
        nsView.onLayerReady = nil
        nsView.onDoubleClick = nil
        nsView.playerLayer.player = nil
    }
}
