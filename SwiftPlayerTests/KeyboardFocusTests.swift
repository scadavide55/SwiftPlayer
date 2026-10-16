import XCTest
import AppKit
@testable import SwiftPlayer

@MainActor
final class KeyboardFocusTests: XCTestCase {
    func testDoublePressSelectsShuttleWithoutChangingSingleHoldsShiftOrNativeRepeat() throws {
        let view = KeyEventHandlingView.KeyCatcherView()
        defer { KeyEventHandlingView.dismantleNSView(view, coordinator: ()) }
        var modes: [ArrowSeekMode] = []
        view.onArrowDown = { _, mode in modes.append(mode) }
        func send(_ code: UInt16, _ time: TimeInterval, up: Bool = false,
                  repeatKey: Bool = false, flags: NSEvent.ModifierFlags = []) throws {
            view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: up ? .keyUp : .keyDown,
                location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)))
        }
        for (code, start): (UInt16, TimeInterval) in [(123, 0), (124, 3)] {
            try send(code, start)
            try send(code, start + 0.05, up: true)
            try send(code, start + 0.1)
            try send(code, start + 0.7, repeatKey: true)
            try send(code, start + 0.8, up: true)
        }
        XCTAssertEqual(modes, [.jump, .shuttle, .jump, .shuttle])
        try send(124, 6)
        try send(124, 6.05, up: true)
        try send(124, 6.1, flags: .shift)
        XCTAssertEqual(modes.suffix(2), [.jump, .largeJump])
        try send(124, 6.2, up: true)
        try send(124, 8)
        XCTAssertEqual(modes.last, .jump, "An old tap must not activate shuttle playback.")
    }

    func testShiftRoutesSixTimesTheNormalJump() throws {
        let view = KeyEventHandlingView.KeyCatcherView()
        defer { KeyEventHandlingView.dismantleNSView(view, coordinator: ()) }
        var jumps: [Int] = []
        view.onArrowDown = { direction, mode in jumps.append(direction * (mode == .largeJump ? 30 : 5)) }
        for (code, flags): (UInt16, NSEvent.ModifierFlags) in [(123, []), (124, []), (123, .shift), (124, .shift)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        XCTAssertEqual(jumps, [-5, 5, -30, 30])
    }

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
        catcher.onArrowDown = { direction, _ in directions.append(direction) }
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
        catcher.onArrowDown = { _, _ in starts += 1 }
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
