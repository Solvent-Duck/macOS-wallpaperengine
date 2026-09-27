import AppKit
@testable import WallpaperEngine
import Testing

struct CursorTrackerTests {
    @Test func eachDisplayUsesItsOwnOriginAndDimensions() {
        let point = NSPoint(x: -500, y: 350)
        let leftDisplay = NSRect(x: -1000, y: 100, width: 1000, height: 500)
        let primaryDisplay = NSRect(x: 0, y: 0, width: 2000, height: 1000)
        #expect(CursorTracker.normalize(point, in: leftDisplay) == NSPoint(x: 0.5, y: 0.5))
        #expect(CursorTracker.normalize(point, in: primaryDisplay) == NSPoint(x: -0.25, y: 0.35))
        #expect(CursorTracker.normalize(point, in: .zero) == .zero)
    }
}

extension CursorTrackerTests {
    @Test @MainActor func deliveredEventsUseTheirOwnCoordinatesAndButtonTransitions() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -300, y: 120, width: 200, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let point = NSPoint(x: 25, y: 40)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let sample = CursorTracker.inputSample(for: down, previousLeftDown: false)
        #expect(sample.position == window.convertPoint(toScreen: point))
        #expect(sample.leftDown)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let released = CursorTracker.inputSample(for: up, previousLeftDown: true)
        #expect(released.position == point)
        #expect(!released.leftDown)
        let other = try #require(NSEvent.mouseEvent(with: .rightMouseDragged, location: point, modifierFlags: [], timestamp: 3, windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        #expect(CursorTracker.inputSample(for: other, previousLeftDown: true).leftDown)
    }
}
