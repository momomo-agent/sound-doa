import AVFoundation
import Accelerate
import AudioToolbox
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
    private var auUnit: AudioComponentInstance?
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
        if mode == .rawAudioUnit {
            startRawAudioUnit()
        } else {
            startAVAudioEngine()
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        if let au = auUnit {
            AudioOutputUnitStop(au)
            AudioComponentInstanceDispose(au)
            auUnit = nil
        }

        angleHistory.removeAll()
    }

    // MARK: - AVAudioEngine modes

    private func startAVAudioEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)

            // Log available inputs and data sources
            if let inputs = session.availableInputs {
                for port in inputs {
                    flog("[SoundDOA][\(mode.rawValue)] Input: \(port.portName) type=\(port.portType.rawValue)")
                    if let sources = port.dataSources {
                        for src in sources {
                            let patterns = src.supportedPolarPatterns?.map { $0.rawValue } ?? []
                            flog("[SoundDOA][\(mode.rawValue)]   Source: \(src.dataSourceName) id=\(src.dataSourceID) patterns=\(patterns)")
                        }
                    }
                }
            }

            switch mode {
            case .stereoDefault:
                // Set stereo polar pattern on all sources that support it
                configurePolarPattern(session, pattern: .stereo)

            case .stereoOmni:
                // Set omnidirectional — no beamforming, raw mic signal
                configurePolarPattern(session, pattern: .omnidirectional)

            case .stereoFrontBack:
                // Try to select specific data sources (front vs back)
                // First pass: just use stereo but log which source is active
                configurePolarPattern(session, pattern: .stereo)
                // Log the selected data source
                if let input = session.currentRoute.inputs.first {
                    flog("[SoundDOA][\(mode.rawValue)] Active input: \(input.portName) channels=\(input.channels?.count ?? 0)")
                    if let channels = input.channels {
                        for ch in channels {
                            flog("[SoundDOA][\(mode.rawValue)]   Channel: \(ch.channelName) label=\(ch.channelLabel) number=\(ch.channelNumber)")
                        }
                    }
                    flog("[SoundDOA][\(mode.rawValue)] Selected data source: \(input.selectedDataSource?.dataSourceName ?? "none")")
                }

            case .rawAudioUnit:
                break // handled separately
            }

            try? session.setPreferredInputNumberOfChannels(2)
            try session.setActive(false)
            try session.setActive(true)

            // Log final route info
            let route = session.currentRoute
            for input in route.inputs {
                flog("[SoundDOA][\(mode.rawValue)] Route input: \(input.portName) ch=\(input.channels?.count ?? 0) ds=\(input.selectedDataSource?.dataSourceName ?? "none")")
            }

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

    // MARK: - Raw AudioUnit (RemoteIO)

    private func startRawAudioUnit() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            configurePolarPattern(session, pattern: .stereo)
            try? session.setPreferredInputNumberOfChannels(2)
            try session.setActive(false)
            try session.setActive(true)

            // Create RemoteIO AudioUnit
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_RemoteIO,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            guard let component = AudioComponentFindNext(nil, &desc) else {
                flog("[SoundDOA][\(mode.rawValue)] RemoteIO component not found")
                onError?("RemoteIO not found")
                return
            }

            var unit: AudioComponentInstance?
            var status = AudioComponentInstanceNew(component, &unit)
            guard status == noErr, let au = unit else {
                flog("[SoundDOA][\(mode.rawValue)] AudioComponentInstanceNew failed: \(status)")
                onError?("AudioUnit create failed: \(status)")
                return
            }
            self.auUnit = au

            // Enable input
            var enableInput: UInt32 = 1
            status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                         kAudioUnitScope_Input, 1,
                                         &enableInput, UInt32(MemoryLayout<UInt32>.size))
            flog("[SoundDOA][\(mode.rawValue)] EnableIO input: \(status)")

            // Get hardware format
            var hwFormat = AudioStreamBasicDescription()
            var hwFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 1,
                               &hwFormat, &hwFormatSize)
            flog("[SoundDOA][\(mode.rawValue)] HW format: \(hwFormat.mChannelsPerFrame)ch @ \(hwFormat.mSampleRate)Hz bits=\(hwFormat.mBitsPerChannel) interleaved=\(hwFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)")

            // Set output format (what we receive in callback) to 2ch float
            var clientFormat = AudioStreamBasicDescription(
                mSampleRate: hwFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: max(hwFormat.mChannelsPerFrame, 2),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                         kAudioUnitScope_Output, 1,
                                         &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            flog("[SoundDOA][\(mode.rawValue)] Set client format \(clientFormat.mChannelsPerFrame)ch: \(status)")

            // Get actual output format
            var actualFormat = AudioStreamBasicDescription()
            var actualSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Output, 1,
                               &actualFormat, &actualSize)
            flog("[SoundDOA][\(mode.rawValue)] Actual output format: \(actualFormat.mChannelsPerFrame)ch @ \(actualFormat.mSampleRate)Hz")

            let sr = actualFormat.mSampleRate
            let ch = Int(actualFormat.mChannelsPerFrame)

            tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: sr, micSpacing: 0.20)
            ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: Float(sr))

            // Set render callback
            var callbackStruct = AURenderCallbackStruct(
                inputProc: { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
                    let engine = Unmanaged<AudioCaptureEngine>.fromOpaque(inRefCon).takeUnretainedValue()
                    guard let au = engine.auUnit else { return noErr }

                    // Allocate buffer
                    let channelCount = max(Int(engine.tdoaProcessor?.sampleRate ?? 48000) > 0 ? 2 : 1, 2)
                    var bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
                    for i in 0..<channelCount {
                        bufferList[i] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: inNumberFrames * 4,
                            mData: malloc(Int(inNumberFrames * 4))
                        )
                    }

                    let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufferList.unsafeMutablePointer)

                    if status == noErr {
                        let frames = Int(inNumberFrames)
                        var left = [Float](repeating: 0, count: frames)
                        var right = [Float](repeating: 0, count: frames)

                        if let data0 = bufferList[0].mData {
                            left = Array(UnsafeBufferPointer(start: data0.assumingMemoryBound(to: Float.self), count: frames))
                        }
                        if channelCount >= 2, let data1 = bufferList[1].mData {
                            right = Array(UnsafeBufferPointer(start: data1.assumingMemoryBound(to: Float.self), count: frames))
                        } else {
                            right = left
                        }

                        engine.processRawBuffer(left: left, right: right, channelCount: channelCount, sampleRate: Double(engine.tdoaProcessor?.sampleRate ?? 48000))
                    } else {
                        flog("[SoundDOA][Raw AudioUnit] Render error: \(status)")
                    }

                    // Free buffers
                    for i in 0..<channelCount {
                        free(bufferList[i].mData)
                    }
                    free(bufferList.unsafeMutablePointer)

                    return noErr
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )

            status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                         kAudioUnitScope_Global, 0,
                                         &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            flog("[SoundDOA][\(mode.rawValue)] Set callback: \(status)")

            status = AudioUnitInitialize(au)
            flog("[SoundDOA][\(mode.rawValue)] Initialize: \(status)")

            status = AudioOutputUnitStart(au)
            flog("[SoundDOA][\(mode.rawValue)] Start: \(status)")

        } catch {
            flog("[SoundDOA][\(mode.rawValue)] Error: \(error)")
            onError?("[\(mode.rawValue)] \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func configurePolarPattern(_ session: AVAudioSession, pattern: AVAudioSession.PolarPattern) {
        if let inputs = session.availableInputs {
            for port in inputs {
                if let sources = port.dataSources {
                    for src in sources {
                        if src.supportedPolarPatterns?.contains(pattern) == true {
                            try? port.setPreferredDataSource(src)
                            try? src.setPreferredPolarPattern(pattern)
                            flog("[SoundDOA][\(mode.rawValue)] Set \(pattern.rawValue) on \(src.dataSourceName)")
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

        processRawBuffer(left: left, right: right, channelCount: channelCount, sampleRate: sampleRate)
    }

    func processRawBuffer(left: [Float], right: [Float], channelCount: Int, sampleRate: Double) {
        guard let tdoa = tdoaProcessor, let ild = ildProcessor else { return }

        let tdoaResult = tdoa.process(left: left, right: right)
        let ildResult = ild.process(left: left, right: right)

        let diffRMS = tdoaResult.metadata["diffRMS"] ?? 0
        let peakCorr = tdoaResult.metadata["peakCorr"] ?? 0
        let lag = tdoaResult.metadata["delaySamples"] ?? 0
        let ildDB = ildResult.metadata["ildOverall"] ?? 0

        let result: DOAResult
        if diffRMS > 0.001 && peakCorr > 5 {
            result = tdoaResult
        } else if diffRMS > 0.0005 {
            result = ildResult
        } else {
            result = DOAResult(angle: 0, confidence: 0, timestamp: .now, metadata: ["silent": 1])
        }

        if result.confidence > 0.1 && diffRMS > 0.0005 {
            let weight = diffRMS * result.confidence
            angleHistory.append((angle: result.angle, weight: weight))
            if angleHistory.count > maxHistory { angleHistory.removeFirst() }
        }

        let totalWeight = angleHistory.reduce(0.0) { $0 + $1.weight }
        let smoothedAngle = totalWeight > 0
            ? angleHistory.reduce(0.0) { $0 + $1.angle * $1.weight } / totalWeight
            : result.angle

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

        let smoothed = DOAResult(angle: smoothedAngle, confidence: result.confidence, timestamp: .now, metadata: result.metadata)
        onResult?(smoothed, snapshot)
    }
}
