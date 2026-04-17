import Accelerate
import Foundation

/// TDOA (Time Difference of Arrival) processor using GCC-PHAT
final class TDOAProcessor: @unchecked Sendable {
    private let fftSize: Int
    private let sampleRate: Double
    private let micSpacing: Double
    private let speedOfSound: Double = 343.0
    private let halfN: Int  // fftSize / 2 + 1

    private let windowPtr: UnsafeMutablePointer<Float>
    private let zerosInputImag: UnsafeMutablePointer<Float>  // dummy zeros for real input
    private let fftSetup: vDSP_DFT_Setup

    init(fftSize: Int = 2048, sampleRate: Double = 16000, micSpacing: Double = 0.10) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.micSpacing = micSpacing
        self.halfN = fftSize / 2 + 1

        self.fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!

        self.windowPtr = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        vDSP_hann_window(windowPtr, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Zero array for imaginary input (real FFT input has no imaginary part)
        self.zerosInputImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        zerosInputImag.initialize(repeating: 0, count: fftSize)
    }

    deinit {
        vDSP_DFT_DestroySetup(fftSetup)
        windowPtr.deallocate()
        zerosInputImag.deallocate()
    }

    func process(left: [Float], right: [Float]) -> DOAResult {
        let n = min(left.count, right.count, fftSize)

        // Copy and window
        var lBuf = [Float](repeating: 0, count: fftSize)
        var rBuf = [Float](repeating: 0, count: fftSize)
        lBuf.replaceSubrange(0..<n, with: left[0..<n])
        rBuf.replaceSubrange(0..<n, with: right[0..<n])
        vDSP_vmul(lBuf, 1, windowPtr, 1, &lBuf, 1, vDSP_Length(fftSize))
        vDSP_vmul(rBuf, 1, windowPtr, 1, &rBuf, 1, vDSP_Length(fftSize))

        // FFT left: vDSP_DFT_Execute(setup, inputReal, inputImag, outputReal, outputImag)
        var lRealOut = [Float](repeating: 0, count: halfN)
        var lImagOut = [Float](repeating: 0, count: halfN)
        vDSP_DFT_Execute(fftSetup, &lBuf, zerosInputImag, &lRealOut, &lImagOut)

        // FFT right
        let fftSetupR = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!
        var rRealOut = [Float](repeating: 0, count: halfN)
        var rImagOut = [Float](repeating: 0, count: halfN)
        vDSP_DFT_Execute(fftSetupR, &rBuf, zerosInputImag, &rRealOut, &rImagOut)

        // GCC-PHAT: conj(L) * R, normalized by magnitude
        var corrReal = [Float](repeating: 0, count: halfN)
        var corrImag = [Float](repeating: 0, count: halfN)

        for i in 0..<halfN {
            let re = lRealOut[i] * rRealOut[i] + lImagOut[i] * rImagOut[i]
            let im = lRealOut[i] * rImagOut[i] - lImagOut[i] * rRealOut[i]
            let mag = sqrt(re * re + im * im)
            if mag > 1e-10 {
                corrReal[i] = re / mag
                corrImag[i] = im / mag
            }
        }

        // IFFT: create inverse setup
        let ifftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE)!
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        // For IFFT we need input size matching the FFT size
        // Pad halfN to fftSize for inverse
        var paddedReal = corrReal + [Float](repeating: 0, count: fftSize - halfN)
        var paddedImag = corrImag + [Float](repeating: 0, count: fftSize - halfN)

        vDSP_DFT_Execute(ifftSetup, &paddedReal, &paddedImag, &outReal, &outImag)

        // Find peak
        var peakVal: Float = -Float.infinity
        var peakIdx = 0
        for i in 0..<fftSize {
            let val = outReal[i]
            if val > peakVal {
                peakVal = val
                peakIdx = i
            }
        }

        // Delay: indices 0...N/2 = positive, N/2+1...N-1 = negative
        var delaySamples: Float
        if peakIdx <= fftSize / 2 {
            delaySamples = Float(peakIdx)
        } else {
            delaySamples = Float(peakIdx - fftSize)
        }

        // Angle
        let delaySeconds = Double(delaySamples) / sampleRate
        let ratio = delaySeconds * speedOfSound / micSpacing
        let clampedRatio = max(-1.0, min(1.0, ratio))
        let angleDegrees = asin(clampedRatio) * 180.0 / .pi

        // Confidence
        var mean: Float = 0
        vDSP_meanv(outReal, 1, &mean, vDSP_Length(fftSize))
        let confidence = abs(mean) > 1e-10 ? min(1.0, Double(abs(peakVal) / (abs(mean) * 3.0))) : 0

        return DOAResult(
            angle: angleDegrees,
            confidence: max(0, confidence),
            timestamp: .now,
            metadata: [
                "delaySamples": Double(delaySamples),
                "delayUs": delaySeconds * 1_000_000,
                "peakCorr": Double(abs(peakVal))
            ]
        )
    }
}
