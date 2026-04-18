import SwiftUI

struct ContentView: View {
    @State private var selectedTab: CaptureMode = .stereoDefault
    @State private var isRunning = false
    @State private var snapshots: [CaptureMode: CaptureSnapshot] = [:]
    @State private var results: [CaptureMode: DOAResult] = [:]
    @State private var errorMessages: [CaptureMode: String] = [:]

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

                // Selected mode detail
                ScrollView {
                    VStack(spacing: 16) {
                        // Direction indicator
                        DirectionView(
                            angle: results[selectedTab]?.angle ?? 0,
                            confidence: results[selectedTab]?.confidence ?? 0
                        )

                        // Metrics
                        if let snap = snapshots[selectedTab] {
                            MetricsGrid(snapshot: snap)
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
            .onAppear { startAll() }
            .onChange(of: selectedTab) { _, newMode in
                if isRunning { startEngine(for: newMode) }
            }
        }
    }

    private func startAll() {
        // Only run one engine at a time (AVAudioSession is shared)
        // Start selected mode
        startEngine(for: selectedTab)
        isRunning = true
    }

    private func stopAll() {
        for (_, engine) in engines {
            engine.stop()
        }
        isRunning = false
    }

    private func startEngine(for mode: CaptureMode) {
        // Stop all first
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
