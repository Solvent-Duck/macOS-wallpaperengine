import AVFoundation
import CoreAudio
import Foundation

struct AudioCaptureError: LocalizedError {
    let operation: String
    let code: OSStatus
    var errorDescription: String? {
        "\(operation) (\(code)). Check audio recording permission and select the source again."
    }
}

/// Private tap + private aggregate input. No default device changes, speaker
/// muting, recording, or third-party loopback driver is involved.
@MainActor
final class SystemAudioCapture: AudioCaptureSession {
    private let worker = DispatchQueue(label: "com.wallpaperengine.audio-setup", qos: .userInitiated)
    private let resources = AudioTapResources()
    isolated deinit { stop() }

    func start(samples: @escaping @Sendable (StereoAudioSamples) -> Void,
               invalidated: @escaping @Sendable () -> Void) async throws {
        let resources = resources
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                do { try resources.start(samples: samples, invalidated: invalidated); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        let resources = resources
        resources.cancel()
        worker.async { resources.stop() }
    }
}

/// HAL resource ownership is confined to the setup queue. Cancellation is the
/// only cross-queue state. In particular, HAL startup must never block AppKit.
private final class AudioTapResources: @unchecked Sendable {
    private let cancellationLock = NSLock()
    private var cancelled = false
    func cancel() { cancellationLock.lock(); cancelled = true; cancellationLock.unlock() }
    private func checkCancellation() throws {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        if cancelled { throw CancellationError() }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.wallpaperengine.system-audio", qos: .userInteractive)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []


    func start(samples: @escaping @Sendable (StereoAudioSamples) -> Void,
               invalidated: @escaping @Sendable () -> Void) throws {
        stop()
        do {
            try checkCancellation()
            // Exclude our own scene sounds so the response does not feed itself.
            var pid = getpid()
            var processID = AudioObjectID(kAudioObjectUnknown)
            var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processID), "Find wallpaper audio process")
            guard processID != kAudioObjectUnknown else { throw AudioCaptureError(operation: "Find wallpaper audio process", code: -1) }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [processID])
            description.name = "Wallpaper Audio Response"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio tap")

            var format = AudioStreamBasicDescription()
            address = Self.address(kAudioTapPropertyFormat)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Read system audio format")
            let decoder = try AudioPCMDecoder(format: format)
            // A physical clock keeps the aggregate running even while all
            // tapped applications are silent. The device remains private and
            // is never selected as the system input or output.
            address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            var outputID = AudioObjectID(kAudioObjectUnknown)
            size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                &size, &outputID), "Read output clock")
            address = Self.address(kAudioDevicePropertyDeviceUID)
            var outputUID: CFString = "" as CFString
            size = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &outputUID) {
                AudioObjectGetPropertyData(outputID, &address, 0, nil, &size, $0)
            }
            try check(uidStatus, "Read output clock identity")
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Wallpaper Audio Response",
                kAudioAggregateDeviceUIDKey: "com.wallpaperengine.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID,
                                                       kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "Create audio input")
            // Some hardware combines microphone inputs and speaker outputs in
            // one device. Reject added input channels rather than capturing them.
            address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            size = 0
            try check(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size), "Read tap input layout")
            guard size >= MemoryLayout<AudioBufferList>.size, size <= 65536 else {
                throw AudioCaptureError(operation: "Invalid tap input layout size", code: -1)
            }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage), "Read tap input layout")
            let layout = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            guard layout.reduce(0, { $0 + $1.mNumberChannels }) == format.mChannelsPerFrame else {
                throw AudioCaptureError(operation: "Output clock includes additional audio inputs", code: -1)
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, input, _, _, _ in
                if let pcm = decoder.stereo(input), !pcm.left.isEmpty { samples(pcm) }
            }, "Connect system audio input")
            // Rebuild after a physical output switch or tap format change. These
            // listeners never mutate the OS device selection or run on the IO queue.
            try listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, invalidated)
            try listen(tapID, kAudioTapPropertyFormat, invalidated)
            try checkCancellation()
            try check(AudioDeviceStart(deviceID, ioProc), "Start system audio input")
            try checkCancellation()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for (object, original, block) in listeners {
            var address = original
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
            self.ioProc = nil
        }
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ invalidated: @escaping @Sendable () -> Void) throws {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in invalidated() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, .main, block), "Observe audio device")
        listeners.append((object, address, block))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioCaptureError(operation: operation, code: status) }
    }
}

/// Explicit legacy microphone/loopback input, with permission handled by the
/// controller before this session is created.
@MainActor
final class InputAudioCapture: AudioCaptureSession {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    isolated deinit { stop() }

    func start(samples: @escaping @Sendable (StereoAudioSamples) -> Void,
               invalidated: @escaping @Sendable () -> Void) async throws {
        stop()
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        let decoder = try AudioPCMDecoder(format: format.streamDescription.pointee)
        node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            if let pcm = decoder.stereo(buffer.audioBufferList), !pcm.left.isEmpty { samples(pcm) }
        }
        self.engine = engine
        do {
            try engine.start()
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { _ in invalidated() }
        } catch { stop(); throw error }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
    }
}

struct StereoAudioSamples: Sendable, Equatable {
    let left: [Float]
    let right: [Float]
    static func mono(_ samples: [Float]) -> Self { Self(left: samples, right: samples) }
}

/// Converts packed native-endian PCM, including interleaved and planar layouts.
/// Copies at most four FFT windows while the borrowed IO buffers remain valid.
struct AudioPCMDecoder: Sendable {
    private enum Kind: Sendable { case float32, float64, int16, int32 }
    private let kind: Kind
    private let bytes: Int
    private let channels: Int

    init(format: AudioStreamBasicDescription) throws {
        let flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate.isFinite, format.mSampleRate > 0,
              (1...32).contains(format.mChannelsPerFrame), flags & kAudioFormatFlagIsBigEndian == 0,
              flags & kAudioFormatFlagIsPacked != 0 else {
            throw AudioCaptureError(operation: "Unsupported PCM format", code: -1)
        }
        switch (flags & kAudioFormatFlagIsFloat != 0, flags & kAudioFormatFlagIsSignedInteger != 0, format.mBitsPerChannel) {
        case (true, _, 32): kind = .float32; bytes = 4
        case (true, _, 64): kind = .float64; bytes = 8
        case (false, true, 16): kind = .int16; bytes = 2
        case (false, true, 32): kind = .int32; bytes = 4
        default: throw AudioCaptureError(operation: "Unsupported PCM sample type", code: -1)
        }
        channels = Int(format.mChannelsPerFrame)
        let frameChannels = flags & kAudioFormatFlagIsNonInterleaved == 0 ? channels : 1
        guard Int(format.mBytesPerFrame) == frameChannels * bytes else {
            throw AudioCaptureError(operation: "Unsupported PCM frame stride", code: -1)
        }
    }

    func stereo(_ list: UnsafePointer<AudioBufferList>) -> StereoAudioSamples? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard !buffers.isEmpty, buffers.count <= channels,
              buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) == channels else { return nil }
        var frames = Int.max
        for buffer in buffers {
            guard buffer.mNumberChannels > 0 else { return nil }
            frames = min(frames, Int(buffer.mDataByteSize) / (Int(buffer.mNumberChannels) * bytes))
        }
        guard frames > 0 else { return .mono([]) }
        let first = max(0, frames - 8192)
        var left = [Float](repeating: 0, count: frames - first)
        var right = left
        var channelOffset = 0
        for buffer in buffers {
            defer { channelOffset += Int(buffer.mNumberChannels) }
            guard let data = buffer.mData else { continue } // A null buffer represents silence.
            let channelCount = Int(buffer.mNumberChannels)
            for frame in first..<frames {
                for channel in 0..<channelCount {
                    let offset = (frame * channelCount + channel) * bytes
                    let value: Float
                    switch kind {
                    case .float32: value = data.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    case .float64: value = Float(data.loadUnaligned(fromByteOffset: offset, as: Double.self))
                    case .int16: value = Float(data.loadUnaligned(fromByteOffset: offset, as: Int16.self)) / 32768
                    case .int32: value = Float(data.loadUnaligned(fromByteOffset: offset, as: Int32.self)) / 2147483648
                    }
                    let finite = value.isFinite ? min(max(value, -1), 1) : 0
                    if channelOffset + channel == 0 { left[frame - first] = finite }
                    if channelOffset + channel == 1 { right[frame - first] = finite }
                }
            }
        }
        return StereoAudioSamples(left: left, right: channels == 1 ? left : right)
    }
}
