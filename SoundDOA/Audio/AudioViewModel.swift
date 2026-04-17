import AVFoundation
import Accelerate
import Combine
import Foundation
import SwiftUI

/// ViewModel bridging audio capture and processors to the UI
@MainActor
@Observable
final class AudioViewModel {
    // MARK: - Published state
    var isRunning = false
    var selectedAlgorithm: DOAAlgorithm = .tdoa
    var currentResult: DOAResult = .zero
    var errorMessage: String?
    var leftLevels: [Float] = Array(repeating: 0, count: 32)
    var rightLevels: [Float] = Array(repeating: 0, count: 32)
    var micSpacing: Double = 0.10  // meters

    // MARK: - Private
    private let captureManager = AudioCaptureManager()
    private var tdoaProcessor: TDOAProcessor?
    private var ildProcessor: ILDProcessor?
    private var updateTimer: Timer?
    private var pendingLeft: [Float]?
    private var pendingRight: [Float]?

    init() {
        tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: 16000, micSpacing: micSpacing)
        ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: 16000)
    }

    // MARK: - Actions

    func toggleRecording() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        errorMessage = nil

        captureManager.onBuffer = { [weak self] left, right in
            // Store latest buffer for UI processing
            // Processing happens on a timer to avoid blocking audio thread
            self?.pendingLeft = left
            self?.pendingRight = right
        }

        do {
            try captureManager.start()
            isRunning = true

            // Process at ~20fps
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.processBuffer()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        captureManager.stop()
        isRunning = false
        currentResult = .zero
    }

    func setMicSpacing(_ spacing: Double) {
        micSpacing = spacing
        tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: 16000, micSpacing: spacing)
    }

    // MARK: - Processing

    private func processBuffer() {
        guard let left = pendingLeft, let right = pendingRight else { return }
        pendingLeft = nil
        pendingRight = nil

        let result: DOAResult
        switch selectedAlgorithm {
        case .tdoa:
            result = tdoaProcessor?.process(left: left, right: right) ?? .zero
        case .ild:
            result = ildProcessor?.process(left: left, right: right) ?? .zero
        }
        currentResult = result

        // Update waveform levels
        let blockSize = left.count / 32
        if blockSize > 0 {
            for i in 0..<32 {
                let start = i * blockSize
                let end = min(start + blockSize, left.count)
                var rmsL: Float = 0
                var rmsR: Float = 0
                left[start..<end].withUnsafeBufferPointer { ptr in
                    vDSP_rmsqv(ptr.baseAddress!, 1, &rmsL, vDSP_Length(end - start))
                }
                right[start..<end].withUnsafeBufferPointer { ptr in
                    vDSP_rmsqv(ptr.baseAddress!, 1, &rmsR, vDSP_Length(end - start))
                }
                leftLevels[i] = rmsL
                rightLevels[i] = rmsR
            }
        }
    }
}
