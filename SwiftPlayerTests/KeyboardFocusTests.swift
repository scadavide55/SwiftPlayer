import XCTest
import AppKit
@testable import SwiftPlayer

@MainActor
final class KeyboardFocusTests: XCTestCase {
    private func event(_ code: UInt16, window: NSWindow, up: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    func testPlayerArrowsWorkAfterSliderTakesKeyboardFocusAndStopAfterDismantle() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        window.contentView = root
        let catcher = KeyEventHandlingView.KeyCatcherView()
        root.addSubview(catcher)
        var directions: [Int] = [], volumes: [Int] = []
        catcher.onArrowDown = { directions.append($0) }
        catcher.onVolumeUp = { volumes.append(1) }
        catcher.onVolumeDown = { volumes.append(-1) }
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        root.addSubview(slider)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(slider))
        XCTAssertTrue(window.firstResponder === slider)
        for code: UInt16 in [123, 124, 126, 125] { NSApp.sendEvent(try event(code, window: window)) }
        XCTAssertEqual(directions, [-1, 1])
        XCTAssertEqual(volumes, [1, -1])
        KeyEventHandlingView.dismantleNSView(catcher, coordinator: ())
        NSApp.sendEvent(try event(124, window: window))
        XCTAssertEqual(directions, [-1, 1])
    }

    func testTextEditingKeepsItsOwnArrowsAndCannotLeaveAHeldKeyRunning() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView()
        window.contentView = root
        let catcher = KeyEventHandlingView.KeyCatcherView()
        root.addSubview(catcher)
        var starts = 0, ends = 0
        catcher.onArrowDown = { _ in starts += 1 }
        catcher.onArrowUp = { ends += 1 }
        let slider = NSSlider()
        root.addSubview(slider)
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(slider)
        NSApp.sendEvent(try event(123, window: window))
        XCTAssertEqual(starts, 1)
        let editor = NSTextView()
        editor.isEditable = true
        root.addSubview(editor)
        _ = window.makeFirstResponder(editor)
        let beforeRelease = ends
        NSApp.sendEvent(try event(123, window: window, up: true))
        XCTAssertEqual(ends, beforeRelease + 1)
        let previous = starts
        NSApp.sendEvent(try event(124, window: window))
        XCTAssertEqual(starts, previous)
        KeyEventHandlingView.dismantleNSView(catcher, coordinator: ())
    }
}
