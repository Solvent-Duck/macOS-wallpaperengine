import AppKit
import AVFoundation

/// Renders video wallpapers using AVFoundation.
///
/// Supports MP4, MOV, M4V, and any format AVFoundation can decode natively.
/// WebM files are transcoded to MP4 via `WebMTranscoder` before being passed
/// to this renderer, so all playback uses native hardware-accelerated decoding.
///
/// Features:
/// - Seamless looping via AVPlayerLooper
/// - Muted by default (wallpapers shouldn't play audio unexpectedly)
/// - Fills the entire screen via VideoHostView layout
class VideoRenderer: WallpaperRenderer {
    let view: NSView
    private let player: AVQueuePlayer
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?

    init(fileURL: URL) {
        player = AVQueuePlayer()
        player.isMuted = true

        // Set up seamless looping
        let templateItem = AVPlayerItem(url: fileURL)
        looper = AVPlayerLooper(player: player, templateItem: templateItem)

        // Create the player layer and host view
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill

        view = VideoHostView(playerLayer: playerLayer)
    }

    var supportsAudio: Bool { true }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    func play() {
        player.play()
        print("[VideoRenderer] Playing")
    }

    func pause() {
        player.pause()
        print("[VideoRenderer] Paused")
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.removeFromSuperlayer()
        print("[VideoRenderer] Stopped")
    }

    deinit {
        stop()
    }
}

/// NSView subclass that keeps an AVPlayerLayer sized to fill its bounds.
private class VideoHostView: NSView {
    let playerLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
