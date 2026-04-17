import Accelerate
import Foundation

/// Pre-computed Hann window
final class HannWindow {
    let size: Int
    let window: UnsafeMutablePointer<Float>

    init(size: Int) {
        self.size = size
        self.window = UnsafeMutablePointer<Float>.allocate(capacity: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { window.deallocate() }

    func apply(_ samples: inout [Float]) {
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(size))
    }
}

/// RMS computation
func computeRMS(_ samples: UnsafePointer<Float>, count: Int) -> Float {
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
    return rms
}
