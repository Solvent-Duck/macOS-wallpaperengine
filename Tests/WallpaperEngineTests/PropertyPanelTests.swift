import AppKit
import Foundation
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
        let controller = PropertiesWindowController()
        defer { controller.close() }
        controller.show(title: "Slider layout regression", properties: [property], values: [:], onChange: { _, _ in
            edits += 1
        })
        // List creates its rows lazily: fittingSize alone never evaluates the
        // slider. Display the actual panel and allow its first layout to finish.
        try await Task.sleep(for: .milliseconds(100))
        #expect(NSApp.windows.contains { $0.title == "Properties — Slider layout regression" && $0.isVisible })
        #expect(edits == 0)
        #expect(Double(property.defaultValue) == value)
        #expect(property.min == minimum)
        #expect(property.max == maximum)
    }
}
