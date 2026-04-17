import AVFoundation
import Accelerate
import Combine
import Foundation
import SwiftUI

/// ViewModel bridging audio capture and processors to the UI
final class AudioViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var selectedAlgorithm: DOAAlgorithm = .tdoa
    @Published var currentResult: DOAResult = .zero
    @Published var errorMessage: String?
    @Published var leftLevels: [Float] = Array(repeating: 0, count: 32)
    @Published var rightLevels: [Float] = Array(repeating: 0, count: 32)
    @Published var micSpacing: Double = 0.10
    @Published var isDemoMode: Bool = false

    private var engine: AVAudioEngine?
    private var tdoaProcessor: TDOAProcessor?
    private var ildProcessor: ILDProcessor?
    private var updateTimer: Timer?
    private var latestLeft: [Float]?
    private var latestRight: [Float]?

    #if targetEnvironment(simulator)
    private let runningOnSimulator = true
    #else
    private let runningOnSimulator = false
    #endif

    init() {
        isDemoMode = runningOnSimulator
        tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: 16000, micSpacing: micSpacing)
        ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: 16000)
    }

    func toggleRecording() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        errorMessage = nil
        guard !runningOnSimulator else {
            errorMessage = "Simulator has no microphone"
            return
        }

        // Don't explicitly request permission — AVAudioEngine.start()
        // implicitly triggers the iOS permission dialog on first mic access.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])

            // Try to select stereo input (front mic + stereo polar pattern)
            if let inputs = session.availableInputs,
               let port = inputs.first,
               let sources = port.dataSources,
               let front = sources.first(where: { $0.dataSourceName == "Front" }) {
                try port.setPreferredDataSource(front)
                if front.supportedPolarPatterns?.contains(.stereo) == true {
                    try front.setPreferredPolarPattern(.stereo)
                }
            }

            try session.setPreferredSampleRate(16000)
            try session.setPreferredInputNumberOfChannels(2)
            try session.setActive(true)

            let eng = AVAudioEngine()
            self.engine = eng
            let input = eng.inputNode
            let format = input.inputFormat(forBus: 0)

            guard format.channelCount >= 1 else {
                errorMessage = "No input channels available"
                return
            }

            print("[SoundDOA] Input: \(format.channelCount)ch @ \(format.sampleRate)Hz")

            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                self.handleBuffer(buffer)
            }

            try eng.start()
            isRunning = true
            print("[SoundDOA] Engine started")

            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.processBuffer()
            }

        } catch {
            errorMessage = error.localizedDescription
            print("[SoundDOA] Error: \(error)")
        }
    }

    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
        currentResult = .zero
    }

    func setMicSpacing(_ spacing: Double) {
        micSpacing = spacing
        tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: 16000, micSpacing: spacing)
    }

    // MARK: - Audio handling

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
            result = tdoaProcessor?.process(left: left, right: right) ?? .zero
        case .ild:
            result = ildProcessor?.process(left: left, right: right) ?? .zero
        }
        currentResult = result

        let blockSize = left.count / 32
        guard blockSize > 0 else { return }
        var newL = [Float](repeating: 0, count: 32)
        var newR = [Float](repeating: 0, count: 32)
        for i in 0..<32 {
            let s = i * blockSize
            let e = min(s + blockSize, left.count)
            vDSP_rmsqv(Array(left[s..<e]), 1, &newL[i], vDSP_Length(e - s))
            vDSP_rmsqv(Array(right[s..<e]), 1, &newR[i], vDSP_Length(e - s))
        }
        leftLevels = newL
        rightLevels = newR
    }
}
