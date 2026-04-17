import Accelerate
import Foundation

/// ILD (Interaural Level Difference) processor
final class ILDProcessor: @unchecked Sendable {
    let fftSize: Int
    let sampleRate: Float
    private let halfN: Int

    private let fftSetup: vDSP_DFT_Setup
    private let windowPtr: UnsafeMutablePointer<Float>
    private let zerosInputImag: UnsafeMutablePointer<Float>

    static let bandNames = ["Low 0-500Hz", "Mid 500-2kHz", "High 2-8kHz"]
    static let bandLimits: [(low: Float, high: Float)] = [
        (0, 500),
        (500, 2000),
        (2000, 8000)
    ]

    init(fftSize: Int = 2048, sampleRate: Float = 16000) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.halfN = fftSize / 2 + 1

        self.fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!

        self.windowPtr = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        vDSP_hann_window(windowPtr, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

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

        // Overall time-domain RMS ILD
        var rmsL: Float = 0
        var rmsR: Float = 0
        vDSP_rmsqv(left, 1, &rmsL, vDSP_Length(n))
        vDSP_rmsqv(right, 1, &rmsR, vDSP_Length(n))

        let ildOverall: Float
        if rmsL > 1e-10 && rmsR > 1e-10 {
            ildOverall = 20.0 * log10f(rmsL / rmsR)
        } else {
            ildOverall = 0
        }

        // Per-band ILD from frequency domain
        let binWidth = sampleRate / Float(fftSize)
        var bandILDs: [Float] = []

        for band in Self.bandLimits {
            let binStart = max(1, Int(band.low / binWidth))
            let binEnd = min(halfN - 1, Int(band.high / binWidth))
            let count = max(1, binEnd - binStart)

            var eL: Float = 0
            var eR: Float = 0
            for b in binStart..<binEnd {
                eL += lRealOut[b] * lRealOut[b] + lImagOut[b] * lImagOut[b]
                eR += rRealOut[b] * rRealOut[b] + rImagOut[b] * rImagOut[b]
            }

            let avgEL = eL / Float(count)
            let avgER = eR / Float(count)

            if avgEL > 1e-12 && avgER > 1e-12 {
                bandILDs.append(10.0 * log10f(avgEL / avgER))
            } else {
                bandILDs.append(0)
            }
        }

        // Weighted angle: high-freq ILD more directional
        let weights: [Float] = [1, 2, 4]
        var weightedILD: Float = 0
        var totalWeight: Float = 0
        for (i, ild) in bandILDs.enumerated() {
            weightedILD += ild * weights[i]
            totalWeight += weights[i]
        }
        weightedILD /= totalWeight

        // Map ILD to angle: -25dB → -90°, 0 → 0°, +25dB → +90°
        let clampedILD = max(-25, min(25, weightedILD))
        let angle = Double(clampedILD / 25.0 * 90.0)

        let maxRms = max(rmsL, rmsR)
        let confidence = min(1.0, Double(maxRms) * 20.0)

        var metadata: [String: Double] = [
            "ildOverall": Double(ildOverall),
        ]
        for (i, ild) in bandILDs.enumerated() {
            metadata["ildBand\(i)"] = Double(ild)
        }

        return DOAResult(
            angle: angle,
            confidence: confidence,
            timestamp: .now,
            metadata: metadata
        )
    }
}
