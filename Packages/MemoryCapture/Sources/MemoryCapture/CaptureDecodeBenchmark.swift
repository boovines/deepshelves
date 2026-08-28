import Foundation
import ImageIO
import MemoryContracts

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
        let frameURLs = try mediaPaths.flatMap { path -> [URL] in
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let data = try Data(
                contentsOf: directory.appendingPathComponent("manifest.json"))
            let manifest = try ContractJSON.decode(HEICKeyframeManifest.self, from: data)
            return manifest.frames.map { directory.appendingPathComponent($0.relativePath) }
        }
        guard !frameURLs.isEmpty else {
            return CaptureDecodeBenchmarkReport(
                samplesMilliseconds: [],
                p95Milliseconds: 0,
                p99Milliseconds: 0
            )
        }
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let url = frameURLs[index % frameURLs.count] as CFURL
            let started = DispatchTime.now().uptimeNanoseconds
            guard let source = CGImageSourceCreateWithURL(url, nil),
                CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
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
