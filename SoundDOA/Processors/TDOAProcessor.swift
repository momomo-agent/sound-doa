import Accelerate
import Foundation

/// TDOA processor using time-domain cross-correlation
/// with parabolic interpolation for sub-sample accuracy
final class TDOAProcessor: @unchecked Sendable {
    private let sampleRate: Double
    private let micSpacing: Double
    private let speedOfSound: Double = 343.0

    init(fftSize: Int = 2048, sampleRate: Double = 44100, micSpacing: Double = 0.10) {
        self.sampleRate = sampleRate
        self.micSpacing = micSpacing
    }

    func process(left: [Float], right: [Float]) -> DOAResult {
        let n = min(left.count, right.count)
        guard n >= 64 else { return .zero }

        // Use a centered window for cross-correlation
        let windowSize = min(n, 2048)
        let maxLag = min(windowSize / 4, Int(sampleRate * micSpacing / speedOfSound * 2) + 10)

        // Compute cross-correlation for lags in [-maxLag, maxLag]
        var corr = [Float](repeating: 0, count: 2 * maxLag + 1)

        // Use Accelerate for vectorized dot products
        for lag in -maxLag...maxLag {
            var dotProduct: Float = 0
            if lag >= 0 {
                let count = windowSize - lag
                if count > 0 {
                    vDSP_dotpr(left, 1, UnsafePointer(right).advanced(by: lag), 1, &dotProduct, vDSP_Length(count))
                }
            } else {
                let count = windowSize + lag
                if count > 0 {
                    vDSP_dotpr(UnsafePointer(left).advanced(by: -lag), 1, right, 1, &dotProduct, vDSP_Length(count))
                }
            }
            corr[lag + maxLag] = dotProduct
        }

        // Find peak
        var peakVal: Float = -Float.infinity
        var peakIdx = 0
        for i in 0..<corr.count {
            if corr[i] > peakVal {
                peakVal = corr[i]
                peakIdx = i
            }
        }

        // Parabolic interpolation for sub-sample accuracy
        var refinedLag = Float(peakIdx - maxLag)
        if peakIdx > 0 && peakIdx < corr.count - 1 {
            let y1 = corr[peakIdx - 1]
            let y2 = corr[peakIdx]
            let y3 = corr[peakIdx + 1]
            let denom = 2 * (2 * y2 - y1 - y3)
            if abs(denom) > 1e-10 {
                let delta = (y3 - y1) / denom
                refinedLag = Float(peakIdx - maxLag) + delta
            }
        }

        // Convert lag to delay in seconds
        let delaySeconds = Double(refinedLag) / sampleRate

        // Convert to angle
        let ratio = delaySeconds * speedOfSound / micSpacing
        let clampedRatio = max(-1.0, min(1.0, ratio))
        let angleDegrees = asin(clampedRatio) * 180.0 / .pi

        // Confidence: peak height relative to mean of correlation
        var mean: Float = 0
        vDSP_meanv(corr, 1, &mean, vDSP_Length(corr.count))
        let confidence = abs(mean) > 1e-10 ? min(1.0, Double(abs(peakVal) / (abs(mean) * 5.0))) : 0

        return DOAResult(
            angle: angleDegrees,
            confidence: max(0, confidence),
            timestamp: .now,
            metadata: [
                "delaySamples": Double(refinedLag),
                "delayUs": delaySeconds * 1_000_000,
                "peakCorr": Double(abs(peakVal))
            ]
        )
    }
}
