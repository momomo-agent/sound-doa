# SoundDOA Demo App — Implementation Spec

## Overview
iOS app that detects the direction of a sound source (voice) relative to the iPhone using its built-in stereo microphone array. The app supports two detection algorithms that can be toggled in real-time.

## Architecture

### Audio Engine (`AudioCaptureManager`)
- Uses `AVAudioEngine` with stereo input
- Configures `AVAudioSession` with `.playAndRecord` category
- Selects built-in microphone, sets preferred data source to "Front" (or "Back"), sets polar pattern to `.stereo`
- Installs an input tap on the input node to get 2-channel PCM audio buffers
- Feeds audio buffers to the active algorithm processor
- Must handle microphone permission request

### Algorithm 1: TDOA via GCC-PHAT (`TDOAProcessor`)
- Receives 2-channel PCM float buffers
- For each frame (~50ms window, ~25ms hop):
  1. Apply Hann window to both channels
  2. Compute FFT of both channels using Accelerate framework (vDSP)
  3. Compute cross-power spectrum: `X1(f) * conj(X2(f))`
  4. Normalize by magnitude (PHAT weighting): `R(f) = X1*conj(X2) / |X1*conj(X2)|`
  5. IFFT to get cross-correlation
  6. Find peak index → convert to time delay τ
  7. Convert τ to angle: `θ = asin(τ * c / d)` where c=343 m/s, d=microphone spacing (configurable, default 0.10m)
- Output: estimated angle in degrees (-90 to +90), confidence (peak height relative to mean)
- Use `Accelerate` framework for all FFT/vector operations (vDSP_fft_zrip, etc.)

### Algorithm 2: ILD — Interaural Level Difference (`ILDProcessor`)
- Receives 2-channel PCM float buffers
- For each frame (~50ms window):
  1. Compute RMS energy of left channel and right channel separately
  2. Compute ILD in dB: `20 * log10(rms_left / rms_right)`
  3. Compute per-band ILD: split into frequency bands (low: 0-500Hz, mid: 500-2000Hz, high: 2000-8000Hz) using band-pass filters or STFT bin grouping
  4. High-frequency ILD is more directional (shorter wavelength → more shadowing by phone body)
  5. Weighted combination of band ILDs → estimated angle
- Output: estimated angle in degrees, per-band ILD values for visualization
- Calibration mode: record ILD fingerprints from known directions, store as reference

### UI (`ContentView`)
SwiftUI interface with:

1. **Direction Indicator** (center, large):
   - Circular radar-style view
   - Phone icon in center
   - Arrow/dot showing estimated sound direction
   - Angle text label
   - Confidence indicator (opacity or size of the dot)

2. **Algorithm Picker** (top):
   - Segmented control: "TDOA" | "ILD"
   - Switching instantly changes the active processor

3. **Real-time Metrics** (bottom panel):
   - TDOA mode: show time delay (μs), peak correlation value, estimated angle
   - ILD mode: show ILD (dB) per band (low/mid/high), overall ILD, estimated angle

4. **Controls**:
   - Start/Stop button
   - Microphone source picker (Front/Back) if available

5. **Raw Waveform** (optional, small):
   - Two horizontal waveform strips showing left and right channel levels

### Data Flow
```
Microphone → AVAudioEngine (stereo tap) → AudioCaptureManager
  → TDOAProcessor or ILDProcessor (based on selection)
  → DOAResult { angle: Double, confidence: Double, metadata: [String: Double] }
  → Published to SwiftUI via @Observable AudioViewModel
  → UI updates at ~20fps (throttled)
```

### Key Types
```swift
struct DOAResult {
    let angle: Double        // -180 to 180 degrees (0 = front)
    let confidence: Double   // 0.0 to 1.0
    let timestamp: Date
    let metadata: [String: Double]  // algorithm-specific values
}

enum DOAAlgorithm: String, CaseIterable {
    case tdoa = "TDOA"
    case ild = "ILD"
}
```

## Technical Notes
- All DSP must use Accelerate framework (vDSP) for performance
- Audio processing on a dedicated queue, not main thread
- UI updates throttled to ~20fps via Combine/Timer
- FFT size: 2048 samples (at 16kHz = 128ms window, good enough for voice)
- Hop size: 1024 samples (50% overlap)
- Microphone spacing parameter should be adjustable (slider in settings)
- The app should work on real device only (simulator has no stereo mic)

## File Structure
```
SoundDOA/
  SoundDOAApp.swift          — App entry
  ContentView.swift           — Main UI with algorithm picker + direction view
  Views/
    DirectionIndicatorView.swift  — Radar/compass direction visualization
    MetricsView.swift             — Real-time algorithm metrics display
    WaveformView.swift            — Left/right channel waveform
  Audio/
    AudioCaptureManager.swift     — AVAudioEngine setup + stereo capture
    AudioViewModel.swift          — @Observable view model bridging audio → UI
  Processors/
    DOAResult.swift               — Shared result type
    TDOAProcessor.swift           — GCC-PHAT algorithm
    ILDProcessor.swift            — Interaural Level Difference algorithm
    DSPUtils.swift                — Accelerate/vDSP helpers (FFT, windowing, etc.)
```

## Build Requirements
- iOS 17.0+
- Swift 6.0
- No external dependencies (Accelerate framework only)
- Real device required for testing
