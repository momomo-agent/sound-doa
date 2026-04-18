import AVFoundation
import Accelerate
import Combine
import Foundation
import SwiftUI

// MARK: - Audio Capture (no ObservableObject, pure callback)

final class AudioCapture {
    private var engine: AVAudioEngine?
    private var timer: Timer?
    var onResult: ((DOAResult) -> Void)?
    var onError: ((String) -> Void)?
    var onLevels: (([Float], [Float]) -> Void)?

    var selectedAlgorithm: DOAAlgorithm = .tdoa
    private var actualSampleRate: Double = 44100

    private var latestLeft: [Float]?
    private var latestRight: [Float]?

    private var tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: 44100, micSpacing: 0.10)
    private var ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: 44100)

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])

            // Try to select stereo input (non-fatal if fails)
            if let inputs = session.availableInputs,
               let port = inputs.first,
               let sources = port.dataSources,
               let front = sources.first(where: { $0.dataSourceName == "Front" }) {
                try? port.setPreferredDataSource(front)
                if front.supportedPolarPatterns?.contains(.stereo) == true {
                    try? front.setPreferredPolarPattern(.stereo)
                }
            }

            // Try stereo channels (non-fatal — device might not support it)
            try? session.setPreferredInputNumberOfChannels(2)
            try session.setActive(true)

            let eng = AVAudioEngine()
            self.engine = eng
            let input = eng.inputNode
            let format = input.inputFormat(forBus: 0)
            actualSampleRate = format.sampleRate

            print("[SoundDOA] Format: \(format.channelCount)ch @ \(format.sampleRate)Hz")

            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.handleBuffer(buffer)
            }

            try eng.start()
            print("[SoundDOA] Engine started (\(actualSampleRate)Hz, \(format.channelCount)ch)")

            // Create processors with actual device sample rate
            tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: actualSampleRate, micSpacing: 0.10)
            ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: Float(actualSampleRate))

            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.processBuffer()
            }

        } catch {
            print("[SoundDOA] Error: \(error)")
            onError?(error.localizedDescription)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        print("[SoundDOA] Engine stopped")
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, let ch = buffer.floatChannelData else { return }

        if channels >= 2 {
            latestLeft = Array(UnsafeBufferPointer(start: ch[0], count: frames))
            latestRight = Array(UnsafeBufferPointer(start: ch[1], count: frames))
        } else {
            let mono = Array(UnsafeBufferPointer(start: ch[0], count: frames))
            latestLeft = mono
            latestRight = mono
        }
    }

    private func processBuffer() {
        guard let left = latestLeft, let right = latestRight else { return }
        latestLeft = nil
        latestRight = nil

        let result: DOAResult
        switch selectedAlgorithm {
        case .tdoa:
            result = tdoaProcessor.process(left: left, right: right)
        case .ild:
            result = ildProcessor.process(left: left, right: right)
        }
        onResult?(result)

        let blockSize = left.count / 32
        guard blockSize > 0 else { return }
        var lLevels = [Float](repeating: 0, count: 32)
        var rLevels = [Float](repeating: 0, count: 32)
        for i in 0..<32 {
            let s = i * blockSize
            let e = min(s + blockSize, left.count)
            vDSP_rmsqv(Array(left[s..<e]), 1, &lLevels[i], vDSP_Length(e - s))
            vDSP_rmsqv(Array(right[s..<e]), 1, &rLevels[i], vDSP_Length(e - s))
        }
        onLevels?(lLevels, rLevels)
    }
}

// MARK: - ContentView (all state via @State)

struct ContentView: View {
    @State private var isRunning = false
    @State private var selectedAlgorithm: DOAAlgorithm = .tdoa
    @State private var result: DOAResult = .zero
    @State private var errorMessage: String?
    @State private var leftLevels: [Float] = Array(repeating: 0, count: 32)
    @State private var rightLevels: [Float] = Array(repeating: 0, count: 32)
    @State private var micSpacing: Double = 0.10

    private let capture = AudioCapture()

    #if targetEnvironment(simulator)
    private let isSimulator = true
    #else
    private let isSimulator = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Algorithm picker
                    Picker("Algorithm", selection: $selectedAlgorithm) {
                        ForEach(DOAAlgorithm.allCases, id: \.self) { algo in
                            Text(algo.rawValue).tag(algo)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedAlgorithm) { _, newValue in
                        capture.selectedAlgorithm = newValue
                    }

                    // Direction indicator
                    HStack {
                        Spacer()
                        DirectionIndicatorView(result: result)
                            .frame(width: 260, height: 260)
                        Spacer()
                    }
                    .padding(.vertical, 10)

                    // Angle display
                    VStack(spacing: 4) {
                        Text("\(Int(result.angle))°")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Confidence \(String(format: "%.0f%%", result.confidence * 100))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    // Metrics panel
                    MetricsView(result: result, algorithm: selectedAlgorithm)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)

                    // Waveforms
                    VStack(alignment: .leading, spacing: 8) {
                        WaveformView(levels: leftLevels, label: "Left", color: .blue)
                        WaveformView(levels: rightLevels, label: "Right", color: .orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                    // Mic spacing slider
                    HStack {
                        Text("Mic spacing")
                        Slider(value: $micSpacing, in: 0.02...0.20, step: 0.01)
                        Text("\(String(format: "%.0f", micSpacing * 100))cm")
                            .font(.caption)
                            .frame(width: 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .onChange(of: micSpacing) { _, newValue in
                        // Restart with new spacing (recreate processor internally)
                        if isRunning {
                            capture.stop()
                            isRunning = false
                            // Note: spacing change needs processor recreation, simplified for now
                        }
                    }

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
                    if isSimulator {
                        Label("Demo", systemImage: "waveform.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                    } else {
                        Button {
                            print("[SoundDOA] Button tapped! isRunning=\(isRunning)")
                            if isRunning {
                                capture.stop()
                                isRunning = false
                                result = .zero
                            } else {
                                errorMessage = nil
                                capture.onResult = { r in
                                    Task { @MainActor in
                                        result = r
                                    }
                                }
                                capture.onLevels = { l, r in
                                    Task { @MainActor in
                                        leftLevels = l
                                        rightLevels = r
                                    }
                                }
                                capture.onError = { msg in
                                    Task { @MainActor in
                                        errorMessage = msg
                                    }
                                }
                                capture.start()
                                isRunning = true
                            }
                        } label: {
                            Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(isRunning ? .red : .green)
                        }
                    }
                }
            }
        }
    }
}
