import AVFoundation
import Compression
import Foundation
import NativeSceneCore

/// A script-controlled movie has its own clock even when layers share a file.
struct SceneVideoTexture {
    let duration: Double
    var time: Double = 0
    var rate: Double = 1
    var loop = true
    var playing = true

    mutating func advance(_ delta: Double) -> Double {
        guard playing, delta.isFinite, delta > 0, rate != 0 else { return 0 }
        let next = time + delta * rate
        guard next.isFinite else { return 0 }
        if loop {
            let crossings = rate > 0 ? floor(next / duration) : max(0, ceil(-next / duration))
            let remainder = next.truncatingRemainder(dividingBy: duration)
            time = remainder < 0 ? remainder + duration : remainder
            return max(0, crossings)
        }
        time = min(max(next, 0), duration)
        if (rate > 0 && next >= duration) || (rate < 0 && next <= 0) {
            playing = false
            return 1
        }
        return 0
    }

    mutating func apply(_ values: [String: Any]) {
        switch values["action"] as? String {
        case "play": playing = true
        case "pause": playing = false
        case "stop": playing = false; time = 0
        case "setCurrentTime":
            if let value = values["value"] as? Double, value.isFinite { time = min(max(value, 0), duration) }
        case "rate":
            if let value = values["value"] as? Double, value.isFinite { rate = value }
        case "loop": if let value = values["value"] as? Bool { loop = value }
        default: break
        }
    }

    var snapshot: [String: Any] {
        ["duration": duration, "time": time, "rate": rate, "loop": loop, "playing": playing]
    }
}

/// Resolve metadata only when a script requests a video. Ordinary image layers
/// and uncontrolled videos keep their existing loading and playback paths.
final class SceneVideoTextureLibrary {
    private let assets: TextureAnimationLibrary
    private var durations: [String: Double?] = [:]
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WEVideoMetadata-\(UUID().uuidString)")

    init(assets: TextureAnimationLibrary) { self.assets = assets }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func duration(for path: String) -> Double? {
        if let cached = durations[path] { return cached }
        let result = loadDuration(for: path)
        durations[path] = .some(result)
        return result
    }

    private func loadDuration(for path: String) -> Double? {
        guard let url = assets.assetURL(for: path),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let movie = Self.moviePayload(data) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent("\(durations.count).mp4")
            try movie.write(to: staged, options: .atomic)
            defer { try? FileManager.default.removeItem(at: staged) }
            // Match the renderer's synchronous AVAsset metadata loading. No
            // audio output or video decoder is started by this metadata query.
            let asset = AVURLAsset(url: staged)
            guard !asset.tracks(withMediaType: .video).isEmpty else { return nil }
            let seconds = asset.duration.seconds
            return seconds.isFinite && seconds > 0 ? seconds : nil
        } catch { return nil }
    }

    /// The first TEX mip holds the entire MP4. Match WETexDecoder's payload
    /// sniffing: real files use TEXB0003 and sometimes clear the video flag.
    static func moviePayload(_ data: Data) -> Data? {
        var offset = 0
        func word() -> UInt32? {
            guard offset <= data.count - 4 else { return nil }
            defer { offset += 4 }
            return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        func tag() -> String? {
            guard offset <= data.count - 9, data[offset + 8] == 0 else { return nil }
            defer { offset += 9 }
            return String(decoding: data[offset..<offset + 8], as: UTF8.self)
        }
        guard tag() == "TEXV0005", tag() == "TEXI0001" else { return nil }
        for _ in 0..<7 { guard word() != nil else { return nil } }
        guard let container = tag(), let images = word(), images > 0 else { return nil }
        switch container {
        case "TEXB0001", "TEXB0002": break
        case "TEXB0003": guard word() != nil else { return nil }
        case "TEXB0004": guard word() != nil, word() != nil else { return nil }
        default: return nil
        }
        guard let mips = word(), mips > 0, word() != nil, word() != nil else { return nil }
        var compression: UInt32 = 0, unpacked: UInt32 = 0
        if container != "TEXB0001" {
            guard let kind = word(), let size = word() else { return nil }
            compression = kind; unpacked = size
        }
        guard let length = word(), length > 0, Int(length) <= data.count - offset else { return nil }
        var payload = data.subdata(in: offset..<offset + Int(length))
        if compression == 1 {
            // Bound allocations from an untrusted compressed size header.
            guard unpacked > 0, unpacked <= 512 * 1024 * 1024 else { return nil }
            var decoded = Data(count: Int(unpacked))
            let count = decoded.withUnsafeMutableBytes { output in payload.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, Int(unpacked),
                    input.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_LZ4_RAW)
            } }
            guard count == Int(unpacked) else { return nil }
            payload = decoded
        }
        guard payload.count >= 12, payload[4..<8] == Data("ftyp".utf8) else { return nil }
        return payload
    }
}
