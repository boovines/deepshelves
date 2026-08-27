@preconcurrency import AVFoundation
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
        guard !mediaPaths.isEmpty else {
            return CaptureDecodeBenchmarkReport(
                samplesMilliseconds: [],
                p95Milliseconds: 0,
                p99Milliseconds: 0
            )
        }
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        for index in 0 ..< sampleCount {
            let path = mediaPaths[index % mediaPaths.count]
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await generator.image(at: .zero)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            samples.append(Double(elapsed) / 1_000_000)
        }
        let sorted = samples.sorted()
        return CaptureDecodeBenchmarkReport(
            samplesMilliseconds: samples,
            p95Milliseconds: percentile(sorted, quantile: 0.95),
            p99Milliseconds: percentile(sorted, quantile: 0.99)
        )
    }

    private static func percentile(_ sorted: [Double], quantile: Double) -> Double {
        guard !sorted.isEmpty else {
            return 0
        }
        let index = max(0, Int(ceil(Double(sorted.count) * quantile)) - 1)
        return sorted[min(index, sorted.count - 1)]
    }
}
