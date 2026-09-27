import AVFoundation
import Testing
@testable import WallpaperEngine

@MainActor
struct AudioReactivityTests {
    @Test func stalePermissionCannotStartCaptureAfterStopOrSourceReplacement() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var permissions: [@Sendable (Bool) -> Void] = []
        var made: [Capture] = []
        let controller = AudioReactivity(defaults: defaults, automaticallyDelivers: false,
            permission: { permissions.append($0) }, factory: { _ in let c = Capture(); made.append(c); return c })
        controller.select(.input)
        controller.start { _ in }; await settle()
        controller.stop()
        permissions[0](true)
        await settle()
        #expect(made.isEmpty && !controller.isRunning)
        controller.start { _ in }; await settle()
        controller.select(.system); await settle()
        #expect(made.count == 1 && controller.isRunning)
        permissions[1](true)
        await settle()
        #expect(made.count == 1)
        controller.stop()
        #expect(made[0].stops == 1)
    }

    @Test func sourceSelectionPersistsAndOffDoesNotRequestPermissionOrCapture() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var permissions = 0, factories = 0
        let controller = AudioReactivity(defaults: defaults, automaticallyDelivers: false,
            permission: { _ in permissions += 1 }, factory: { _ in factories += 1; return Capture() })
        #expect(controller.selection == .system)
        controller.select(.off)
        var outputs: [[Float]] = []
        controller.start { outputs.append($0) }
        #expect(permissions == 0 && factories == 0 && !controller.isRunning)
        #expect(outputs.last == Array(repeating: 0, count: 128))
        let restored = AudioReactivity(defaults: defaults, automaticallyDelivers: false)
        #expect(restored.selection == .off)
        controller.select(.input)
        #expect(permissions == 1 && factories == 0)
        controller.stop()
    }

    @Test func captureFailureCleansUpAndCanBeRetried() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Capture(); first.fail = true
        let second = Capture()
        var attempts = 0
        let controller = AudioReactivity(defaults: defaults, automaticallyDelivers: false, factory: { _ in
            attempts += 1; return attempts == 1 ? first : second
        })
        controller.start { _ in }; await settle()
        #expect(!controller.isRunning && first.stops == 1 && controller.status.contains("unavailable"))
        controller.select(.system); await settle()
        #expect(controller.isRunning && attempts == 2)
        controller.stop(); controller.stop()
        #expect(second.stops == 1)
    }

    @Test func deliveryClearsSilenceAndIgnoresOldCaptureBuffers() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var captures: [Capture] = []
        let controller = AudioReactivity(defaults: defaults, automaticallyDelivers: false, factory: { _ in
            let capture = Capture(); captures.append(capture); return capture
        })
        var bands: [Float] = []
        controller.start { bands = $0 }; await settle()
        captures[0].samples?(.mono(tone(bin: 32)))
        controller.deliver()
        #expect(bands.count == 128 && (bands.max() ?? 0) > 0.99)
        controller.stop()
        #expect(bands.allSatisfy { $0 == 0 })
        controller.start { bands = $0 }; await settle()
        captures[0].samples?(.mono(tone(bin: 32)))
        controller.deliver()
        #expect(bands.allSatisfy { $0 == 0 })
        captures[1].samples?(.mono(tone(bin: 128)))
        controller.deliver()
        #expect((bands.max() ?? 0) > 0.99)
        controller.deliver(now: ProcessInfo.processInfo.systemUptime + 1)
        #expect(bands.allSatisfy { $0 == 0 })
        controller.stop()
    }

    @Test func deviceInvalidationRestartsOnceAndCannotReviveAStoppedSession() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var captures: [Capture] = []
        let controller = AudioReactivity(defaults: defaults, automaticallyDelivers: false, factory: { _ in
            let capture = Capture(); captures.append(capture); return capture
        })
        controller.start { _ in }; await settle()
        captures[0].invalidated?(); captures[0].invalidated?()
        try await Task.sleep(for: .milliseconds(200))
        #expect(captures.count == 2 && captures[0].stops == 1 && controller.isRunning)
        captures[1].invalidated?()
        await settle()
        controller.stop()
        try await Task.sleep(for: .milliseconds(150))
        #expect(captures.count == 2 && !controller.isRunning)
    }

    @Test func stoppingDuringAsynchronousStartupDoesNotPublishLateSuccess() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = Capture(); capture.delayStart = true
        let controller = AudioReactivity(defaults: defaults, automaticallyDelivers: false, factory: { _ in capture })
        controller.start { _ in }; await settle()
        #expect(capture.gate != nil && !controller.isRunning)
        controller.stop()
        capture.gate?.resume(); capture.gate = nil
        await settle()
        #expect(!controller.isRunning && capture.stops == 1 && controller.status.contains("inactive"))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AudioReactivityTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    private func settle() async { for _ in 0..<10 { await Task.yield() } }
    private func tone(bin: Int) -> [Float] { (0..<2048).map { 0.5 * sin(Float($0 * bin) * 2 * .pi / 2048) } }
}

@MainActor
private final class Capture: AudioCaptureSession {
    var samples: (@Sendable (StereoAudioSamples) -> Void)?
    var invalidated: (@Sendable () -> Void)?
    var stops = 0
    var fail = false
    var delayStart = false
    var gate: CheckedContinuation<Void, Never>?
    func start(samples: @escaping @Sendable (StereoAudioSamples) -> Void, invalidated: @escaping @Sendable () -> Void) async throws {
        self.samples = samples; self.invalidated = invalidated
        if delayStart { await withCheckedContinuation { gate = $0 } }
        if fail { throw AudioCaptureError(operation: "Test start", code: -7) }
    }
    func stop() { stops += 1 }
}

struct AudioSpectrumTests {
    @Test func boundedMailboxRetainsNewestSamplesAndExpires() {
        let mailbox = AudioSampleMailbox()
        mailbox.append(.mono(Array(repeating: 0.25, count: 100_000)), now: 10)
        mailbox.append(.mono(Array(repeating: 0.5, count: 1024)), now: 10)
        let window = mailbox.window(now: 10.1).left
        #expect(window.count == 2048)
        #expect(window.prefix(1024).allSatisfy { $0 == 0.25 })
        #expect(window.suffix(1024).allSatisfy { $0 == 0.5 })
        #expect(mailbox.window(now: 11).left.allSatisfy { $0 == 0 })
        mailbox.append(.mono(Array(repeating: .nan, count: 2048)), now: 12)
        #expect(mailbox.window(now: 12).left.allSatisfy { $0 == 0 })
    }

    @Test func tonesMoveEnergyThroughTheExistingBandMappingAndSilenceClearsIt() {
        let analyzer = AudioSpectrumAnalyzer()
        func peak(_ bin: Int) -> Int {
            let samples = (0..<2048).map { 0.5 * sin(Float($0 * bin) * 2 * .pi / 2048) }
            let bands = analyzer.bands(.mono(samples))
            #expect(bands.count == 128 && bands.allSatisfy { $0.isFinite && (0...1.00001).contains($0) })
            return bands.indices.max { bands[$0] < bands[$1] }!
        }
        #expect(peak(16) < peak(128))
        #expect(analyzer.bands(.mono(Array(repeating: 0, count: 2048))).allSatisfy { $0 == 0 })
        #expect(analyzer.bands(.mono([])).allSatisfy { $0 == 0 })
    }

    @Test func stereoBandsKeepFrequencyOrderAndRelativeChannelLevel() {
        let analyzer = AudioSpectrumAnalyzer()
        let tone = (0..<2048).map { 0.5 * sin(Float($0 * 32) * 2 * .pi / 2048) }
        let bands = analyzer.bands(StereoAudioSamples(left: tone, right: tone.map { $0 * 0.25 }))
        let left = Array(bands.prefix(64)), right = Array(bands.suffix(64))
        #expect((left.max() ?? 0) > 0.99)
        #expect(abs((right.max() ?? 0) - 0.25) < 0.001)
        #expect(left.indices.max { left[$0] < left[$1] } == right.indices.max { right[$0] < right[$1] })
        let silentRight = analyzer.bands(StereoAudioSamples(left: tone, right: Array(repeating: 0, count: 2048)))
        #expect(silentRight.suffix(64).allSatisfy { $0 == 0 })
    }

    @MainActor @Test func sceneFrequencySummariesIncludeBassFromTheRightChannel() {
        var spectrum = [Float](repeating: 0, count: 128)
        for index in 64..<80 { spectrum[index] = 1 }
        let state = SceneRenderer.makeAudioState(from: spectrum)
        #expect(state.bass == 0.5 && state.mid == 0 && state.treble == 0)
        #expect(state.overall == 0.125 && state.spectrum == spectrum)
    }

    @Test func pcmConversionPreservesStereoAndHandlesPlanarIntegerAndInvalidLayouts() throws {
        for interleaved in [false, true] {
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
            buffer.frameLength = 3
            let channels = try #require(buffer.floatChannelData)
            if interleaved {
                for (i, value) in [Float(1),0,-1,1,.nan,0.5].enumerated() { channels[0][i] = value }
            } else {
                for (i, value) in [Float(1),-1,.nan].enumerated() { channels[0][i] = value }
                for (i, value) in [Float(0),1,0.5].enumerated() { channels[1][i] = value }
            }
            let decoder = try AudioPCMDecoder(format: format.streamDescription.pointee)
            #expect(decoder.stereo(buffer.audioBufferList) == StereoAudioSamples(left: [1,-1,0], right: [0,1,0.5]))
            let list = buffer.mutableAudioBufferList
            let original = list.pointee.mBuffers.mNumberChannels
            list.pointee.mBuffers.mNumberChannels = 0
            #expect(decoder.stereo(UnsafePointer(list)) == nil)
            list.pointee.mBuffers.mNumberChannels = original
        }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)); buffer.frameLength = 2
        let samples = try #require(buffer.int16ChannelData)
        samples[0][0] = .min; samples[0][1] = 16384
        #expect(try AudioPCMDecoder(format: format.streamDescription.pointee).stereo(buffer.audioBufferList) == .mono([-1,0.5]))
        var invalid = format.streamDescription.pointee; invalid.mBytesPerFrame = 7
        #expect(throws: AudioCaptureError.self) { try AudioPCMDecoder(format: invalid) }
    }
}
