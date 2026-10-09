import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WallpaperEngine

@MainActor
@Suite(.serialized)
struct PropertyPanelTests {
    @Test(arguments: [(1900.0, -100.0, 1232.0), (-10.0, 10.0, 3.0)])
    func sliderEndpointsCanBeReversedOrAscending(minimum: Double, maximum: Double, value: Double) async throws {
        try await displaySlider(minimum: minimum, maximum: maximum, value: value)
    }

    @Test func fixedValueSliderDisplaysWithoutEditingItsValue() async throws {
        try await displaySlider(minimum: 100, maximum: 100, value: 100)
    }

    private func displaySlider(minimum: Double, maximum: Double, value: Double) async throws {
        _ = NSApplication.shared
        let data = try JSONSerialization.data(withJSONObject: ["general": ["properties": [
            "position": ["type": "slider", "min": minimum, "max": maximum, "value": value]
        ]]])
        let property = try #require(WallpaperProperty.parse(from: data).first)
        var edits = 0
        let store = PropertyStore(properties: [property], values: [:], onChange: { _, _ in edits += 1 })
        let window = NSWindow(
            contentRect: NSRect(x: -3000, y: 0, width: 420, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Slider layout regression"
        window.contentViewController = NSHostingController(rootView: Form { PropertySections(store: store) }.formStyle(.grouped))
        defer { window.close() }
        window.orderFrontRegardless()
        // Forms create their rows lazily: fittingSize alone never evaluates the
        // slider. Display the actual form and allow its first layout to finish.
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.isVisible)
        #expect(edits == 0)
        #expect(Double(property.defaultValue) == value)
        #expect(property.min == minimum)
        #expect(property.max == maximum)
    }
}
