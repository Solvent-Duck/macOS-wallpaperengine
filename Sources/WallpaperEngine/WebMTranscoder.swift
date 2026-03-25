import Foundation
import CryptoKit

/// Transcodes WebM files to MP4 via ffmpeg for AVFoundation playback.
///
/// Caches transcoded files in ~/Library/Caches/WallpaperEngine/webm/ so each
/// WebM is only transcoded once. Uses hardware-accelerated encoding via
/// VideoToolbox when available, falling back to software libx264.
enum WebMTranscoder {

    private static let cacheDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("WallpaperEngine/webm", isDirectory: true)
    }()

    enum TranscodeError: LocalizedError {
        case ffmpegNotFound
        case transcodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg not found. Install via: brew install ffmpeg"
            case .transcodeFailed(let msg):
                return "WebM transcode failed: \(msg)"
            }
        }
    }

    /// Returns a cached MP4 URL for the given WebM file, transcoding if needed.
    static func transcode(webmURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let cachedMP4 = cachedURL(for: webmURL)

        // Use cache if it exists and is newer than the source
        if FileManager.default.fileExists(atPath: cachedMP4.path) {
            let srcMod = modificationDate(of: webmURL)
            let cacheMod = modificationDate(of: cachedMP4)
            if let s = srcMod, let c = cacheMod, c >= s {
                print("[WebMTranscoder] Using cached: \(cachedMP4.lastPathComponent)")
                return cachedMP4
            }
        }

        let ffmpeg = try findFFmpeg()
        print("[WebMTranscoder] Transcoding \(webmURL.lastPathComponent)...")

        // Try hardware-accelerated encode first, fall back to software
        let hwArgs = buildArgs(ffmpeg: ffmpeg, input: webmURL, output: cachedMP4, hwAccel: true)
        let swArgs = buildArgs(ffmpeg: ffmpeg, input: webmURL, output: cachedMP4, hwAccel: false)

        if run(args: hwArgs) != nil {
            print("[WebMTranscoder] HW encode unavailable, falling back to software")
            // Remove partial output from failed attempt
            try? FileManager.default.removeItem(at: cachedMP4)
            if let swError = run(args: swArgs) {
                throw TranscodeError.transcodeFailed(swError)
            }
        }

        print("[WebMTranscoder] Done: \(cachedMP4.lastPathComponent)")
        return cachedMP4
    }

    /// Check if a URL points to a WebM file.
    static func isWebM(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "webm"
    }

    // MARK: - Private

    private static func cachedURL(for source: URL) -> URL {
        // Hash the full path so different files with the same name don't collide
        let hash = Insecure.MD5.hash(data: Data(source.path.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let name = source.deletingPathExtension().lastPathComponent
        return cacheDir.appendingPathComponent("\(name)-\(hex.prefix(12)).mp4")
    }

    private static func buildArgs(ffmpeg: String, input: URL, output: URL, hwAccel: Bool) -> [String] {
        var args = [ffmpeg, "-y", "-i", input.path]
        if hwAccel {
            args += ["-c:v", "h264_videotoolbox", "-b:v", "8M"]
        } else {
            args += ["-c:v", "libx264", "-crf", "18", "-preset", "fast"]
        }
        // Copy audio (usually Vorbis/Opus → AAC for MP4 compat)
        args += ["-c:a", "aac", "-b:a", "128k"]
        // Avoid re-encoding if possible, keep quality high
        args += ["-movflags", "+faststart"]
        args += ["-loglevel", "error"]
        args += [output.path]
        return args
    }

    private static func run(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: errData, encoding: .utf8) ?? "exit code \(process.terminationStatus)"
        }
        return nil
    }

    private static func findFFmpeg() throws -> String {
        // Check common locations
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try PATH via which
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["ffmpeg"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try? which.run()
        which.waitUntilExit()
        if which.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }
        throw TranscodeError.ffmpegNotFound
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}
