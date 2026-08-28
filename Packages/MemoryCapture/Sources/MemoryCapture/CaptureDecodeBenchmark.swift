import Foundation

public struct CaptureDecodeBenchmarkReport: Codable, Equatable, Sendable {
    public let samplesMilliseconds: [Double]
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
}

public enum CaptureDecodeBenchmark {
    public static func run(
        mediaPaths: [String],
        sampleCount: Int = 100
    ) async throws -> CaptureDecodeBenchmarkReport {
        _ = mediaPaths
        _ = sampleCount
        throw HEICFrameEncoderError.runtimeQuarantined
    }
}
