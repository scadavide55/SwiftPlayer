import XCTest
import AppKit
@testable import SwiftPlayer

@MainActor
final class VideoDoubleClickTests: XCTestCase {
    private func click(_ count: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }

    func testOnlyAnUnmodifiedDoubleClickTriggersFullscreen() throws {
        let view = PlayerLayerNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        var requests = 0
        view.onDoubleClick = { requests += 1 }
        view.mouseDown(with: try click(1))
        view.mouseDown(with: try click(2, modifiers: .command))
        view.mouseDown(with: try click(3))
        XCTAssertEqual(requests, 0)
        view.mouseDown(with: try click(2))
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testControlsRemainTheHitTargetAndDismantlingReleasesTheCallback() {
        let view = PlayerLayerNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let button = NSButton(frame: CGRect(x: 10, y: 10, width: 100, height: 30))
        view.addSubview(button)
        XCTAssertTrue(view.hitTest(CGPoint(x: 20, y: 20)) === button)
        var owner: NSObject? = NSObject()
        weak var released = owner
        view.onDoubleClick = { [retained = owner] in _ = retained }
        owner = nil
        XCTAssertNotNil(released)
        PlayerLayerView.dismantleNSView(view, coordinator: ())
        XCTAssertNil(released)
        XCTAssertNil(view.onDoubleClick)
    }
}
