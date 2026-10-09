import CoreGraphics
import Testing
@testable import WallpaperEngine

struct OcclusionCoverageTests {
    private let screen = CGRect(x: 0, y: 33, width: 1512, height: 949)

    @Test func maximizedWindowCoversTheScreen() {
        #expect(OcclusionDetector.isCovered(screen, by: [CGRect(x: 0, y: 33, width: 1512, height: 949)]))
    }

    @Test func tiledWindowsTogetherCoverTheScreen() {
        let left = CGRect(x: 0, y: 33, width: 756, height: 949)
        let right = CGRect(x: 756, y: 33, width: 756, height: 949)
        #expect(OcclusionDetector.isCovered(screen, by: [left, right]))
    }

    @Test func visibleDesktopAreaKeepsRendering() {
        #expect(!OcclusionDetector.isCovered(screen, by: [CGRect(x: 0, y: 33, width: 1200, height: 949)]))
        #expect(!OcclusionDetector.isCovered(screen, by: [CGRect(x: 100, y: 100, width: 800, height: 600)]))
        #expect(!OcclusionDetector.isCovered(screen, by: []))
    }

    @Test func windowsOnAnotherScreenDoNotCount() {
        #expect(!OcclusionDetector.isCovered(screen, by: [CGRect(x: 1512, y: 0, width: 1920, height: 1080)]))
    }
}
