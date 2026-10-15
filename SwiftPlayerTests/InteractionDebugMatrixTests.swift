import XCTest
import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import SwiftPlayer

@MainActor
final class InteractionDebugMatrixTests: DebugMatrixTestCase {
    private func key(_ code: UInt16, repeatKey: Bool = false, flags: NSEvent.ModifierFlags = [], up: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeatKey, keyCode: code))
    }

    func test100WindowAndInteractionRounds() async throws {
        let names = ["space-repeat", "arrow-routing", "modified-key-up", "volume-keys", "shortcut-modifiers",
                     "focus-loss", "mouse-tracking", "two-window-routing", "file-url-provider", "hosted-controls-layout"]
        for family in 0..<10 {
            for variant in 0..<10 {
                try await round("interaction", family * 10 + variant, "\(names[family]); input=\(variant)") {
                    let view = KeyEventHandlingView.KeyCatcherView()
                    defer { KeyEventHandlingView.dismantleNSView(view, coordinator: ()) }
                    var plays = 0
                    var directions: [Int] = []
                    var releases = 0
                    view.onSpace = { plays += 1 }
                    view.onArrowDown = { directions.append($0) }
                    view.onArrowUp = { releases += 1 }
                    switch family {
                    case 0:
                        view.keyDown(with: try key(49))
                        for _ in 0...variant { view.keyDown(with: try key(49, repeatKey: true)) }
                        XCTAssertEqual(plays, 1)
                    case 1:
                        for index in 0...variant { view.keyDown(with: try key(index % 2 == 0 ? 123 : 124, repeatKey: index > 0)) }
                        XCTAssertEqual(directions, (0...variant).map { $0 % 2 == 0 ? -1 : 1 })
                        view.keyUp(with: try key(variant % 2 == 0 ? 123 : 124, up: true))
                        XCTAssertEqual(releases, 1)
                    case 2:
                        let flags: [NSEvent.ModifierFlags] = [[], .shift, .command, .control, .option, [.command, .shift],
                            [.control, .option], .capsLock, [.shift, .option], [.command, .control, .option]]
                        view.keyUp(with: try key(variant % 2 == 0 ? 123 : 124, flags: flags[variant], up: true))
                        XCTAssertEqual(releases, 1)
                    case 3:
                        let model = PlayerModel()
                        model.volume = Float(variant) / 10
                        view.onVolumeUp = { model.volumeUp() }
                        view.onVolumeDown = { model.volumeDown() }
                        view.keyDown(with: try key(126))
                        XCTAssertEqual(model.volume, min(Float(variant) / 10 + 0.05, 1), accuracy: 0.001)
                        view.keyDown(with: try key(125))
                        XCTAssertEqual(model.volume, Float(variant) / 10, accuracy: 0.001)
                    case 4:
                        let flags: [NSEvent.ModifierFlags] = [.command, .control, .option, [.command, .shift], [.control, .shift],
                            [.option, .shift], [.command, .control], [.command, .option], [.control, .option], [.command, .control, .option]]
                        view.keyDown(with: try key(49, flags: flags[variant]))
                        view.keyDown(with: try key(123, flags: flags[variant]))
                        XCTAssertEqual(plays, 0)
                        XCTAssertTrue(directions.isEmpty)
                    case 5:
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480 + variant * 16, height: 320),
                            styleMask: [.titled], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        defer { window.close() }
                        window.contentView = view
                        _ = window.makeFirstResponder(view)
                        releases = 0
                        _ = window.makeFirstResponder(window)
                        XCTAssertEqual(releases, 1)
                    case 6:
                        let tracker = MouseActivityTracker.TrackingNSView(frame: NSRect(x: 0, y: 0, width: 100 + variant * 10, height: 50))
                        var activities = 0
                        tracker.onActivity = { activities += 1 }
                        tracker.updateTrackingAreas()
                        tracker.updateTrackingAreas()
                        XCTAssertEqual(tracker.trackingAreas.count, 1)
                        XCTAssertNil(tracker.hitTest(NSPoint(x: variant, y: variant)))
                        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                        for _ in 0...variant { tracker.mouseMoved(with: event) }
                        XCTAssertEqual(activities, variant + 1)
                        MouseActivityTracker.dismantleNSView(tracker, coordinator: ())
                        tracker.mouseMoved(with: event)
                        XCTAssertEqual(activities, variant + 1)
                    case 7:
                        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
                        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480 + variant * 10, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
                        first.isReleasedWhenClosed = false
                        second.isReleasedWhenClosed = false
                        defer { first.close(); second.close() }
                        let other = KeyEventHandlingView.KeyCatcherView()
                        var otherPlays = 0
                        other.onSpace = { otherPlays += 1 }
                        first.contentView = view
                        second.contentView = other
                        _ = first.makeFirstResponder(view)
                        _ = second.makeFirstResponder(other)
                        for _ in 0...variant { first.sendEvent(try key(49)) }
                        XCTAssertEqual(plays, variant + 1)
                        XCTAssertEqual(otherPlays, 0)
                        second.sendEvent(try key(49))
                        XCTAssertEqual(otherPlays, 1)
                        let observer = PlayerWindowObserver.ObservingView()
                        var fullscreen: [Bool] = []
                        var resigns = 0
                        observer.onFullScreenChanged = { fullscreen.append($0) }
                        observer.onResignKey = { resigns += 1 }
                        view.addSubview(observer)
                        fullscreen.removeAll()
                        for _ in 0...variant {
                            NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: second)
                            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: second)
                        }
                        XCTAssertTrue(fullscreen.isEmpty)
                        XCTAssertEqual(resigns, 0)
                        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: first)
                        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: first)
                        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
                        XCTAssertEqual(fullscreen, [true, false])
                        XCTAssertEqual(resigns, 1)
                        PlayerWindowObserver.dismantleNSView(observer, coordinator: ())
                        KeyEventHandlingView.dismantleNSView(other, coordinator: ())
                    case 8:
                        let ext = supportedExtensions[variant % supportedExtensions.count]
                        let url = directory.appendingPathComponent("drop-\(variant).\(ext)")
                        let provider = variant % 2 == 0
                            ? NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
                            : NSItemProvider(item: url.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier)
                        let result: URL? = await withCheckedContinuation { continuation in
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                let decoded = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                continuation.resume(returning: decoded)
                            }
                        }
                        XCTAssertEqual(result, url)
                    default:
                        var model: PlayerModel? = PlayerModel()
                        let released: @MainActor @Sendable () -> Bool = { [weak model] in model == nil }
                        model?.duration = Double(variant + 1) * 60
                        model?.currentTime = Double(variant) * 30
                        var host: NSHostingView<ControlsOverlay>? = NSHostingView(rootView: ControlsOverlay(model: try XCTUnwrap(model)))
                        host?.frame = NSRect(x: 0, y: 0, width: 480 + variant * 100, height: 80)
                        host?.layoutSubtreeIfNeeded()
                        XCTAssertTrue(try XCTUnwrap(host).fittingSize.height.isFinite)
                        XCTAssertGreaterThan(try XCTUnwrap(host).fittingSize.height, 0)
                        model = nil
                        host = nil
                        try await waitUntilCondition(released)
                    }
                }
            }
        }
    }
}
