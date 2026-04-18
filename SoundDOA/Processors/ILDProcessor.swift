import Accelerate
import Foundation

/// ILD processor using time-domain bandpass filtering + RMS
final class ILDProcessor: @unchecked Sendable {
    let sampleRate: Float

    /// Stateful 2nd-order IIR bandpass filter
    struct BandPass {
        let b0, b1, b2, a1, a2: Float

        // Filter state — persists across frames
        var x1: Float = 0, x2: Float = 0
        var y1: Float = 0, y2: Float = 0

        init(lowHz: Float, highHz: Float, fs: Float) {
            let fl = lowHz / fs
            let fh = highHz / fs
            let center = sqrt(fl * fh)
            let bw = fh - fl
            let r = 1 - 3 * bw
            let cosVal = cos(2 * .pi * center)
            let k = (1 - 2 * r * cosVal + r * r) / (2 * (1 - r * cosVal))
            a1 = 2 * r * cosVal
            a2 = -r * r
            b0 = 1 - k
            b1 = 2 * (k - r) * cosVal
            b2 = r * r - k
        }

        /// Process samples in-place, updating internal state
        mutating func process(_ input: [Float]) -> [Float] {
            var output = [Float](repeating: 0, count: input.count)
            for i in 0..<input.count {
                let x0 = input[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x0
                y2 = y1; y1 = y0
                output[i] = y0
            }
            return output
        }
    }

    static let bandNames = ["Low 0-500Hz", "Mid 500-2kHz", "High 2-8kHz"]
    static let bandLimits: [(low: Float, high: Float)] = [
        (100, 500),
        (500, 2000),
        (2000, 8000)
    ]

    // Persistent filter state across frames
    private var filtersL: [BandPass] = []
    private var filtersR: [BandPass] = []

    init(fftSize: Int = 2048, sampleRate: Float = 44100) {
        self.sampleRate = sampleRate
        // Create persistent filters
        for band in Self.bandLimits {
            filtersL.append(BandPass(lowHz: band.low, highHz: band.high, fs: sampleRate))
            filtersR.append(BandPass(lowHz: band.low, highHz: band.high, fs: sampleRate))
        }
    }

    func process(left: [Float], right: [Float]) -> DOAResult {
        let n = min(left.count, right.count)

        // Overall RMS ILD (time-domain, no filtering)
        var rmsL: Float = 0, rmsR: Float = 0
        vDSP_rmsqv(left, 1, &rmsL, vDSP_Length(n))
        vDSP_rmsqv(right, 1, &rmsR, vDSP_Length(n))

        let ildOverall: Float
        if rmsL > 1e-8 && rmsR > 1e-8 {
            ildOverall = 20.0 * log10f(rmsL / rmsR)
        } else {
            ildOverall = 0
        }

        // Per-band ILD using persistent filters
        var bandILDs: [Float] = []

        for i in 0..<filtersL.count {
            let filteredL = filtersL[i].process(left)
            let filteredR = filtersR[i].process(right)

            var eL: Float = 0, eR: Float = 0
            vDSP_rmsqv(filteredL, 1, &eL, vDSP_Length(n))
            vDSP_rmsqv(filteredR, 1, &eR, vDSP_Length(n))

            if eL > 1e-10 && eR > 1e-10 {
                bandILDs.append(20.0 * log10f(eL / eR))
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

        let clampedILD = max(-25, min(25, weightedILD))
        let angle = Double(clampedILD / 25.0 * 90.0)

        let maxRms = max(rmsL, rmsR)
        let confidence = min(1.0, Double(maxRms) * 20.0)

        var metadata: [String: Double] = ["ildOverall": Double(ildOverall)]
        for (i, ild) in bandILDs.enumerated() {
            metadata["ildBand\(i)"] = Double(ild)
        }

        return DOAResult(angle: angle, confidence: confidence, timestamp: .now, metadata: metadata)
    }
}
