import AVFoundation
import Foundation
import Metal

/// Plays an animated `.tex` texture's embedded MP4 payload into a persistent
/// Metal texture. Decoding is pull-based (AVAssetReader) and driven by the
/// scene clock, so playback works identically in the app and in headless
/// snapshot runs. The MTLTexture identity is stable for the player's
/// lifetime; `advance(to:)` rewrites its contents in place.
final class VideoTexturePlayer {
    private struct FrameSample {
        let sampleBuffer: CMSampleBuffer
        let pixelBuffer: CVPixelBuffer
        let time: Double
    }

    let texture: MTLTexture
    /// WE `g_TextureNResolution` semantics (storage xy, real image zw).
    let resolution: SIMD4<Float>
    let clampUVs: Bool
    let pointSampling: Bool

    private let assetURL: URL
    private let videoDuration: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Presentation time of the frame currently uploaded, within the loop.
    private var uploadedTime: Double = -1
    /// The first decoded frame after `uploadedTime`. Holding it lets the
    /// player select the frame at-or-before a request without consuming the
    /// frame for the next request.
    private var pendingSample: CMSampleBuffer?
    /// Last requested time within the movie loop. This is deliberately
    /// independent of `uploadedTime`: a movie may begin at a nonzero PTS.
    private var requestedTime: Double?

    /// Test-visible only through `@testable`; production callers have no
    /// decoder-control surface. It makes the no-restart regression explicit.
    private(set) var readerRestartCount = 0

    init?(payload: WETexVideoPayload, cacheURL: URL, device: MTLDevice) {
        do {
            let existingSize = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int) ?? -1
            if existingSize != payload.data.count {
                try payload.data.write(to: cacheURL, options: .atomic)
            }
        } catch {
            print("[VideoTexturePlayer] Failed to stage MP4 payload at \(cacheURL.path): \(error)")
            return nil
        }
        self.assetURL = cacheURL
        self.clampUVs = payload.clampUVs
        self.pointSampling = payload.pointSampling

        let asset = AVURLAsset(url: cacheURL)
        guard let (track, duration) = Self.loadVideoTrack(from: asset) else {
            print("[VideoTexturePlayer] No decodable video track in \(cacheURL.lastPathComponent)")
            return nil
        }
        guard duration.isFinite, duration > 0 else {
            print("[VideoTexturePlayer] Invalid video duration in \(cacheURL.lastPathComponent)")
            return nil
        }
        self.videoDuration = duration

        let naturalSize = Self.loadNaturalSize(of: track)
        let width = max(Int(naturalSize.width.rounded()), 1)
        let height = max(Int(naturalSize.height.rounded()), 1)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        self.texture = texture
        self.resolution = SIMD4<Float>(
            Float(width),
            Float(height),
            Float(payload.imageWidth > 0 ? payload.imageWidth : width),
            Float(payload.imageHeight > 0 ? payload.imageHeight : height)
        )

        // Upload the first frame immediately so the texture is never blank.
        restartReader()
        advance(to: 0)
        guard uploadedTime >= 0 else {
            return nil
        }
    }

    /// Advances playback so the uploaded frame matches scene time `time`
    /// (looping over the movie duration). Decodes forward as needed; a no-op
    /// when the current frame is still correct.
    func advance(to time: Double, looping: Bool = true) {
        guard videoDuration.isFinite, videoDuration > 0, time.isFinite else { return }
        let remainder = time.truncatingRemainder(dividingBy: videoDuration)
        let loopTime = looping ? (remainder >= 0 ? remainder : remainder + videoDuration) : min(max(time, 0), videoDuration)

        // A lower requested loop time means either a caller seeked backwards
        // or scene time wrapped. Do not compare against `uploadedTime`: the
        // first video frame can legitimately have a PTS after zero.
        if let requestedTime, loopTime < requestedTime {
            restartReader()
        }
        requestedTime = loopTime

        guard let output else { return }

        // The initial texture must be populated even when the movie's first
        // PTS is nonzero. After that, only promote samples whose PTS is at or
        // before the requested time.
        if uploadedTime < 0, let first = nextSample(from: output) {
            upload(pixelBuffer: first.pixelBuffer)
            uploadedTime = first.time
        }

        var latestEligible: FrameSample?
        while true {
            let next: FrameSample
            if let pendingSample {
                guard let sample = validSample(pendingSample) else {
                    self.pendingSample = nil
                    continue
                }
                next = sample
            } else {
                guard let sample = nextSample(from: output) else {
                    // EOF (including duration metadata after the last PTS):
                    // retain the last successfully uploaded frame.
                    break
                }
                next = sample
            }

            guard next.time <= loopTime else {
                // Keep one future sample for the next advancing request.
                if pendingSample == nil {
                    pendingSample = next.sampleBuffer
                }
                break
            }

            pendingSample = nil
            latestEligible = next
            uploadedTime = next.time
        }
        // A forward jump can traverse several decoded samples. Rewrite the
        // persistent texture once with the selected final frame rather than
        // uploading every intermediate frame.
        if let latestEligible {
            upload(pixelBuffer: latestEligible.pixelBuffer)
        }
    }

    private func restartReader() {
        reader?.cancelReading()
        reader = nil
        output = nil
        uploadedTime = -1
        pendingSample = nil
        readerRestartCount += 1

        let asset = AVURLAsset(url: assetURL)
        guard let (track, _) = Self.loadVideoTrack(from: asset),
              let reader = try? AVAssetReader(asset: asset) else {
            return
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }
        self.reader = reader
        self.output = output
    }

    private func nextSample(from output: AVAssetReaderTrackOutput) -> FrameSample? {
        while let sample = output.copyNextSampleBuffer() {
            if let valid = validSample(sample) {
                return valid
            }
        }
        return nil
    }

    private func validSample(_ sample: CMSampleBuffer) -> FrameSample? {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time.isFinite, let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            return nil
        }
        return FrameSample(sampleBuffer: sample, pixelBuffer: pixelBuffer, time: time)
    }

    private func upload(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = min(CVPixelBufferGetWidth(pixelBuffer), texture.width)
        let height = min(CVPixelBufferGetHeight(pixelBuffer), texture.height)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: base,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
    }

    // MARK: - Synchronous AVAsset loading

    /// The renderer initializes textures synchronously on its render thread;
    /// the synchronous AVAsset metadata APIs are deprecated but remain the
    /// only option that doesn't hop tasks with non-Sendable AVFoundation
    /// types.
    private static func loadVideoTrack(from asset: AVURLAsset) -> (AVAssetTrack, Double)? {
        guard let track = asset.tracks(withMediaType: .video).first else {
            return nil
        }
        return (track, asset.duration.seconds)
    }

    private static func loadNaturalSize(of track: AVAssetTrack) -> CGSize {
        track.naturalSize
    }
}
