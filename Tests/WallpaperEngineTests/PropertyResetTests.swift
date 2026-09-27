import Foundation
import Testing
@testable import WallpaperEngine

@MainActor
struct PropertyResetTests {
    private var properties: [WallpaperProperty] {
        WallpaperProperty.parse(from: Data(#"{"properties":{"speed":{"type":"slider","value":1}}}"#.utf8))
    }

    @Test func successfulResetRunsOnceAndPublishesDefaultsWithoutIndividualEdits() {
        var resets = 0
        var edits = 0
        let store = PropertyStore(properties: properties, values: ["speed": "4"], onChange: { _, _ in edits += 1 }, onReset: {
            resets += 1
            return true
        })
        store.resetToDefaults()
        #expect(resets == 1)
        #expect(edits == 0)
        #expect(store.values["speed"] == "1")
    }

    @Test func failedResetPreservesTheDisplayedValues() {
        let store = PropertyStore(properties: properties, values: ["speed": "4"], onChange: { _, _ in Issue.record("Unexpected individual edit") }, onReset: { false })
        store.resetToDefaults()
        #expect(store.values["speed"] == "4")
    }

    @Test func storageResetRemainsAvailableWithoutAuthoredProperties() {
        var resets = 0
        let store = PropertyStore(properties: [], values: [:], onChange: { _, _ in }, onReset: { resets += 1; return true })
        store.resetToDefaults()
        #expect(resets == 1)
    }
}
