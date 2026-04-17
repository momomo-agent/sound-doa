import SwiftUI

/// Radar/compass style direction indicator
/// Phone icon in center, arrow showing estimated sound direction
struct DirectionIndicatorView: View {
    let result: DOAResult

    @State private var demoAngle: Double = 0
    @State private var demoTimer: Timer?

    private var angleRadians: Double { result.confidence > 0 ? result.angle * .pi / 180.0 : 0 }
    private var confidence: Double { result.confidence }

    var body: some View {
        ZStack {
            // Background circles
            ForEach(1...3, id: \.self) { ring in
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    .frame(width: CGFloat(ring) * 80, height: CGFloat(ring) * 80)
            }

            // Cross hairs
            Path { path in
                path.move(to: CGPoint(x: -130, y: 0))
                path.addLine(to: CGPoint(x: 130, y: 0))
            }
            .stroke(Color.gray.opacity(0.25), lineWidth: 1)

            Path { path in
                path.move(to: CGPoint(x: 0, y: -130))
                path.addLine(to: CGPoint(x: 0, y: 130))
            }
            .stroke(Color.gray.opacity(0.25), lineWidth: 1)

            // Direction arc
            if confidence > 0.1 {
                let radius: CGFloat = 100
                Path { path in
                    path.addArc(
                        center: .zero,
                        radius: radius,
                        startAngle: .degrees(-90) + .degrees(result.angle - 15),
                        endAngle: .degrees(-90) + .degrees(result.angle + 15),
                        clockwise: false
                    )
                }
                .stroke(
                    Color.green.opacity(0.3 * confidence),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
            }

            // Direction dot — always visible with some opacity
            let radius: CGFloat = 100
            let dotAngle = confidence > 0.1 ? result.angle : demoAngle
            let dotRad = dotAngle * .pi / 180.0
            let dx = cos(dotRad - .pi / 2) * Double(radius)
            let dy = sin(dotRad - .pi / 2) * Double(radius)

            let dotOpacity = confidence > 0.1 ? (0.4 + 0.6 * confidence) : 0.5
            let dotSize = confidence > 0.1 ? CGFloat(10 + 14 * confidence) : CGFloat(12)

            Circle()
                .fill(confidence > 0.1 ? Color.green : Color.green.opacity(0.6))
                .opacity(dotOpacity)
                .frame(width: dotSize, height: dotSize)
                .offset(x: dx, y: dy)

            // Phone icon in center
            Image(systemName: "iphone")
                .font(.system(size: 28))
                .foregroundStyle(.primary.opacity(0.7))

            // Compass labels
            Text("0°")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: -125)
            Text("90°")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(x: 120)
            Text("180°")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: 125)
            Text("-90°")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(x: -120)
        }
        .animation(.easeOut(duration: 0.08), value: result.angle)
        .onAppear { startDemoRotation() }
        .onDisappear { demoTimer?.invalidate() }
    }

    private func startDemoRotation() {
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            demoAngle += 2.0
            if demoAngle > 180 { demoAngle -= 360 }
        }
    }
}
