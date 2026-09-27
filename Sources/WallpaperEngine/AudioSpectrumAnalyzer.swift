import Accelerate
import Foundation

/// Wallpaper Engine expects 64 low-to-high bands per channel: left, then right.
final class AudioSpectrumAnalyzer {
    private let fftSize = 2048          // FFT window — power of 2
    private let bandCount = 64
    // Owned by the main-actor audio controller; reused across windows.
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

    deinit { if let setup = fftSetup { vDSP_destroy_fftsetup(setup) } }

    func bands(_ samples: StereoAudioSamples) -> [Float] {
        var bands = channelBands(samples.left) + channelBands(samples.right)
        // Normalize both channels together so their relative level survives.
        var maximum: Float = 0
        vDSP_maxv(bands, 1, &maximum, vDSP_Length(bands.count))
        if maximum > 1e-5 {
            var scale = 1 / maximum
            vDSP_vsmul(bands, 1, &scale, &bands, 1, vDSP_Length(bands.count))
        }
        return bands
    }

    /// Run a real-FFT on `samples` and return `bandCount` log-spaced amplitude bands.
    private func channelBands(_ samples: [Float]) -> [Float] {
        guard samples.count == fftSize, let setup = fftSetup else { return [Float](repeating: 0, count: bandCount) }

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

        return bands
    }
}
