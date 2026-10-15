import SwiftUI
import AppKit

/// Associates playback controls with the window that actually contains them.
struct PlayerWindowObserver: NSViewRepresentable {
    let onFullScreenChanged: (Bool) -> Void
    let onResignKey: () -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onFullScreenChanged = onFullScreenChanged
        view.onResignKey = onResignKey
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onFullScreenChanged = onFullScreenChanged
        view.onResignKey = onResignKey
    }

    static func dismantleNSView(_ view: ObservingView, coordinator: ()) {
        view.invalidate()
        view.onFullScreenChanged = nil
        view.onResignKey = nil
    }

    final class ObservingView: NSView {
        var onFullScreenChanged: ((Bool) -> Void)?
        var onResignKey: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            invalidate()
            guard window != nil else { return }
            // Publish initial state after SwiftUI finishes attaching its native view.
            Task { @MainActor [weak self] in
                guard let self, !self.observers.isEmpty, let window = self.window else { return }
                self.onFullScreenChanged?(window.styleMask.contains(.fullScreen))
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window,
                              notification.object as? NSWindow === window else { return }
                        switch notification.name {
                        case NSWindow.didEnterFullScreenNotification: self.onFullScreenChanged?(true)
                        case NSWindow.didExitFullScreenNotification: self.onFullScreenChanged?(false)
                        default: self.onResignKey?()
                        }
                    }
                })
            }
        }

        func invalidate() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
