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

    private func window(layer: Int, pid: Int32, alpha: Double = 1, _ rect: CGRect) -> [String: Any] {
        [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: rect.dictionaryRepresentation]
    }

    @Test func onlyOtherAppsOpaqueNormalWindowsCover() {
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let list = [
            window(layer: 20, pid: 1220, full),                 // Dock overlay shown while windows are minimized
            window(layer: 0, pid: 9240, alpha: 0, full),       // invisible helper window
            window(layer: 0, pid: 42, full),                   // this app's own window
            window(layer: 0, pid: 9240, CGRect(x: 1, y: 92, width: 697, height: 800)),
        ]
        #expect(OcclusionDetector.coveringRects(in: list, ownPID: 42) == [CGRect(x: 1, y: 92, width: 697, height: 800)])
        #expect(!OcclusionDetector.isCovered(screen, by: OcclusionDetector.coveringRects(in: list, ownPID: 42)))
    }
}
