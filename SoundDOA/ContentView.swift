import SwiftUI

/// Main UI: radar direction indicator + algorithm selector + metrics
struct ContentView: View {
    @State private var vm = AudioViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Algorithm picker
                    Picker("Algorithm", selection: $vm.selectedAlgorithm) {
                        ForEach(DOAAlgorithm.allCases, id: \.self) { algo in
                            Text(algo.rawValue).tag(algo)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    // Direction indicator
                    DirectionIndicatorView(result: vm.currentResult)
                        .frame(width: 260, height: 260)
                        .padding(.vertical, 10)

                    // Angle display
                    VStack(spacing: 4) {
                        Text("\(Int(vm.currentResult.angle))°")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Confidence \(String(format: "%.0f%%", vm.currentResult.confidence * 100))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Metrics panel
                    MetricsView(result: vm.currentResult, algorithm: vm.selectedAlgorithm)
                        .padding(.horizontal)

                    // Waveforms
                    VStack(alignment: .leading, spacing: 8) {
                        WaveformView(levels: vm.leftLevels, label: "Left", color: .blue)
                        WaveformView(levels: vm.rightLevels, label: "Right", color: .orange)
                    }
                    .padding(.horizontal)

                    // Mic spacing slider
                    HStack {
                        Text("Mic spacing")
                        Slider(value: Binding(
                            get: { vm.micSpacing },
                            set: { vm.setMicSpacing($0) }
                        ), in: 0.02...0.20, step: 0.01)
                        Text("\(String(format: "%.0f", vm.micSpacing * 100))cm")
                            .font(.caption)
                            .frame(width: 40)
                    }
                    .padding(.horizontal)

                    if let err = vm.errorMessage, !vm.isDemoMode {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Sound DOA")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if !vm.isDemoMode {
                            vm.toggleRecording()
                        }
                    } label: {
                        if vm.isDemoMode {
                            Label("Demo", systemImage: "waveform.circle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: vm.isRunning ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(vm.isRunning ? .red : .green)
                        }
                    }
                    .disabled(vm.isDemoMode)
                }
            }
        }
    }
}
