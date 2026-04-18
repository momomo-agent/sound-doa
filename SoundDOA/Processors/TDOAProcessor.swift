import Accelerate
import Foundation

/// TDOA using GCC (cross-correlation via FFT) with energy-weighted bins
final class TDOAProcessor: @unchecked Sendable {
    let sampleRate: Double
    private let micSpacing: Double
    private let speedOfSound: Double = 343.0
    private let n: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    init(fftSize: Int = 2048, sampleRate: Double = 44100, micSpacing: Double = 0.10) {
        self.n = fftSize
        self.half = fftSize / 2
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.sampleRate = sampleRate
        self.micSpacing = micSpacing
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    private func realFFT(_ x: [Float]) -> ([Float], [Float]) {
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        x.withUnsafeBytes { xPtr in
            re.withUnsafeMutableBufferPointer { rBuf in
                im.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    vDSP_ctoz(xPtr.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
        }
        return (re, im)
    }

    func process(left: [Float], right: [Float]) -> DOAResult {
        let count = min(left.count, right.count, n)
        guard count >= 64 else { return .zero }

        // Window + pad
        var win = [Float](repeating: 0, count: n)
        vDSP_hann_window(&win, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var L = [Float](repeating: 0, count: n)
        var R = [Float](repeating: 0, count: n)
        for i in 0..<count { L[i] = left[i] * win[i]; R[i] = right[i] * win[i] }

        let (lRe, lIm) = realFFT(L)
        let (rRe, rIm) = realFFT(R)

        // Cross-spectrum G = L * conj(R), no PHAT normalization
        var gRe = [Float](repeating: 0, count: half)
        var gIm = [Float](repeating: 0, count: half)
        for i in 0..<half {
            gRe[i] = lRe[i]*rRe[i] + lIm[i]*rIm[i]
            gIm[i] = lIm[i]*rRe[i] - lRe[i]*rIm[i]
        }

        // IFFT
        var cRe = gRe, cIm = gIm
        cRe.withUnsafeMutableBufferPointer { r in
            cIm.withUnsafeMutableBufferPointer { i in
                var s = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(fftSetup, &s, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        var corr = [Float](repeating: 0, count: n)
        corr.withUnsafeMutableBytes { cPtr in
            cRe.withUnsafeMutableBufferPointer { r in
                cIm.withUnsafeMutableBufferPointer { i in
                    var s = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_ztoc(&s, 1, cPtr.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }

        // Search peak in valid lag range
        let maxLag = min(half - 1, Int(sampleRate * micSpacing / speedOfSound * 2.5) + 5)
        var peakVal: Float = -Float.infinity
        var peakIdx = 0
        for i in 0...maxLag {
            if corr[i] > peakVal { peakVal = corr[i]; peakIdx = i }
        }
        for i in (n - maxLag)..<n {
            if corr[i] > peakVal { peakVal = corr[i]; peakIdx = i }
        }

        let signedLag = peakIdx > n/2 ? peakIdx - n : peakIdx
        var refined = Float(signedLag)
        if peakIdx > 0 && peakIdx < n - 1 {
            let y1 = corr[peakIdx-1], y2 = corr[peakIdx], y3 = corr[peakIdx+1]
            let d = 2*(2*y2 - y1 - y3)
            if abs(d) > 1e-10 { refined = Float(signedLag) + (y3-y1)/d }
        }

        let delay = Double(refined) / sampleRate
        let ratio = max(-1.0, min(1.0, delay * speedOfSound / micSpacing))
        let angle = asin(ratio) * 180.0 / .pi

        // Confidence: peak-to-mean ratio
        var meanAbs: Float = 0
        var absBuf = Array(corr.prefix(half))
        vDSP_vabs(absBuf, 1, &absBuf, 1, vDSP_Length(half))
        vDSP_meanv(absBuf, 1, &meanAbs, vDSP_Length(half))
        let conf = meanAbs > 1e-10 ? min(1.0, Double(abs(peakVal) / (meanAbs * 4.0))) : 0

        var diffE: Float = 0
        for i in 0..<count { let d = left[i]-right[i]; diffE += d*d }
        let diffRMS = sqrt(diffE / Float(count))

        return DOAResult(angle: angle, confidence: max(0, conf), timestamp: .now,
            metadata: ["delaySamples": Double(refined), "delayUs": delay*1e6,
                       "peakCorr": Double(abs(peakVal)), "diffRMS": Double(diffRMS)])
    }
}
