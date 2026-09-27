import AppKit
import AVFoundation
import CoreImage
import Darwin
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WallpaperEngine

/// Opt-in, lead-only integration against the eligible installed video corpus.
/// The runner selects bounded batches and deletes images after visual review.
@MainActor
@Suite(.serialized)
struct VideoCorpusTests {
    private struct Manifest: Decodable {
        let corpus_root: String
        let fixtures: [Fixture]
    }
    private struct Fixture: Decodable { let id: String; let path: String; let type: String }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WE_VIDEO_CORPUS_MANIFEST"] != nil))
    func installedVideosPlayLoopPauseAndRelease() async throws {
        let environment = ProcessInfo.processInfo.environment
        let manifestPath = try #require(environment["WE_VIDEO_CORPUS_MANIFEST"])
        let output = URL(fileURLWithPath: try #require(environment["WE_VIDEO_CORPUS_REPORT_DIR"]))
        let images = URL(fileURLWithPath: try #require(environment["WE_VIDEO_IMAGE_DIR"]))
        let selected = Set(try #require(environment["WE_VIDEO_PROBE_IDS"]).split(separator: ",").map(String.init))
        try #require(!selected.isEmpty && selected.count <= 5)
        let excluded: Set<String> = ["2114290843", "3340296712", "3626081043", "3626090712"]
        try #require(selected.isDisjoint(with: excluded))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        let root = URL(fileURLWithPath: manifest.corpus_root).resolvingSymlinksInPath()
        try #require(!root.pathComponents.contains("Nsfw - non-testing"))
        let fixtures = manifest.fixtures.filter { selected.contains($0.id) }
        try #require(fixtures.count == selected.count)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for fixture in fixtures {
            try #require(fixture.path == fixture.id && fixture.type.lowercased() == "video")
            let directory = root.appendingPathComponent(fixture.path).resolvingSymlinksInPath()
            try #require(directory.path.hasPrefix(root.path + "/") && !directory.pathComponents.contains("Nsfw - non-testing"))
            var report: [String: Any] = ["id": fixture.id, "rss_before_mb": residentMiB()]
            do {
                report.merge(try await inspect(directory: directory, images: images, id: fixture.id)) { _, new in new }
                report["status"] = "passed"
            } catch {
                report["status"] = "failed"
                report["error"] = String(describing: error)
                Issue.record("Video \(fixture.id): \(error)")
            }
            report["rss_after_stop_mb"] = residentMiB()
            reports.append(report)
            let result: [String: Any] = [
                "complete": reports.count == fixtures.count, "fixtures": reports,
                "validation": "Production VideoRenderer queue and layer; decoded frames from current player items, display readiness, pause/resume, loop rollover, mute state and teardown.",
                "limits": "Images are player-item output, not screen-compositor captures. Loop tests seek near the end. Audible output, sustained resources and Windows fidelity require separate evidence.",
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("report.json"))
            print("[VideoCorpus] \(fixture.id): \(report["status"]!)")
        }
    }

    private func inspect(directory: URL, images: URL, id: String) async throws -> [String: Any] {
        let project = try WallpaperLoader.load(from: directory)
        try #require(project.resolvedType == .video)
        let url = try #require(project.fileURL).resolvingSymlinksInPath()
        try #require(url.path.hasPrefix(directory.path + "/"))
        let probe = try VideoPlaybackProbe(url: url)
        defer { probe.close() }
        try #require(probe.renderer.isMuted && probe.renderer.supportsAudio)
        probe.renderer.applyProperties(project.resolvedProperties, values: [:])
        probe.renderer.play()
        try await probe.waitUntilReady()
        let initialItem = try #require(probe.player.currentItem)
        let duration = try await initialItem.asset.load(.duration).seconds
        try #require(duration.isFinite && duration > 0.2)
        let tracks = try await initialItem.asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let audioTracks = try await initialItem.asset.loadTracks(withMediaType: .audio)
        let requestedSample = Double(ProcessInfo.processInfo.environment["WE_VIDEO_SAMPLE_SECONDS"] ?? "1") ?? 1
        let observeSeconds = Double(ProcessInfo.processInfo.environment["WE_VIDEO_OBSERVE_SECONDS"] ?? "0") ?? 0
        try #require(requestedSample.isFinite && requestedSample >= 0)
        try #require(observeSeconds.isFinite && observeSeconds >= 0 && observeSeconds <= 120)
        let observation = try await observe(probe, seconds: observeSeconds)
        let sampleTime = min(requestedSample, duration * 0.25)
        let first = try await probe.frame(at: sampleTime)
        try writeImage(first, transform: transform, to: images.appendingPathComponent(id + "-before.png"))
        let pausedBefore = probe.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(150))
        let pausedAfter = probe.player.currentTime().seconds
        try #require(abs(pausedAfter - pausedBefore) < 0.03)
        probe.renderer.play()
        try await VideoPlaybackProbe.waitFor { probe.player.currentTime().seconds > pausedAfter + min(0.1, duration * 0.1) }
        let resumed = probe.player.currentTime().seconds

        let endingItem = try #require(probe.player.currentItem)
        let nearEnd = max(0, duration - min(0.25, duration * 0.2))
        let sought = await probe.player.seek(to: CMTime(seconds: nearEnd, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try #require(sought)
        probe.renderer.play()
        try await VideoPlaybackProbe.waitFor {
            probe.player.currentItem !== endingItem && probe.player.currentTime().seconds > min(0.05, duration * 0.1)
        }
        try #require(probe.player.rate > 0 && probe.layer.isReadyForDisplay)
        let afterLoop = try await probe.frame(at: sampleTime)
        try writeImage(afterLoop, transform: transform, to: images.appendingPathComponent(id + "-loop.png"))
        try #require(CVPixelBufferGetWidth(first) == CVPixelBufferGetWidth(afterLoop))
        try #require(CVPixelBufferGetHeight(first) == CVPixelBufferGetHeight(afterLoop))
        let displayReady = probe.layer.isReadyForDisplay
        let videoRect = probe.layer.videoRect
        probe.renderer.stop()
        try #require(probe.player.items().isEmpty && probe.layer.player == nil && probe.layer.superlayer == nil)
        return [
            "title": project.title, "file": url.lastPathComponent, "duration_seconds": duration,
            "coded_width": size.width, "coded_height": size.height, "nominal_fps": nominalFPS,
            "audio_track_count": audioTracks.count, "muted": probe.renderer.isMuted,
            "paused_before": pausedBefore, "paused_after": pausedAfter, "resumed_seconds": resumed,
            "loop_rolled_over": true, "display_ready_after_loop": displayReady,
            "display_video_rect": [videoRect.origin.x, videoRect.origin.y, videoRect.width, videoRect.height],
            "sample_seconds": sampleTime, "queued_items_after_stop": probe.player.items().count,
            "property_keys": project.resolvedProperties.map(\.key),
            "images": [id + "-before.png", id + "-loop.png"],
            "continuous_observation": observation,
        ]
    }

    private func observe(_ probe: VideoPlaybackProbe, seconds: Double) async throws -> [String: Any] {
        guard seconds > 0 else { return [:] }
        let start = ContinuousClock.now
        var item: AVPlayerItem?
        var output: AVPlayerItemVideoOutput?
        defer { if let item, let output { item.remove(output) } }
        var loops = 0, frames = 0
        var lastFrameAt = start, lastSampleAt = start
        var samples: [[String: Any]] = []
        while start.duration(to: .now) < .seconds(seconds) {
            let current = try #require(probe.player.currentItem)
            if current !== item {
                if let item, let output { item.remove(output); loops += 1 }
                item = current
                let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                current.add(next)
                output = next
            }
            let time = probe.player.currentTime()
            if let output, output.hasNewPixelBuffer(forItemTime: time),
               output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                frames += 1
                lastFrameAt = .now
            }
            try #require(lastFrameAt.duration(to: .now) < .seconds(2), "No decoded video frames for two seconds")
            if lastSampleAt.duration(to: .now) >= .seconds(1) {
                samples.append(["playback_seconds": time.seconds, "rss_mb": residentMiB(),
                    "queued_items": probe.player.items().count, "rate": probe.player.rate,
                    "display_ready": probe.layer.isReadyForDisplay])
                lastSampleAt = .now
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(Double(frames) > seconds * 10, "Too few decoded frames during continuous playback")
        return ["requested_seconds": seconds, "decoded_frames_observed": frames, "natural_loops": loops,
                "samples": samples, "sampling_limit": "20ms polling is a frame-delivery lower bound, not a display-FPS measurement."]
    }

    private func writeImage(_ pixel: CVPixelBuffer, transform: CGAffineTransform, to url: URL) throws {
        let transformed = CIImage(cvPixelBuffer: pixel).transformed(by: transform)
        let scale = min(1, 960 / max(transformed.extent.width, transformed.extent.height))
        let image = transformed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        let cgImage = try #require(context.createCGImage(image, from: image.extent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        try #require(CGImageDestinationFinalize(destination))
    }

    private func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
