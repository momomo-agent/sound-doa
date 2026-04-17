import SwiftUI

/// Real-time algorithm metrics display
struct MetricsView: View {
    let result: DOAResult
    let algorithm: DOAAlgorithm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metrics")
                .font(.headline)

            Group {
                switch algorithm {
                case .tdoa:
                    tdoaMetrics
                case .ild:
                    ildMetrics
                }
            }
            .font(.system(.body, design: .monospaced))
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var tdoaMetrics: some View {
        MetricRow(label: "Delay", value: String(format: "%.1f µs", result.metadata["delayUs"] ?? 0))
        MetricRow(label: "Peak Corr", value: String(format: "%.4f", result.metadata["peakCorr"] ?? 0))
    }

    @ViewBuilder
    private var ildMetrics: some View {
        MetricRow(label: "ILD Overall", value: String(format: "%.1f dB", result.metadata["ildOverall"] ?? 0))
        MetricRow(label: "Low", value: String(format: "%.1f dB", result.metadata["ildBand0"] ?? 0))
        MetricRow(label: "Mid", value: String(format: "%.1f dB", result.metadata["ildBand1"] ?? 0))
        MetricRow(label: "High", value: String(format: "%.1f dB", result.metadata["ildBand2"] ?? 0))
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
