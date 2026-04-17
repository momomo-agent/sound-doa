import SwiftUI

/// Radar/compass style direction indicator
/// Phone icon in center, arrow showing estimated sound direction
struct DirectionIndicatorView: View {
    let result: DOAResult

    @State private var demoAngle: Double = 0
    @State private var demoTimer: Timer?

    private var effectiveAngle: Double {
        result.confidence > 0.1 ? result.angle : demoAngle
    }

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let maxR = min(cx, cy) - 20

            // Rings
            for ring in 1...3 {
                let r = maxR * Double(ring) / 3.0
                context.stroke(
                    Path { p in p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                    with: .color(.gray.opacity(0.2)),
                    lineWidth: 1
                )
            }

            // Crosshair — horizontal
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: cx - maxR, y: cy))
                    p.addLine(to: CGPoint(x: cx + maxR, y: cy))
                },
                with: .color(.gray.opacity(0.25)),
                lineWidth: 1
            )

            // Crosshair — vertical
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: cx, y: cy - maxR))
                    p.addLine(to: CGPoint(x: cx, y: cy + maxR))
                },
                with: .color(.gray.opacity(0.25)),
                lineWidth: 1
            )

            // Direction arc
            if result.confidence > 0.1 {
                let startDeg = -90 + effectiveAngle - 15
                let endDeg = -90 + effectiveAngle + 15
                let arcR = maxR * 0.8
                context.stroke(
                    Path { p in
                        p.addArc(
                            center: CGPoint(x: cx, y: cy),
                            radius: arcR,
                            startAngle: .degrees(startDeg),
                            endAngle: .degrees(endDeg),
                            clockwise: false
                        )
                    },
                    with: .color(.green.opacity(0.3 * result.confidence)),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
            }

            // Direction dot
            let dotR = maxR * 0.8
            let dotRad = (effectiveAngle - 90) * .pi / 180.0
            let dotX = cx + dotR * cos(dotRad)
            let dotY = cy + dotR * sin(dotRad)
            let dotSize = result.confidence > 0.1 ? 10 + 14 * result.confidence : 12.0
            let dotColor: Color = result.confidence > 0.1 ? .green : .green.opacity(0.6)

            context.fill(
                Path(ellipseIn: CGRect(
                    x: dotX - dotSize / 2,
                    y: dotY - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )),
                with: .color(dotColor.opacity(result.confidence > 0.1 ? 0.4 + 0.6 * result.confidence : 0.5))
            )

            // Compass labels
            let labelFont = Font.caption2
            context.draw(Text("0°").font(labelFont).foregroundStyle(.secondary),
                        at: CGPoint(x: cx, y: cy - maxR - 12))
            context.draw(Text("90°").font(labelFont).foregroundStyle(.secondary),
                        at: CGPoint(x: cx + maxR + 18, y: cy))
            context.draw(Text("180°").font(labelFont).foregroundStyle(.secondary),
                        at: CGPoint(x: cx, y: cy + maxR + 12))
            context.draw(Text("-90°").font(labelFont).foregroundStyle(.secondary),
                        at: CGPoint(x: cx - maxR - 16, y: cy))
        }
        .overlay {
            // Phone icon overlay at center
            Image(systemName: "iphone")
                .font(.system(size: 28))
                .foregroundStyle(.primary.opacity(0.7))
        }
        .onAppear { startDemoRotation() }
        .onDisappear { demoTimer?.invalidate() }
        .animation(.easeOut(duration: 0.08), value: effectiveAngle)
    }

    private func startDemoRotation() {
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            demoAngle += 2.0
            if demoAngle > 180 { demoAngle -= 360 }
        }
    }
}
