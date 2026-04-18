import AVFoundation
import Accelerate
import Combine
import Foundation
import SwiftUI

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

// MARK: - Audio Capture

final class AudioCapture {
    private var engine: AVAudioEngine?
    var onResult: ((DOAResult) -> Void)?
    var onError: ((String) -> Void)?
    var onLevels: (([Float], [Float]) -> Void)?

    var selectedAlgorithm: DOAAlgorithm = .tdoa
    private var actualSampleRate: Double = 44100

    private var latestLeft: [Float]?
    private var latestRight: [Float]?

    // Smoothing: weighted moving average, only high-energy frames
    private var angleHistory: [(angle: Double, weight: Double)] = []
    private let maxHistory = 8

    private var tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: 44100, micSpacing: 0.20)
    private var ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: 44100)

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)

            if let inputs = session.availableInputs {
                for port in inputs {
                    if let sources = port.dataSources {
                        for src in sources {
                            if src.supportedPolarPatterns?.contains(.stereo) == true {
                                try? port.setPreferredDataSource(src)
                                try? src.setPreferredPolarPattern(.stereo)
                                flog("[SoundDOA] Set stereo polar pattern on \(src.dataSourceName)")
                            }
                        }
                    }
                }
            }
            try? session.setPreferredInputNumberOfChannels(2)
            try session.setActive(false)
            try session.setActive(true)

            let eng = AVAudioEngine()
            self.engine = eng
            let input = eng.inputNode
            let format = input.inputFormat(forBus: 0)
            actualSampleRate = format.sampleRate

            flog("[SoundDOA] Format: \(format.channelCount)ch @ \(format.sampleRate)Hz")

            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.handleBuffer(buffer)
                self?.processBuffer()
            }

            try eng.start()
            flog("[SoundDOA] Engine started (\(actualSampleRate)Hz, \(format.channelCount)ch)")

            if format.channelCount < 2 {
                flog("[SoundDOA] WARNING: Got mono input, TDOA disabled. Using ILD only.")
                selectedAlgorithm = .ild
            }

            tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: actualSampleRate, micSpacing: 0.20)
            ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: Float(actualSampleRate))
        } catch {
            flog("[SoundDOA] Error: \(error)")
            onError?(error.localizedDescription)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        flog("[SoundDOA] tap: frames=\(frames) ch=\(ch)")

        if ch >= 2 {
            latestLeft = Array(UnsafeBufferPointer(start: floatData[0], count: frames))
            latestRight = Array(UnsafeBufferPointer(start: floatData[1], count: frames))
        } else {
            latestLeft = Array(UnsafeBufferPointer(start: floatData[0], count: frames))
            latestRight = latestLeft
        }

        // Send levels for visualization
        if let l = latestLeft, let r = latestRight {
            let step = max(1, l.count / 64)
            let lLevels = stride(from: 0, to: l.count, by: step).map { abs(l[$0]) }
            let rLevels = stride(from: 0, to: r.count, by: step).map { abs(r[$0]) }
            onLevels?(lLevels, rLevels)
        }
    }

    private func processBuffer() {
        guard let left = latestLeft, let right = latestRight, !left.isEmpty else {
            flog("[SoundDOA] processBuffer: no data")
            return
        }

        // Run both TDOA and ILD
        let tdoaResult = tdoaProcessor.process(left: left, right: right)
        let ildResult = ildProcessor.process(left: left, right: right)

        let diffRMS = tdoaResult.metadata["diffRMS"] ?? 0
        let peakCorr = tdoaResult.metadata["peakCorr"] ?? 0

        // Fusion: use TDOA angle when signal is strong, ILD for front/back disambiguation
        let result: DOAResult
        if diffRMS > 0.001 && peakCorr > 5 {
            // Signal present: trust TDOA for precise angle
            result = tdoaResult
        } else if diffRMS > 0.0005 {
            // Very weak signal: use ILD
            result = ildResult
        } else {
            // Silence: no update
            result = DOAResult(angle: 0, confidence: 0, timestamp: .now, metadata: ["silent": 1])
        }

        flog("[SoundDOA] fusion: angle=\(result.angle) conf=\(result.confidence) diffRMS=\(diffRMS) peak=\(peakCorr) algo=\(diffRMS > 0.003 ? "TDOA" : diffRMS > 0.001 ? "ILD" : "silent")")

        // Weighted smoothing: higher energy = more weight
        if result.confidence > 0.1 && diffRMS > 0.0005 {
            let weight = diffRMS * result.confidence
            angleHistory.append((angle: result.angle, weight: weight))
            if angleHistory.count > maxHistory { angleHistory.removeFirst() }
        }

        // Compute weighted average
        let totalWeight = angleHistory.reduce(0.0) { $0 + $1.weight }
        let smoothedAngle: Double
        if totalWeight > 0 {
            smoothedAngle = angleHistory.reduce(0.0) { $0 + $1.angle * $1.weight } / totalWeight
        } else {
            smoothedAngle = result.angle
        }

        let smoothed = DOAResult(
            angle: smoothedAngle,
            confidence: result.confidence,
            timestamp: .now,
            metadata: result.metadata
        )

        flog("[SoundDOA] smoothed: angle=\(smoothedAngle) conf=\(result.confidence) raw=\(result.angle)")
        onResult?(smoothed)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var currentAngle: Double = 0
    @State private var confidence: Double = 0
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var leftLevels: [Float] = []
    @State private var rightLevels: [Float] = []
    @State private var selectedAlgorithm: DOAAlgorithm = .tdoa
    @State private var micSpacing: Double = 0.20

    private let capture = AudioCapture()
    private let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    private func startRecording() {
        flog("[SoundDOA] startRecording() called")
        capture.selectedAlgorithm = selectedAlgorithm
        capture.onResult = { result in
            Task { @MainActor in
                currentAngle = result.angle
                confidence = result.confidence
            }
        }
        capture.onError = { err in
            Task { @MainActor in errorMessage = err }
        }
        capture.onLevels = { l, r in
            Task { @MainActor in leftLevels = l; rightLevels = r }
        }
        capture.start()
        isRunning = true
    }

    private func stopRecording() {
        capture.stop()
        isRunning = false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Direction indicator
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                            .frame(width: 200, height: 200)

                        // Cardinal markers
                        ForEach([0, 90, 180, 270], id: \.self) { deg in
                            let rad = Double(deg) * .pi / 180 - .pi/2
                            Text(["N","E","S","W"][deg/90])
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .offset(x: cos(rad) * 110, y: sin(rad) * 110)
                        }

                        // Angle arc (shows range)
                        if confidence > 0.1 {
                            let startAngle = Angle(degrees: currentAngle - 5)
                            let endAngle = Angle(degrees: currentAngle + 5)
                            Path { path in
                                path.addArc(center: CGPoint(x: 100, y: 100),
                                           radius: 90,
                                           startAngle: startAngle - .degrees(90),
                                           endAngle: endAngle - .degrees(90),
                                           clockwise: false)
                            }
                            .stroke(Color.orange.opacity(0.3), lineWidth: 20)
                            .frame(width: 200, height: 200)
                        }

                        // Direction arrow
                        let arrowAngle = currentAngle * .pi / 180 - .pi/2
                        let arrowLen = 80.0 * min(1.0, confidence + 0.3)
                        Path { path in
                            path.move(to: CGPoint(x: 100, y: 100))
                            path.addLine(to: CGPoint(
                                x: 100 + cos(arrowAngle) * arrowLen,
                                y: 100 + sin(arrowAngle) * arrowLen))
                        }
                        .stroke(confidence > 0.3 ? Color.red : Color.red.opacity(0.4), lineWidth: 3)
                        .frame(width: 200, height: 200)

                        // Center dot
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }

                    // Angle readout
                    VStack(spacing: 4) {
                        Text(String(format: "%.1f°", currentAngle))
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                        Text(String(format: "Confidence: %.0f%%", confidence * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(directionLabel(for: currentAngle))
                            .font(.headline)
                            .foregroundStyle(.blue)
                    }

                    // Waveform
                    if !leftLevels.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("L/R Waveform")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 0) {
                                ForEach(0..<min(leftLevels.count, rightLevels.count), id: \.self) { i in
                                    VStack(spacing: 0) {
                                        Rectangle()
                                            .fill(Color.blue.opacity(0.6))
                                            .frame(width: 3, height: CGFloat(leftLevels[i]) * 100)
                                        Rectangle()
                                            .fill(Color.green.opacity(0.6))
                                            .frame(width: 3, height: CGFloat(rightLevels[i]) * 100)
                                    }
                                }
                            }
                            .frame(height: 60)
                            .clipped()
                        }
                        .padding(.horizontal)
                    }

                    // Controls
                    VStack(spacing: 12) {
                        Picker("Algorithm", selection: $selectedAlgorithm) {
                            ForEach(DOAAlgorithm.allCases, id: \.self) { algo in
                                Text(algo.rawValue).tag(algo)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedAlgorithm) { _, newValue in
                            capture.selectedAlgorithm = newValue
                        }

                        HStack {
                            Text("Virtual Spacing")
                            Slider(value: $micSpacing, in: 0.05...0.40, step: 0.01)
                            Text("\(String(format: "%.0f", micSpacing * 100))cm")
                        }
                    }
                    .padding(.horizontal)

                    if let err = errorMessage, !isSimulator {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Sound DOA")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if isRunning { stopRecording() } else { startRecording() }
                    } label: {
                        Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isRunning ? .red : .green)
                    }
                }
            }
            .onAppear {
                if !isRunning && !isSimulator {
                    startRecording()
                }
            }
        }
    }

    private func directionLabel(for angle: Double) -> String {
        let a = ((angle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        switch a {
        case 337.5...360, 0..<22.5: return "Front"
        case 22.5..<67.5: return "Front-Right"
        case 67.5..<112.5: return "Right"
        case 112.5..<157.5: return "Back-Right"
        case 157.5..<202.5: return "Back"
        case 202.5..<247.5: return "Back-Left"
        case 247.5..<292.5: return "Left"
        case 292.5..<337.5: return "Front-Left"
        default: return ""
        }
    }
}
