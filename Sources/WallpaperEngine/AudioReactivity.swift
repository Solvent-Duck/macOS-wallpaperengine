import AVFoundation
import Accelerate

/// Captures audio from the default input device, computes a real FFT,
/// and delivers normalized 128-band frequency data to a callback at ~30 fps.
///
/// Used to drive audio-reactive wallpapers (both web and scene types).
/// Requires microphone permission — requests it on first call to `start`.
///
/// If the user routes a loopback device (e.g. BlackHole) as the system default
/// input, this automatically captures system output audio instead.
class AudioReactivity {
    typealias AudioCallback = ([Float]) -> Void

    private(set) var isRunning = false
    private var engine: AVAudioEngine?
    private var callback: AudioCallback?

    private let fftSize = 2048          // FFT window — power of 2
    private let bandCount = 128         // Wallpaper Engine uses 128 frequency bands
    private let deliveryInterval = 1.0 / 30.0
    private var lastDeliveryTime: Double = 0

    // Ring buffer; only accessed on bufferQueue
    private var sampleRing: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.wallpaperengine.audio", qos: .userInteractive)

    // Pre-allocated FFT work buffers; only accessed on bufferQueue
    private var hannWindow: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var magnitudes: [Float]
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?

    init() {
        let n = 2048
        log2n      = vDSP_Length(log2(Double(n)))
        hannWindow = [Float](repeating: 0, count: n)
        realBuf    = [Float](repeating: 0, count: n / 2)
        imagBuf    = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
        vDSP_hann_window(&hannWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        stop()
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup) }
    }

    // MARK: - Public

    /// Request microphone permission, then start capturing and analysing audio.
    func start(callback: @escaping AudioCallback) {
        guard !isRunning else { return }
        self.callback = callback
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard let self else { return }
            if granted {
                DispatchQueue.main.async { self.startEngine() }
            } else {
                print("[AudioReactivity] Microphone permission denied — audio reactivity unavailable")
            }
        }
    }

    /// Stop capturing audio and release engine resources.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        bufferQueue.async { [weak self] in self?.sampleRing.removeAll() }
        print("[AudioReactivity] Stopped")
    }

    // MARK: - Private

    private func startEngine() {
        let ae = AVAudioEngine()
        let inputNode = ae.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)

        guard fmt.sampleRate > 0 else {
            print("[AudioReactivity] No audio input device available")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buf, _ in
            self?.handleBuffer(buf)
        }

        do {
            try ae.start()
            engine = ae
            isRunning = true
            print("[AudioReactivity] Started — \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch")
        } catch {
            print("[AudioReactivity] Engine start failed: \(error.localizedDescription)")
        }
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)

        // Mix down to mono
        var mono = [Float](repeating: 0, count: count)
        if buffer.format.channelCount >= 2 {
            vDSP_vadd(data[0], 1, data[1], 1, &mono, 1, vDSP_Length(count))
            var half: Float = 0.5
            vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(count))
        } else {
            mono = Array(UnsafeBufferPointer(start: data[0], count: count))
        }

        bufferQueue.async { [weak self] in self?.enqueue(mono) }
    }

    private func enqueue(_ samples: [Float]) {
        sampleRing.append(contentsOf: samples)
        // Keep the ring bounded — 4 windows is plenty of look-back
        if sampleRing.count > fftSize * 4 {
            sampleRing.removeFirst(sampleRing.count - fftSize * 2)
        }

        guard sampleRing.count >= fftSize else { return }

        let now = CACurrentMediaTime()
        guard now - lastDeliveryTime >= deliveryInterval else { return }
        lastDeliveryTime = now

        let window = Array(sampleRing.suffix(fftSize))
        let bands = computeBands(window)

        DispatchQueue.main.async { [weak self] in
            self?.callback?(bands)
        }
    }

    /// Run a real-FFT on `samples` and return `bandCount` log-spaced amplitude bands.
    private func computeBands(_ samples: [Float]) -> [Float] {
        guard let setup = fftSetup else { return [Float](repeating: 0, count: bandCount) }

        // Apply Hann window to reduce spectral leakage
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack real array into split complex: [x0,x1,x2,x3,...] → realp=[x0,x2,...] imagp=[x1,x3,...]
        // Use withUnsafeMutableBufferPointer to obtain stable pointers for DSPSplitComplex.
        realBuf.withUnsafeMutableBufferPointer { realPtr in
            imagBuf.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBytes { rawPtr in
                    let complexPtr = rawPtr.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }
                // Real FFT (forward)
                vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                // Power spectrum (magnitude²)
                magnitudes.withUnsafeMutableBufferPointer { magPtr in
                    var sc2 = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_zvmags(&sc2, 1, magPtr.baseAddress!, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        // Convert to amplitude: sqrt(2 / N²) scaling for one-sided real FFT
        var amplitudes = Array(magnitudes.prefix(fftSize / 2))
        var scale = Float(2.0) / Float(fftSize * fftSize)
        vDSP_vsmul(amplitudes, 1, &scale, &amplitudes, 1, vDSP_Length(fftSize / 2))
        // sqrt in-place
        var count = Int32(fftSize / 2)
        vvsqrtf(&amplitudes, amplitudes, &count)

        // Map FFT bins → bandCount logarithmically-spaced bands
        let binCount = fftSize / 2
        var bands = [Float](repeating: 0, count: bandCount)
        let logMax = log(Double(binCount))

        for b in 0..<bandCount {
            let lo    = Int(exp(Double(b)     * logMax / Double(bandCount)))
            let hi    = Int(exp(Double(b + 1) * logMax / Double(bandCount)))
            let start = max(1, lo)
            let end   = min(binCount - 1, max(start, hi))
            var sum: Float = 0
            for bin in start...end { sum += amplitudes[bin] }
            bands[b] = sum / Float(end - start + 1)
        }

        // Soft-normalize to 0–1 against the loudest band
        var maxVal: Float = 0
        vDSP_maxv(bands, 1, &maxVal, vDSP_Length(bandCount))
        if maxVal > 1e-5 {
            var invMax = 1.0 / maxVal
            vDSP_vsmul(bands, 1, &invMax, &bands, 1, vDSP_Length(bandCount))
        }

        return bands
    }
}
