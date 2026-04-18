import SwiftUI

struct ContentView: View {
    @State private var selectedTab: CaptureMode = .stereoDefault
    @State private var isRunning = false
    @State private var snapshots: [CaptureMode: CaptureSnapshot] = [:]
    @State private var results: [CaptureMode: DOAResult] = [:]
    @State private var errorMessages: [CaptureMode: String] = [:]
    @State private var autoTestRunning = false
    @State private var autoTestPhase: String = ""

    private var engines: [CaptureMode: AudioCaptureEngine] = {
        var dict: [CaptureMode: AudioCaptureEngine] = [:]
        for mode in CaptureMode.allCases {
            dict[mode] = AudioCaptureEngine(mode: mode)
        }
        return dict
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Mode tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CaptureMode.allCases) { mode in
                            ModeTab(mode: mode, isSelected: selectedTab == mode,
                                    snapshot: snapshots[mode])
                                .onTapGesture { selectedTab = mode }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)

                Divider()

                // Auto test status
                if autoTestRunning || !autoTestPhase.isEmpty {
                    HStack {
                        if autoTestRunning {
                            ProgressView().scaleEffect(0.8)
                        }
                        Text(autoTestPhase)
                            .font(.caption.bold())
                            .foregroundStyle(autoTestRunning ? .orange : .green)
                    }
                    .padding(.vertical, 4)
                }

                // Selected mode detail
                ScrollView {
                    VStack(spacing: 16) {
                        // Direction indicator (2D or 3D)
                        if selectedTab == .threeD {
                            Direction3DView(
                                azimuth: results[selectedTab]?.angle ?? 0,
                                elevation: snapshots[selectedTab]?.elevation ?? 0,
                                confidence: results[selectedTab]?.confidence ?? 0
                            )
                        } else {
                            DirectionView(
                                angle: results[selectedTab]?.angle ?? 0,
                                confidence: results[selectedTab]?.confidence ?? 0
                            )
                        }

                        // Metrics
                        if let snap = snapshots[selectedTab] {
                            MetricsGrid(snapshot: snap)
                        }

                        // 3D mic RMS bars
                        if selectedTab == .threeD, let snap = snapshots[selectedTab] {
                            MicRMSView(front: snap.frontRMS, back: snap.backRMS, bottom: snap.bottomRMS)
                        }

                        // Raw waveform comparison
                        if let snap = snapshots[selectedTab], !snap.rawLeft.isEmpty {
                            WaveformCompare(left: snap.rawLeft, right: snap.rawRight)
                        }

                        // All modes comparison table
                        ComparisonTable(snapshots: snapshots)

                        if let err = errorMessages[selectedTab] {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Sound DOA Lab")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if isRunning { stopAll() } else { startAll() }
                    } label: {
                        Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(isRunning ? .red : .green)
                    }
                }
            }
            .onAppear { runAutoTest() }
            .onChange(of: selectedTab) { _, newMode in
                if isRunning { startEngine(for: newMode) }
            }
        }
    }

    private func startAll() {
        startEngine(for: selectedTab)
        isRunning = true
    }

    private func stopAll() {
        for (_, engine) in engines {
            engine.stop()
        }
        isRunning = false
        autoTestRunning = false
    }

    private func startEngine(for mode: CaptureMode) {
        for (_, engine) in engines { engine.stop() }

        guard let engine = engines[mode] else { return }
        engine.onResult = { result, snapshot in
            Task { @MainActor in
                results[mode] = result
                snapshots[mode] = snapshot
            }
        }
        engine.onError = { err in
            Task { @MainActor in errorMessages[mode] = err }
        }
        engine.start()
        flog("[SoundDOA] Started engine: \(mode.rawValue)")
    }

    /// Auto-test: cycle through all modes, 6 seconds each
    private func runAutoTest() {
        autoTestRunning = true
        isRunning = true
        flog("[SoundDOA] === AUTO TEST START ===")

        Task {
            for mode in CaptureMode.allCases {
                await MainActor.run {
                    selectedTab = mode
                    autoTestPhase = "Testing \(mode.rawValue)..."
                    startEngine(for: mode)
                }
                flog("[SoundDOA] AUTO TEST: \(mode.rawValue) started, waiting 6s...")
                try? await Task.sleep(for: .seconds(6))

                // Log summary for this mode
                await MainActor.run {
                    if let snap = snapshots[mode] {
                        flog("[SoundDOA] AUTO TEST RESULT [\(mode.rawValue)]: ch=\(snap.channelCount) sr=\(snap.sampleRate) angle=\(String(format:"%.1f", snap.angle)) lag=\(String(format:"%.1f", snap.lag)) diffRMS=\(String(format:"%.4f", snap.diffRMS)) peak=\(String(format:"%.0f", snap.peakCorr)) ild=\(String(format:"%.2f", snap.ildDB))dB")
                    } else if let err = errorMessages[mode] {
                        flog("[SoundDOA] AUTO TEST ERROR [\(mode.rawValue)]: \(err)")
                    } else {
                        flog("[SoundDOA] AUTO TEST [\(mode.rawValue)]: no data")
                    }
                }
            }

            await MainActor.run {
                autoTestPhase = "Done! Check comparison table."
                autoTestRunning = false
                flog("[SoundDOA] === AUTO TEST COMPLETE ===")
            }
        }
    }
}

// MARK: - Mode Tab

struct ModeTab: View {
    let mode: CaptureMode
    let isSelected: Bool
    let snapshot: CaptureSnapshot?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: mode.systemImage)
                .font(.title3)
            Text(mode.rawValue)
                .font(.caption2.bold())
            if let snap = snapshot {
                Text("\(snap.channelCount)ch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Direction View

struct DirectionView: View {
    let angle: Double
    let confidence: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                .frame(width: 180, height: 180)

            // Degree markers
            ForEach(Array(stride(from: 0, to: 360, by: 30)), id: \.self) { deg in
                let rad = Double(deg) * .pi / 180 - .pi/2
                let isCardinal = deg % 90 == 0
                Rectangle()
                    .fill(isCardinal ? Color.primary : Color.secondary.opacity(0.5))
                    .frame(width: isCardinal ? 2 : 1, height: isCardinal ? 10 : 5)
                    .offset(y: -85)
                    .rotationEffect(.degrees(Double(deg)))
            }

            // Arrow
            let arrowAngle = angle * .pi / 180 - .pi/2
            let arrowLen = 70.0 * min(1.0, confidence + 0.3)
            Path { path in
                path.move(to: CGPoint(x: 90, y: 90))
                path.addLine(to: CGPoint(
                    x: 90 + cos(arrowAngle) * arrowLen,
                    y: 90 + sin(arrowAngle) * arrowLen))
            }
            .stroke(confidence > 0.3 ? Color.red : Color.red.opacity(0.4), lineWidth: 3)
            .frame(width: 180, height: 180)

            Circle().fill(Color.red).frame(width: 6, height: 6)
        }

        VStack(spacing: 2) {
            Text(String(format: "%.1f°", angle))
                .font(.system(size: 36, weight: .bold, design: .monospaced))
            Text(String(format: "Confidence: %.0f%%", confidence * 100))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Metrics Grid

struct MetricsGrid: View {
    let snapshot: CaptureSnapshot

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()),
            GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 8) {
            MetricCell(label: "Channels", value: "\(snapshot.channelCount)")
            MetricCell(label: "Sample Rate", value: String(format: "%.0f", snapshot.sampleRate))
            MetricCell(label: "Lag", value: String(format: "%.1f", snapshot.lag))
            MetricCell(label: "Peak", value: String(format: "%.0f", snapshot.peakCorr))
            MetricCell(label: "diffRMS", value: String(format: "%.4f", snapshot.diffRMS))
            MetricCell(label: "ILD", value: String(format: "%.2fdB", snapshot.ildDB))
            MetricCell(label: "Conf", value: String(format: "%.0f%%", snapshot.confidence * 100))
            MetricCell(label: "Angle", value: String(format: "%.1f°", snapshot.angle))
        }
    }
}

struct MetricCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .monospaced).bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Waveform Compare

struct WaveformCompare: View {
    let left: [Float]
    let right: [Float]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("L/R Waveform (first 64 samples)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(0..<min(left.count, right.count, 64), id: \.self) { i in
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: 4, height: max(1, CGFloat(abs(left[i])) * 200))
                        Rectangle()
                            .fill(Color.green.opacity(0.7))
                            .frame(width: 4, height: max(1, CGFloat(abs(right[i])) * 200))
                    }
                }
            }
            .frame(height: 60)
            .clipped()

            // Channel difference
            let diff = zip(left, right).map { abs($0 - $1) }
            let maxDiff = diff.max() ?? 0
            HStack(spacing: 0) {
                ForEach(0..<min(diff.count, 64), id: \.self) { i in
                    let h = CGFloat(diff[i]) / CGFloat(max(maxDiff, 1e-6)) * 30
                    Rectangle()
                        .fill(Color.orange.opacity(0.8))
                        .frame(width: 4, height: max(1, h))
                }
            }
            .frame(height: 30)
            .clipped()
            Text("L-R difference (amplified)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Comparison Table

struct ComparisonTable: View {
    let snapshots: [CaptureMode: CaptureSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode Comparison")
                .font(.headline)

            ForEach(CaptureMode.allCases) { mode in
                if let snap = snapshots[mode] {
                    HStack {
                        Image(systemName: mode.systemImage)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.rawValue).font(.caption.bold())
                            Text("\(snap.channelCount)ch @ \(String(format:"%.0f", snap.sampleRate))Hz")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f°", snap.angle))
                                .font(.system(.caption, design: .monospaced).bold())
                            Text("lag=\(String(format:"%.1f", snap.lag)) rms=\(String(format:"%.4f", snap.diffRMS))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    HStack {
                        Image(systemName: mode.systemImage)
                            .frame(width: 20)
                        Text(mode.rawValue).font(.caption)
                        Spacer()
                        Text("Not tested").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color(.systemGray6).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

// MARK: - 3D Direction View

struct Direction3DView: View {
    let azimuth: Double
    let elevation: Double
    let confidence: Double

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 1)

                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    .frame(width: 160, height: 160)

                let azRad = azimuth * .pi / 180
                let elRad = elevation * .pi / 180
                let projLen = 70.0 * cos(elRad) * min(1.0, confidence + 0.3)
                let vertOff = 70.0 * sin(elRad) * min(1.0, confidence + 0.3)

                Path { path in
                    path.move(to: CGPoint(x: 90, y: 90))
                    path.addLine(to: CGPoint(
                        x: 90 + cos(azRad - .pi/2) * projLen,
                        y: 90 + sin(azRad - .pi/2) * projLen))
                }
                .stroke(Color.red, lineWidth: 3)
                .frame(width: 180, height: 180)

                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .offset(y: CGFloat(-vertOff))

                Circle().fill(Color.red).frame(width: 6, height: 6)

                Text("上").font(.caption2).foregroundStyle(.secondary).offset(y: -85)
                Text("下").font(.caption2).foregroundStyle(.secondary).offset(y: 85)
                Text("左").font(.caption2).foregroundStyle(.secondary).offset(x: -85)
                Text("右").font(.caption2).foregroundStyle(.secondary).offset(x: 85)
            }
            .frame(width: 180, height: 180)

            VStack(spacing: 2) {
                HStack(spacing: 16) {
                    VStack {
                        Text(String(format: "%.1f°", azimuth))
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                        Text("Azimuth")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Text(String(format: "%.1f°", elevation))
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundStyle(.orange)
                        Text("Elevation")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(String(format: "Confidence: %.0f%%", confidence * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Mic RMS View

struct MicRMSView: View {
    let front: Double
    let back: Double
    let bottom: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Mic RMS (3D)")
                .font(.caption.bold())

            let maxRMS = max(front, max(back, max(bottom, 0.0001)))

            MicBar(label: "前 (Front)", rms: front, maxRMS: maxRMS, color: .blue)
            MicBar(label: "后 (Back)", rms: back, maxRMS: maxRMS, color: .green)
            MicBar(label: "下 (Bottom)", rms: bottom, maxRMS: maxRMS, color: .orange)

            if front + back + bottom > 0.0001 {
                let topAvg = (front + back) / 2
                let ratio = topAvg / max(bottom, 0.0001)
                Text("Top/Bottom ratio: \(String(format: "%.2f", ratio)) → \(ratio > 1.2 ? "Above" : ratio < 0.8 ? "Below" : "Level")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MicBar: View {
    let label: String
    let rms: Double
    let maxRMS: Double
    let color: Color

    var body: some View {
        HStack {
            Text(label)
                .font(.caption2)
                .frame(width: 80, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                let barW = CGFloat(rms / maxRMS) * w
                Rectangle()
                    .fill(color.opacity(0.7))
                    .frame(width: max(2, barW))
            }
            .frame(height: 16)
            Text(String(format: "%.4f", rms))
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
        }
    }
}
