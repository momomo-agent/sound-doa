import SwiftUI

/// Simple waveform strip showing audio levels
struct WaveformView: View {
    let levels: [Float]
    let label: String
    var color: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    let height = max(2, CGFloat(min(1.0, Double(level) * 30.0)) * 30)
                    Rectangle()
                        .fill(color.opacity(0.7))
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                }
            }
            .frame(height: 30)
        }
    }
}
