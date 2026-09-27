import Foundation
import AVFoundation
import Darwin

struct VideoItem: Decodable { let id: String; let path: String; let type: String }
struct VideoManifest: Decodable { let corpus_root: String; let fixtures: [VideoItem] }
struct VideoProject: Decodable { let file: String }

@main struct VideoProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "VideoProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: VideoDecodeProbe <video-corpus.json> <report.json>"])
        }
        let manifest = try JSONDecoder().decode(VideoManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = URL(fileURLWithPath: manifest.corpus_root, isDirectory: true).resolvingSymlinksInPath()
        let excluded = Set(["2114290843", "3340296712", "3626081043", "3626090712"])
        guard !root.pathComponents.contains("Nsfw - non-testing") else {
            throw NSError(domain: "VideoProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Excluded corpus root"])
        }
        var reports: [[String: Any]] = []
        for item in manifest.fixtures where item.type == "video" {
            // Exclude before reading project metadata or any media.
            guard !excluded.contains(item.id), item.path == item.id else { continue }
            let directory = root.appendingPathComponent(item.path).resolvingSymlinksInPath()
            guard !directory.pathComponents.contains("Nsfw - non-testing"), directory.path.hasPrefix(root.path + "/") else { continue }
            var report: [String: Any] = ["fixture_id": item.id, "windows_parity_verified": false]
            do {
                let project = try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: directory.appendingPathComponent("project.json")))
                report["file"] = project.file
                let asset = AVURLAsset(url: directory.appendingPathComponent(project.file))
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw NSError(domain: "VideoProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"]) }
                let size = try await track.load(.naturalSize)
                let rate = try await track.load(.nominalFrameRate)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                var captures: [[String: Any]] = []
                for seconds in [0.0, min(1.0, max(0.0, duration / 2))] {
                    let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                    captures.append(["requested_seconds": seconds, "actual_seconds": frame.actualTime.seconds,
                                     "width": frame.image.width, "height": frame.image.height])
                }
                report.merge(["status": "decoded", "playable": playable, "duration_seconds": duration,
                              "width": size.width, "height": size.height, "nominal_fps": rate, "captures": captures]) { _, new in new }
            } catch {
                report["status"] = "failed"
                report["error"] = error.localizedDescription
            }
            reports.append(report)
            FileHandle.standardError.write(Data("\(item.id): \(report["status"]!)\n".utf8))
        }
        let result: [String: Any] = ["fixture_count": reports.count, "validation": "AVFoundation playable metadata and two decoded frames per video; app playback, audio, looping, and controls remain unverified", "windows_parity_verified": false, "fixtures": reports]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if reports.contains(where: { $0["status"] as? String != "decoded" || $0["playable"] as? Bool != true }) {
            exit(1)
        }
    }
}
