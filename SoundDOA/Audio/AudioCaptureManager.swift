import AVFoundation
import Accelerate
import Foundation

/// Manages AVAudioEngine stereo microphone capture
final class AudioCaptureManager: ObservableObject {
    private let engine = AVAudioEngine()

    var onBuffer: (([Float], [Float]) -> Void)?
    var isRunning: Bool { engine.isRunning }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        // Select built-in mic data source and stereo polar pattern
        if let inputs = session.availableInputs,
           let port = inputs.first,
           let sources = port.dataSources {
            if let front = sources.first(where: { $0.dataSourceName == "Front" }) {
                try port.setPreferredDataSource(front)
                if front.supportedPolarPatterns?.contains(.stereo) == true {
                    try front.setPreferredPolarPattern(.stereo)
                }
            }
        }

        try session.setPreferredSampleRate(16000)
        try session.setPreferredInputNumberOfChannels(2)

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        // Guard: we expect at least 1 channel from input
        guard format.channelCount >= 1 else {
            throw AudioError.noChannels
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0 else { return }

            let floatChannelData = buffer.floatChannelData!

            if channels >= 2 {
                let left = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frames))
                let right = Array(UnsafeBufferPointer(start: floatChannelData[1], count: frames))
                self.onBuffer?(left, right)
            } else {
                // Mono fallback: duplicate as both channels
                let mono = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frames))
                self.onBuffer?(mono, mono)
            }
        }

        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    enum AudioError: LocalizedError {
        case noChannels

        var errorDescription: String? {
            switch self {
            case .noChannels: return "No input channels available"
            }
        }
    }
}
