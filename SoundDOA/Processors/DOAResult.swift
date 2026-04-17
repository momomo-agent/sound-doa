import Foundation

enum DOAAlgorithm: String, CaseIterable {
    case tdoa = "TDOA"
    case ild = "ILD"
}

struct DOAResult: Sendable {
    let angle: Double          // degrees, -180 to 180
    let confidence: Double     // 0 to 1
    let timestamp: Date
    let metadata: [String: Double]

    static let zero = DOAResult(angle: 0, confidence: 0, timestamp: .now, metadata: [:])
}
