import XCTest
import AppKit
import SwiftUI
@testable import SwiftPlayer

@MainActor
final class PlayerWindowObserverTests: XCTestCase {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testWindowNotificationsOnlyAffectTheirOwnPlayer() {
        let first = window()
        let other = window()
        defer { first.close(); other.close() }
        let view = PlayerWindowObserver.ObservingView()
        var resigns = 0
        view.onResignKey = { resigns += 1 }
        first.contentView = view
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.post(name: name, object: other)
        }
        XCTAssertEqual(resigns, 0)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: first)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: first)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertEqual(resigns, 1)
        first.contentView = nil
        other.contentView = view
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        XCTAssertEqual(resigns, 1)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        XCTAssertEqual(resigns, 2)
        PlayerWindowObserver.dismantleNSView(view, coordinator: ())
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        XCTAssertEqual(resigns, 2)
        XCTAssertNil(view.onResignKey)
    }

    func testDismantlingWindowObserverReleasesPlaybackCallbacks() {
        let owner = window()
        defer { owner.close() }
        var model: PlayerModel? = PlayerModel()
        weak var weakModel = model
        let view = PlayerWindowObserver.ObservingView()
        view.onResignKey = { [retained = model] in retained?.endFastSeeking() }
        owner.contentView = view
        model = nil
        XCTAssertNotNil(weakModel)
        PlayerWindowObserver.dismantleNSView(view, coordinator: ())
        XCTAssertNil(weakModel)
        XCTAssertNil(view.hitTest(.zero))
    }

    func testContentViewInstallsObserverInItsOwnWindow() async throws {
        let owner = window()
        defer { owner.close() }
        let host = NSHostingView(rootView: ContentView())
        owner.contentView = host
        host.layoutSubtreeIfNeeded()
        func findObserver(_ view: NSView) -> PlayerWindowObserver.ObservingView? {
            if let observer = view as? PlayerWindowObserver.ObservingView { return observer }
            return view.subviews.lazy.compactMap { findObserver($0) }.first
        }
        let deadline = Date().addingTimeInterval(5)
        while findObserver(host) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        let observer = try XCTUnwrap(findObserver(host))
        XCTAssertTrue(observer.window === owner)
        owner.contentView = nil
        XCTAssertNil(observer.window)
    }
}
