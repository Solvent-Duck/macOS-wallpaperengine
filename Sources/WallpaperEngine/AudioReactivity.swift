import AVFoundation
import Foundation

/// Audio response is independent from wallpaper sound output/muting.
enum AudioResponseSource: String, CaseIterable {
    case system, input, off
    var title: String {
        switch self {
        case .system: "System Audio"
        case .input: "Microphone / Input Device"
        case .off: "Off"
        }
    }
}

@MainActor
protocol AudioCaptureSession: AnyObject {
    func start(samples: @escaping @Sendable (StereoAudioSamples) -> Void,
               invalidated: @escaping @Sendable () -> Void) async throws
    func stop()
}

/// Owns capture, permission cancellation and delivery on the main actor. The
/// audio callback writes only into a bounded mailbox, never an unbounded queue.
@MainActor
final class AudioReactivity {
    typealias AudioCallback = ([Float]) -> Void
    typealias PermissionRequest = (@escaping @Sendable (Bool) -> Void) -> Void
    private(set) var selection: AudioResponseSource
    private(set) var isRunning = false
    private(set) var status = "Audio response is inactive"
    private let defaults: UserDefaults
    private let permission: PermissionRequest
    private let factory: (AudioResponseSource) -> any AudioCaptureSession
    private let automaticallyDelivers: Bool
    private let analyzer = AudioSpectrumAnalyzer()
    private var mailbox = AudioSampleMailbox()
    private var capture: (any AudioCaptureSession)?
    private var callback: AudioCallback?
    private var timer: Timer?
    private var active = false
    private var generation: UInt64 = 0
    private var restartTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, automaticallyDelivers: Bool = true,
         permission: @escaping PermissionRequest = { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) },
         factory: @escaping (AudioResponseSource) -> any AudioCaptureSession = {
             $0 == .input ? InputAudioCapture() : SystemAudioCapture()
         }) {
        self.defaults = defaults
        self.permission = permission
        self.factory = factory
        self.automaticallyDelivers = automaticallyDelivers
        selection = defaults.string(forKey: "AudioResponseSource").flatMap(AudioResponseSource.init(rawValue:)) ?? .system
    }

    isolated deinit {
        timer?.invalidate()
        restartTask?.cancel()
        startTask?.cancel()
        capture?.stop()
    }

    func select(_ source: AudioResponseSource) {
        selection = source
        defaults.set(source.rawValue, forKey: "AudioResponseSource")
        // Selecting the same source retries after OS permission or device changes.
        if active, let callback { stop(); start(callback: callback) }
        else { status = source == .off ? "Audio response is off" : "Audio response is inactive" }
    }

    func start(callback: @escaping AudioCallback) {
        guard !active else { return }
        active = true
        self.callback = callback
        generation &+= 1
        let revision = generation
        mailbox = AudioSampleMailbox()
        callback(Array(repeating: 0, count: 128))
        guard selection != .off else { status = "Audio response is off"; return }
        if selection == .input {
            status = "Waiting for microphone permission"
            permission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.generation == revision else { return }
                    if granted { await self.beginCapture(revision: revision) }
                    else { self.status = "Allow microphone access in Privacy & Security, then select Input Device again" }
                }
            }
        } else {
            status = "Starting system audio"
            startTask = Task { @MainActor [weak self] in await self?.beginCapture(revision: revision) }
        }
    }

    func stop() {
        generation &+= 1
        active = false
        isRunning = false
        restartTask?.cancel(); restartTask = nil
        startTask?.cancel(); startTask = nil
        timer?.invalidate(); timer = nil
        capture?.stop(); capture = nil
        mailbox = AudioSampleMailbox()
        callback?(Array(repeating: 0, count: 128))
        callback = nil
        status = selection == .off ? "Audio response is off" : "Audio response is inactive"
    }

    private func beginCapture(revision: UInt64) async {
        guard active, generation == revision else { return }
        let session = factory(selection)
        let sink = mailbox
        capture = session
        do {
            try await session.start(samples: { sink.append($0) }, invalidated: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.generation == revision else { return }
                    self.restartTask?.cancel()
                    self.restartTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled, let self, self.active,
                              self.generation == revision, let callback = self.callback else { return }
                        self.stop(); self.start(callback: callback)
                    }
                }
            })
            guard active, generation == revision, !Task.isCancelled else { return }
            isRunning = true
            status = "Listening to \(selection.title.lowercased())"
            if automaticallyDelivers {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.deliver() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } catch {
            guard active, generation == revision else { return }
            session.stop()
            capture = nil
            status = "\(selection.title) unavailable: \(error.localizedDescription)"
            print("[AudioReactivity] \(status)")
        }
    }

    /// Timer and deterministic tests use the same delivery path. Silence clears
    /// reactive state if a device stops providing buffers without a stop event.
    func deliver(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard active, isRunning else { return }
        callback?(analyzer.bands(mailbox.window(now: now)))
    }
}

/// Fixed storage caps both sample history and work waiting for the main actor.
/// try() avoids holding up the audio IO callback while a window is copied.
final class AudioSampleMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var left = [Float](repeating: 0, count: 8192)
    private var right = [Float](repeating: 0, count: 8192)
    private var cursor = 0
    private var count = 0
    private var receivedAt: TimeInterval = -.infinity

    func append(_ input: StereoAudioSamples, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let frames = min(input.left.count, input.right.count)
        guard frames > 0, lock.try() else { return }
        defer { lock.unlock() }
        for index in max(0, frames - left.count)..<frames {
            left[cursor] = input.left[index].isFinite ? min(max(input.left[index], -1), 1) : 0
            right[cursor] = input.right[index].isFinite ? min(max(input.right[index], -1), 1) : 0
            cursor = (cursor + 1) % left.count
        }
        count = min(left.count, count + min(frames, left.count))
        receivedAt = now
    }

    func window(now: TimeInterval) -> StereoAudioSamples {
        lock.lock(); defer { lock.unlock() }
        let size = 2048
        guard count >= size, now - receivedAt <= 0.25 else { return .mono(Array(repeating: 0, count: size)) }
        let indices = (0..<size).map { (cursor - size + left.count + $0) % left.count }
        return StereoAudioSamples(left: indices.map { left[$0] }, right: indices.map { right[$0] })
    }
}
