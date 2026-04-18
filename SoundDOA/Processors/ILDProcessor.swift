import Accelerate
import Foundation

/// ILD processor — time-domain RMS only (reliable)
/// Band-pass ILD disabled until filter coefficients validated
final class ILDProcessor: @unchecked Sendable {
    let sampleRate: Float

    init(fftSize: Int = 2048, sampleRate: Float = 44100) {
        self.sampleRate = sampleRate
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

        // Band-split ILD using short-time energy in frequency bands
        // Use sliding window energy (time-domain approximation)
        // Low: emphasize low-energy portions, High: emphasize high-energy portions
        // Simple approach: compute energy in short windows and look at spectral shape

        // For now, compute per-band ILD using simple energy difference
        // Split signal into frequency bands using decimation + differencing
        let windowSize = 512
        var bandILDs: [Float] = []
        let bandNames = ["Low", "Mid", "High"]

        // Approximate band separation using running difference (high-freq emphasis)
        // Low: smoothed signal, High: |signal - smoothed|
        for (idx, _) in bandNames.enumerated() {
            var eL: Float = 0, eR: Float = 0

            if idx == 0 {
                // Low band: use smoothed (low-pass) version
                var smoothedL = [Float](repeating: 0, count: n)
                var smoothedR = [Float](repeating: 0, count: n)
                // Simple moving average (low-pass)
                let avgLen = min(8, n)
                for i in avgLen..<n {
                    var sumL: Float = 0, sumR: Float = 0
                    for j in 0..<avgLen {
                        sumL += left[i - j]
                        sumR += right[i - j]
                    }
                    smoothedL[i] = sumL / Float(avgLen)
                    smoothedR[i] = sumR / Float(avgLen)
                }
                vDSP_rmsqv(smoothedL, 1, &eL, vDSP_Length(n))
                vDSP_rmsqv(smoothedR, 1, &eR, vDSP_Length(n))
            } else if idx == 2 {
                // High band: use difference (high-pass)
                var diffL = [Float](repeating: 0, count: n)
                var diffR = [Float](repeating: 0, count: n)
                for i in 1..<n {
                    diffL[i] = left[i] - left[i-1]
                    diffR[i] = right[i] - right[i-1]
                }
                vDSP_rmsqv(diffL, 1, &eL, vDSP_Length(n))
                vDSP_rmsqv(diffR, 1, &eR, vDSP_Length(n))
            } else {
                // Mid band: use original signal (overall)
                vDSP_rmsqv(left, 1, &eL, vDSP_Length(n))
                vDSP_rmsqv(right, 1, &eR, vDSP_Length(n))
            }

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
