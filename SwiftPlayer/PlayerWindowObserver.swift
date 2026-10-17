import SwiftUI
import AppKit

/// Associates playback controls with the window that actually contains them.
struct PlayerWindowObserver: NSViewRepresentable {
    let onResignKey: () -> Void
    var onWindowChanged: (NSWindow?) -> Void = { _ in }

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onResignKey = onResignKey
        view.onWindowChanged = onWindowChanged
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onResignKey = onResignKey
        view.onWindowChanged = onWindowChanged
    }

    static func dismantleNSView(_ view: ObservingView, coordinator: ()) {
        view.invalidate()
        view.onResignKey = nil
        let windowChanged = view.onWindowChanged
        Task { @MainActor in windowChanged?(nil) }
        view.onWindowChanged = nil
    }

    final class ObservingView: NSView {
        var onResignKey: (() -> Void)?
        var onWindowChanged: ((NSWindow?) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            invalidate()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onWindowChanged?(self.window)
            }
            guard window != nil else { return }
            // Fullscreen state belongs to PlayerWindowControls; this bridge
            // only forwards focus loss and changes of the containing window.
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          notification.object as? NSWindow === window else { return }
                    self.onResignKey?()
                }
            })
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
