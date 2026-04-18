import AVFoundation
import Accelerate
import Foundation

// MARK: - File Logger
func flog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sounddoa.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path) {
            if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() }
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Audio Capture Engine (one per mode)

final class AudioCaptureEngine {
    let mode: CaptureMode
    private var engine: AVAudioEngine?
    private var tdoaProcessor: TDOAProcessor?
    private var ildProcessor: ILDProcessor?

    var onResult: ((DOAResult, CaptureSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private var angleHistory: [(angle: Double, weight: Double)] = []
    private let maxHistory = 8

    init(mode: CaptureMode) {
        self.mode = mode
    }

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()

            // Configure based on mode
            switch mode {
            case .stereoDefault:
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
                try session.setActive(true)
                configureStereoPattern(session)

            case .measurement:
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
                try session.setActive(true)
                configureStereoPattern(session)

            case .rawMultiChannel:
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
                try session.setActive(true)
                configureStereoPattern(session)
                // Try private API: fixHardwareFormatToMultiChannel
                let sel = NSSelectorFromString("fixHardwareFormatToMultiChannel:error:")
                if session.responds(to: sel) {
                    flog("[SoundDOA][\(mode.rawValue)] fixHardwareFormatToMultiChannel available, calling...")
                    // Use ObjC-style invocation for error: parameter
                    typealias FixMultiChFunc = @convention(c) (AnyObject, Selector, Bool, UnsafeMutablePointer<NSError?>?) -> Bool
                    let imp = session.method(for: sel)
                    let fn = unsafeBitCast(imp, to: FixMultiChFunc.self)
                    var error: NSError?
                    let ok = fn(session, sel, true, &error)
                    flog("[SoundDOA][\(mode.rawValue)] fixHardwareFormatToMultiChannel ok=\(ok) error=\(String(describing: error))")
                } else {
                    flog("[SoundDOA][\(mode.rawValue)] fixHardwareFormatToMultiChannel NOT available")
                }
                // Re-activate
                try session.setActive(false)
                try session.setActive(true)

            case .voiceChat:
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .mixWithOthers])
                try session.setActive(true)
                configureStereoPattern(session)
            }

            try? session.setPreferredInputNumberOfChannels(2)
            // Re-activate after all configuration
            try session.setActive(false)
            try session.setActive(true)

            let eng = AVAudioEngine()
            self.engine = eng
            let input = eng.inputNode
            let format = input.inputFormat(forBus: 0)
            let sr = format.sampleRate
            let ch = format.channelCount

            flog("[SoundDOA][\(mode.rawValue)] Format: \(ch)ch @ \(sr)Hz interleaved=\(format.isInterleaved)")

            tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: sr, micSpacing: 0.20)
            ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: Float(sr))

            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.processBuffer(buffer, channelCount: Int(ch), sampleRate: sr)
            }

            try eng.start()
            flog("[SoundDOA][\(mode.rawValue)] Engine started")
        } catch {
            flog("[SoundDOA][\(mode.rawValue)] Error: \(error)")
            onError?("[\(mode.rawValue)] \(error.localizedDescription)")
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        angleHistory.removeAll()
    }

    private func configureStereoPattern(_ session: AVAudioSession) {
        if let inputs = session.availableInputs {
            for port in inputs {
                if let sources = port.dataSources {
                    for src in sources {
                        if src.supportedPolarPatterns?.contains(.stereo) == true {
                            try? port.setPreferredDataSource(src)
                            try? src.setPreferredPolarPattern(.stereo)
                            flog("[SoundDOA][\(mode.rawValue)] Set stereo on \(src.dataSourceName)")
                        }
                    }
                }
            }
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer, channelCount: Int, sampleRate: Double) {
        guard let floatData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)

        let left: [Float]
        let right: [Float]
        if channelCount >= 2 {
            left = Array(UnsafeBufferPointer(start: floatData[0], count: frames))
            right = Array(UnsafeBufferPointer(start: floatData[1], count: frames))
        } else {
            left = Array(UnsafeBufferPointer(start: floatData[0], count: frames))
            right = left
        }

        guard let tdoa = tdoaProcessor, let ild = ildProcessor else { return }

        let tdoaResult = tdoa.process(left: left, right: right)
        let ildResult = ild.process(left: left, right: right)

        let diffRMS = tdoaResult.metadata["diffRMS"] ?? 0
        let peakCorr = tdoaResult.metadata["peakCorr"] ?? 0
        let lag = tdoaResult.metadata["delaySamples"] ?? 0
        let ildDB = ildResult.metadata["ildOverall"] ?? 0

        // Fusion
        let result: DOAResult
        if diffRMS > 0.001 && peakCorr > 5 {
            result = tdoaResult
        } else if diffRMS > 0.0005 {
            result = ildResult
        } else {
            result = DOAResult(angle: 0, confidence: 0, timestamp: .now, metadata: ["silent": 1])
        }

        // Weighted smoothing
        if result.confidence > 0.1 && diffRMS > 0.0005 {
            let weight = diffRMS * result.confidence
            angleHistory.append((angle: result.angle, weight: weight))
            if angleHistory.count > maxHistory { angleHistory.removeFirst() }
        }

        let totalWeight = angleHistory.reduce(0.0) { $0 + $1.weight }
        let smoothedAngle = totalWeight > 0
            ? angleHistory.reduce(0.0) { $0 + $1.angle * $1.weight } / totalWeight
            : result.angle

        let smoothed = DOAResult(
            angle: smoothedAngle,
            confidence: result.confidence,
            timestamp: .now,
            metadata: result.metadata
        )

        let snapshot = CaptureSnapshot(
            mode: mode,
            channelCount: channelCount,
            sampleRate: sampleRate,
            angle: smoothedAngle,
            confidence: result.confidence,
            diffRMS: diffRMS,
            lag: lag,
            peakCorr: peakCorr,
            ildDB: ildDB,
            rawLeft: Array(left.prefix(64)),
            rawRight: Array(right.prefix(64))
        )

        flog("[SoundDOA][\(mode.rawValue)] angle=\(String(format:"%.1f", smoothedAngle)) lag=\(String(format:"%.1f", lag)) diffRMS=\(String(format:"%.4f", diffRMS)) peak=\(String(format:"%.0f", peakCorr)) ild=\(String(format:"%.2f", ildDB))dB ch=\(channelCount)")

        onResult?(smoothed, snapshot)
    }
}
