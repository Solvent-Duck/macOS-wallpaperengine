import AppKit
import AVFoundation
import CoreVideo
import Testing
@testable import WallpaperEngine

@MainActor
@Suite(.serialized)
struct VideoPlaybackTests {
    @Test func uninterruptedPlaybackCompletesTwoLoops() async throws {
        let root = try VideoPlaybackProbe.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("colors.mov")
        try await VideoPlaybackProbe.writeMovie(to: movie)
        let probe = try VideoPlaybackProbe(url: movie)
        defer { probe.close() }
        probe.renderer.play()
        try await probe.waitUntilReady()
        var item = try #require(probe.player.currentItem)
        var loops = 0
        try await VideoPlaybackProbe.waitFor {
            if let current = probe.player.currentItem, current !== item {
                item = current
                loops += 1
            }
            return loops >= 2 && probe.player.currentTime().seconds > 0.1
        }
        #expect(probe.player.rate > 0)
        #expect(probe.layer.isReadyForDisplay)
    }

    @Test func playbackSettingsControlGainSpeedAndScaling() async throws {
        let root = try VideoPlaybackProbe.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("colors.mov")
        try await VideoPlaybackProbe.writeMovie(to: movie)
        let probe = try VideoPlaybackProbe(url: movie)
        defer { probe.close() }
        #expect(probe.layer.videoGravity == .resizeAspectFill)

        probe.renderer.applyPlayback(PlaybackSettings(volume: 0.25, rate: 1.5, scaling: .fit))
        probe.renderer.play()
        try await probe.waitUntilReady()
        try await VideoPlaybackProbe.waitFor { probe.player.rate > 0 }
        #expect(probe.player.volume == 0.25)
        #expect(probe.player.rate == 1.5)
        #expect(probe.layer.videoGravity == .resizeAspect)

        // Changing speed while playing retimes immediately; pause/resume keeps it.
        probe.renderer.applyPlayback(PlaybackSettings(volume: 1, rate: 0.5, scaling: .stretch))
        #expect(probe.player.rate == 0.5)
        probe.renderer.pause()
        probe.renderer.play()
        #expect(probe.player.rate == 0.5)
        #expect(probe.layer.videoGravity == .resize)
    }

    @Test func actualPlayerOutputsFramesPausesResumesAndLoops() async throws {
        let root = try VideoPlaybackProbe.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("colors.mov")
        try await VideoPlaybackProbe.writeMovie(to: movie)
        let probe = try VideoPlaybackProbe(url: movie)
        defer { probe.close() }
        #expect(probe.renderer.supportsAudio)
        #expect(probe.renderer.isMuted)
        probe.renderer.play()
        try await probe.waitUntilReady()
        #expect(try await probe.color(at: 0.2) == "red")
        #expect(try await probe.color(at: 1.2) == "blue")

        await probe.player.seek(to: CMTime(seconds: 0.2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        probe.renderer.play()
        try await VideoPlaybackProbe.waitFor { probe.player.currentTime().seconds > 0.35 }
        probe.renderer.pause()
        let paused = probe.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(probe.player.currentTime().seconds - paused) < 0.03)
        probe.renderer.play()
        try await VideoPlaybackProbe.waitFor { probe.player.currentTime().seconds > paused + 0.1 }

        let beforeLoop = try #require(probe.player.currentItem)
        await probe.player.seek(to: CMTime(seconds: 1.8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await VideoPlaybackProbe.waitFor {
            probe.player.currentItem !== beforeLoop && probe.player.currentTime().seconds > 0.05
        }
        #expect(probe.player.rate > 0)
        #expect(try await probe.color(at: 0.2) == "red")
    }

    @Test func stopReleasesQueuedMediaAndReplacementHasIndependentPlayback() async throws {
        let root = try VideoPlaybackProbe.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("colors.mov")
        try await VideoPlaybackProbe.writeMovie(to: movie)
        let old = try VideoPlaybackProbe(url: movie)
        defer { old.close() }
        old.renderer.play()
        try await old.waitUntilReady()
        old.renderer.stop()
        #expect(old.player.rate == 0)
        #expect(old.player.items().isEmpty)
        #expect(old.layer.player == nil)
        #expect(old.layer.superlayer == nil)
        old.renderer.stop() // repeated teardown is harmless

        let replacement = try VideoPlaybackProbe(url: movie)
        defer { replacement.close() }
        replacement.renderer.play()
        try await replacement.waitUntilReady()
        #expect(try await replacement.color(at: 0.2) == "red")
        #expect(replacement.renderer.isMuted)
        // This fixture has no audio track, so toggling tests state without sound.
        replacement.renderer.isMuted = false
        #expect(!replacement.player.isMuted)
        #expect(old.player.isMuted)
        replacement.renderer.isMuted = true
        replacement.renderer.view.setFrameSize(NSSize(width: 180, height: 320))
        replacement.renderer.view.needsLayout = true
        replacement.renderer.view.layoutSubtreeIfNeeded()
        #expect(replacement.layer.frame == replacement.renderer.view.bounds)
        #expect(replacement.layer.videoGravity == .resizeAspectFill)
    }

    @Test func stoppingBeforeReadinessDoesNotRepopulateTheQueue() async throws {
        let root = try VideoPlaybackProbe.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("colors.mov")
        try await VideoPlaybackProbe.writeMovie(to: movie)
        let probe = try VideoPlaybackProbe(url: movie)
        defer { probe.close() }
        probe.renderer.play()
        probe.renderer.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(probe.player.items().isEmpty)
        #expect(probe.layer.player == nil)
        #expect(probe.player.rate == 0)
    }
}

/// Lead-only playback helper: the production renderer owns the queue and layer.
/// Frames are read from that queue's current item, not AVAssetImageGenerator.
@MainActor
final class VideoPlaybackProbe {
    let renderer: VideoRenderer
    let layer: AVPlayerLayer
    let player: AVQueuePlayer
    private let window: NSWindow

    init(url: URL) throws {
        renderer = VideoRenderer(fileURL: url)
        layer = try #require(renderer.view.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        player = try #require(layer.player as? AVQueuePlayer)
        window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 180),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.view
        window.orderBack(nil)
        renderer.view.needsLayout = true
        renderer.view.layoutSubtreeIfNeeded()
    }

    func close() {
        renderer.stop()
        window.contentView = nil
        window.close()
    }

    func waitUntilReady() async throws {
        try await Self.waitFor {
            self.player.status == .readyToPlay && self.layer.isReadyForDisplay
                && self.player.currentItem?.status == .readyToPlay
        }
    }

    func frame(at seconds: Double) async throws -> CVPixelBuffer {
        renderer.pause()
        let item = try #require(player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        defer { item.remove(output) }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let sought = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        try #require(sought)
        var pixel: CVPixelBuffer?
        try await Self.waitFor {
            pixel = output.copyPixelBuffer(forItemTime: self.player.currentTime(), itemTimeForDisplay: nil)
            return pixel != nil
        }
        return try #require(pixel)
    }

    func color(at seconds: Double) async throws -> String {
        let pixel = try await frame(at: seconds)
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        return bytes[2] > 200 && bytes[0] < 30 ? "red" : (bytes[0] > 200 && bytes[2] < 30 ? "blue" : "other")
    }

    static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "Video playback condition timed out")
    }

    static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoPlayback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func writeMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<20 {
            try await waitFor { input.isReadyForMoreMediaData }
            var pixel: CVPixelBuffer?
            try #require(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            for y in 0..<32 {
                for x in 0..<32 {
                    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                    bytes[offset] = index < 10 ? 0 : 255
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = index < 10 ? 255 : 0
                    bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
}
