import CryptoKit
import Foundation
import MemoryContracts
import MemorySoftwareHEIC

public struct CaptureDecodeBenchmarkReport: Codable, Equatable, Sendable {
    public let samplesMilliseconds: [Double]
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
}

public enum CaptureDecodeBenchmarkError: Error, Equatable, Sendable {
    case invalidRequest
    case mediaUnavailable
    case integrityMismatch
}

public enum CaptureDecodeBenchmark {
    public static func run(
        mediaPaths: [String],
        sampleCount: Int = 100
    ) async throws -> CaptureDecodeBenchmarkReport {
        guard !mediaPaths.isEmpty, sampleCount > 0 else {
            throw CaptureDecodeBenchmarkError.invalidRequest
        }
        let codec = try SoftwareHEICCodec()
        var frames: [(url: URL, expectedHash: Data)] = []
        for path in mediaPaths {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                let manifest = try? ContractJSON.decode(
                    HEICKeyframeManifest.self,
                    from: manifestData
                )
            else {
                throw CaptureDecodeBenchmarkError.mediaUnavailable
            }
            frames.append(
                contentsOf: manifest.frames.map {
                    (
                        directory.appendingPathComponent($0.relativePath),
                        $0.sha256
                    )
                })
        }
        guard !frames.isEmpty else { throw CaptureDecodeBenchmarkError.mediaUnavailable }

        let clock = ContinuousClock()
        var samples = [Double]()
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let frame = frames[index % frames.count]
            guard let data = try? Data(contentsOf: frame.url, options: .mappedIfSafe),
                Data(SHA256.hash(data: data)) == frame.expectedHash
            else {
                throw CaptureDecodeBenchmarkError.integrityMismatch
            }
            let started = clock.now
            _ = try codec.decode(data)
            let elapsed = started.duration(to: clock.now)
            samples.append(
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            )
        }
        let ordered = samples.sorted()
        return CaptureDecodeBenchmarkReport(
            samplesMilliseconds: samples,
            p95Milliseconds: percentile(ordered, percentile: 0.95),
            p99Milliseconds: percentile(ordered, percentile: 0.99)
        )
    }

    private static func percentile(_ ordered: [Double], percentile: Double) -> Double {
        let index = min(
            ordered.count - 1,
            max(0, Int(ceil(Double(ordered.count) * percentile)) - 1)
        )
        return ordered[index]
    }
}
