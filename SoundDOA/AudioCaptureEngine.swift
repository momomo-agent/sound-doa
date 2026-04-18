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

// MARK: - Audio Capture Engine

final class AudioCaptureEngine: @unchecked Sendable {
    let mode: CaptureMode
    private var engine: AVAudioEngine?
    private var auUnit: AudioComponentInstance?
    private var tdoaProcessor: TDOAProcessor?
    private var ildProcessor: ILDProcessor?

    var onResult: ((DOAResult, CaptureSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private var angleHistory: [(angle: Double, weight: Double)] = []
    private let maxHistory = 8

    // 3D: store per-source RMS for elevation estimation
    private var frontRMS: Double = 0
    private var backRMS: Double = 0
    private var bottomRMS: Double = 0

    init(mode: CaptureMode) {
        self.mode = mode
    }

    func start() {
        switch mode {
        case .rawAudioUnit:
            startRawAudioUnit()
        case .threeD:
            start3DAlternating()
        default:
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
                configurePolarPattern(session, pattern: .stereo)
            case .stereoOmni:
                configurePolarPattern(session, pattern: .omnidirectional)
            case .stereoFrontBack:
                // Select "前" (front) specifically for stereo
                selectDataSource(session, name: "前", pattern: .stereo)
            default:
                break
            }

            try? session.setPreferredInputNumberOfChannels(2)
            try session.setActive(false)
            try session.setActive(true)

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

            flog("[SoundDOA][\(mode.rawValue)] Format: \(ch)ch @ \(sr)Hz")

            tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: sr, micSpacing: 0.14)
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

    // MARK: - Raw AudioUnit

    private func startRawAudioUnit() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            configurePolarPattern(session, pattern: .stereo)
            try? session.setPreferredInputNumberOfChannels(2)
            try session.setActive(false)
            try session.setActive(true)
            setupRemoteIO(sampleRate: session.sampleRate)
        } catch {
            flog("[SoundDOA][\(mode.rawValue)] Error: \(error)")
            onError?("[\(mode.rawValue)] \(error.localizedDescription)")
        }
    }

    // MARK: - 3D Alternating Capture

    /// Alternates between front/back/bottom data sources every 0.5s
    /// to collect RMS from each mic position for elevation estimation.
    /// Uses stereo from "后" as primary for azimuth, and compares
    /// RMS across sources for elevation.
    private func start3DAlternating() {
        flog("[SoundDOA][3D] Starting 3D alternating capture")

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)

            // Log mic layout
            if let inputs = session.availableInputs {
                for port in inputs where port.portType == .builtInMic {
                    if let sources = port.dataSources {
                        for src in sources {
                            let patterns = src.supportedPolarPatterns?.map { $0.rawValue } ?? []
                            flog("[SoundDOA][3D] Mic: \(src.dataSourceName) id=\(src.dataSourceID) patterns=\(patterns)")
                        }
                    }
                }
            }

            // Start with stereo on "后" for azimuth
            selectDataSource(session, name: "后", pattern: .stereo)
            try? session.setPreferredInputNumberOfChannels(2)
            try session.setActive(false)
            try session.setActive(true)

            let eng = AVAudioEngine()
            self.engine = eng
            let input = eng.inputNode
            let format = input.inputFormat(forBus: 0)
            let sr = format.sampleRate
            let ch = format.channelCount

            flog("[SoundDOA][3D] Primary capture: \(ch)ch @ \(sr)Hz")

            tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: sr, micSpacing: 0.14)
            ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: Float(sr))

            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.processBuffer(buffer, channelCount: Int(ch), sampleRate: sr)
            }

            try eng.start()
            flog("[SoundDOA][3D] Engine started")

            // Start alternating data source sampling in background
            startDataSourceSampling()

        } catch {
            flog("[SoundDOA][3D] Error: \(error)")
            onError?("[3D] \(error.localizedDescription)")
        }
    }

    /// Periodically switch data source to sample RMS from each mic
    private func startDataSourceSampling() {
        let sources = ["前", "后", "下"]
        var idx = 0

        // Every 2 seconds, briefly switch to a different source to measure its RMS
        // This gives us relative loudness from each mic position
        Task { [weak self] in
            while self?.engine != nil {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.engine != nil else { break }

                let sourceName = sources[idx % sources.count]
                idx += 1

                let session = AVAudioSession.sharedInstance()
                if let inputs = session.availableInputs {
                    for port in inputs where port.portType == .builtInMic {
                        if let dataSources = port.dataSources {
                            for src in dataSources where src.dataSourceName == sourceName {
                                if sourceName == "下" {
                                    try? port.setPreferredDataSource(src)
                                    if let first = src.supportedPolarPatterns?.first {
                                        try? src.setPreferredPolarPattern(first)
                                    }
                                } else {
                                    try? port.setPreferredDataSource(src)
                                    if src.supportedPolarPatterns?.contains(.stereo) == true {
                                        try? src.setPreferredPolarPattern(.stereo)
                                    }
                                }

                                flog("[SoundDOA][3D] Sampled \(sourceName): fRMS=\(String(format:"%.4f", self.frontRMS)) bRMS=\(String(format:"%.4f", self.backRMS)) dRMS=\(String(format:"%.4f", self.bottomRMS))")

                                try? await Task.sleep(for: .milliseconds(200))

                                self.selectDataSource(session, name: "后", pattern: .stereo)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - RemoteIO setup

    private func setupRemoteIO(sampleRate: Double) {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            flog("[SoundDOA][\(mode.rawValue)] RemoteIO not found")
            onError?("RemoteIO not found")
            return
        }

        var unit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let au = unit else {
            flog("[SoundDOA][\(mode.rawValue)] AudioUnit create failed: \(status)")
            onError?("AudioUnit create failed: \(status)")
            return
        }
        self.auUnit = au

        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1,
                                     &enableInput, UInt32(MemoryLayout<UInt32>.size))

        status = AudioUnitInitialize(au)

        var hwFormat = AudioStreamBasicDescription()
        var hwFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input, 1,
                           &hwFormat, &hwFormatSize)
        flog("[SoundDOA][\(mode.rawValue)] HW: \(hwFormat.mChannelsPerFrame)ch @ \(hwFormat.mSampleRate)Hz")

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: hwFormat.mSampleRate > 0 ? hwFormat.mSampleRate : sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: max(hwFormat.mChannelsPerFrame, 2),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Output, 1,
                           &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        let actualSR = clientFormat.mSampleRate
        tdoaProcessor = TDOAProcessor(fftSize: 2048, sampleRate: actualSR, micSpacing: 0.14)
        ildProcessor = ILDProcessor(fftSize: 2048, sampleRate: Float(actualSR))

        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
                let engine = Unmanaged<AudioCaptureEngine>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let au = engine.auUnit else { return noErr }

                let channelCount = 2
                let bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
                for i in 0..<channelCount {
                    bufferList[i] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: inNumberFrames * 4,
                        mData: malloc(Int(inNumberFrames * 4))
                    )
                }

                let renderStatus = AudioUnitRender(au, ioActionFlags, inTimeStamp, 1, inNumberFrames, bufferList.unsafeMutablePointer)

                if renderStatus == noErr {
                    let frames = Int(inNumberFrames)
                    var left = [Float](repeating: 0, count: frames)
                    var right = [Float](repeating: 0, count: frames)

                    if let data0 = bufferList[0].mData {
                        left = Array(UnsafeBufferPointer(start: data0.assumingMemoryBound(to: Float.self), count: frames))
                    }
                    if let data1 = bufferList[1].mData {
                        right = Array(UnsafeBufferPointer(start: data1.assumingMemoryBound(to: Float.self), count: frames))
                    }

                    let sr = engine.tdoaProcessor?.sampleRate ?? 48000
                    engine.processRawBuffer(left: left, right: right, channelCount: channelCount, sampleRate: sr)
                }

                for i in 0..<channelCount { free(bufferList[i].mData) }
                free(bufferList.unsafeMutablePointer)
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                           kAudioUnitScope_Global, 0,
                           &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        AudioOutputUnitStart(au)
        flog("[SoundDOA][\(mode.rawValue)] RemoteIO started")
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

    private func selectDataSource(_ session: AVAudioSession, name: String, pattern: AVAudioSession.PolarPattern) {
        if let inputs = session.availableInputs {
            for port in inputs where port.portType == .builtInMic {
                if let sources = port.dataSources {
                    for src in sources where src.dataSourceName == name {
                        try? port.setPreferredDataSource(src)
                        if src.supportedPolarPatterns?.contains(pattern) == true {
                            try? src.setPreferredPolarPattern(pattern)
                        }
                        flog("[SoundDOA][\(mode.rawValue)] Selected \(name) with \(pattern.rawValue)")
                        return
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

        // Track per-channel RMS for 3D mode
        var leftRMS: Float = 0
        var rightRMS: Float = 0
        vDSP_rmsqv(left, 1, &leftRMS, vDSP_Length(left.count))
        vDSP_rmsqv(right, 1, &rightRMS, vDSP_Length(right.count))

        if mode == .threeD {
            // In 3D mode, track RMS for elevation estimation
            let avgRMS = Double((leftRMS + rightRMS) / 2)
            // The current data source determines which mic this RMS belongs to
            let session = AVAudioSession.sharedInstance()
            let dsName = session.currentRoute.inputs.first?.selectedDataSource?.dataSourceName ?? "?"
            switch dsName {
            case "前": frontRMS = avgRMS
            case "后": backRMS = avgRMS
            case "下": bottomRMS = avgRMS
            default: break
            }
        }

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

        // Estimate elevation from front/back/bottom RMS ratio
        var elevation = 0.0
        if mode == .threeD && (frontRMS + backRMS + bottomRMS) > 0.0001 {
            // If bottom mic is louder → sound is below (negative elevation)
            // If front/back mics are louder → sound is at ear level or above
            let topAvg = (frontRMS + backRMS) / 2
            let ratio = topAvg / max(bottomRMS, 0.0001)
            // ratio > 1 → above, ratio < 1 → below
            elevation = atan(ratio - 1) * 180 / .pi  // rough estimate
        }

        var metadata = result.metadata
        metadata["elevation"] = elevation
        metadata["frontRMS"] = frontRMS
        metadata["backRMS"] = backRMS
        metadata["bottomRMS"] = bottomRMS
        metadata["leftRMS"] = Double(leftRMS)
        metadata["rightRMS"] = Double(rightRMS)

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
            rawRight: Array(right.prefix(64)),
            elevation: elevation,
            frontRMS: frontRMS,
            backRMS: backRMS,
            bottomRMS: bottomRMS
        )

        flog("[SoundDOA][\(mode.rawValue)] az=\(String(format:"%.1f", smoothedAngle)) el=\(String(format:"%.1f", elevation)) lag=\(String(format:"%.1f", lag)) diffRMS=\(String(format:"%.4f", diffRMS)) peak=\(String(format:"%.0f", peakCorr)) ild=\(String(format:"%.2f", ildDB))dB fRMS=\(String(format:"%.4f", frontRMS)) bRMS=\(String(format:"%.4f", backRMS)) dRMS=\(String(format:"%.4f", bottomRMS)) ch=\(channelCount)")

        let smoothed = DOAResult(angle: smoothedAngle, confidence: result.confidence, timestamp: .now, metadata: metadata)
        onResult?(smoothed, snapshot)
    }
}
