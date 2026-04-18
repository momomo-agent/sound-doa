import Foundation

enum DOAAlgorithm: String, CaseIterable {
    case tdoa = "TDOA"
    case ild = "ILD"
}

/// Audio capture mode — each uses different AVAudioSession configuration
enum CaptureMode: String, CaseIterable, Identifiable {
    case stereoDefault = "Stereo Default"
    case stereoOmni = "Stereo+Omni"
    case stereoFrontBack = "Front vs Back"
    case rawAudioUnit = "Raw AudioUnit"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .stereoDefault: return "Stereo polar pattern, default mode"
        case .stereoOmni: return "Default mode, omnidirectional pattern (no beamforming)"
        case .stereoFrontBack: return "Compare front mic vs back mic separately"
        case .rawAudioUnit: return "Low-level AudioUnit bypass (RemoteIO)"
        }
    }

    var systemImage: String {
        switch self {
        case .stereoDefault: return "waveform"
        case .stereoOmni: return "circle.dotted"
        case .stereoFrontBack: return "arrow.up.arrow.down"
        case .rawAudioUnit: return "cpu"
        }
    }
}

struct DOAResult: Sendable {
    let angle: Double          // degrees, -180 to 180
    let confidence: Double     // 0 to 1
    let timestamp: Date
    let metadata: [String: Double]

    static let zero = DOAResult(angle: 0, confidence: 0, timestamp: .now, metadata: [:])
}

/// Snapshot of one capture mode's state for comparison
struct CaptureSnapshot: Identifiable {
    let id = UUID()
    let mode: CaptureMode
    let channelCount: Int
    let sampleRate: Double
    let angle: Double
    let confidence: Double
    let diffRMS: Double
    let lag: Double
    let peakCorr: Double
    let ildDB: Double
    let rawLeft: [Float]   // first 64 samples
    let rawRight: [Float]  // first 64 samples
}
