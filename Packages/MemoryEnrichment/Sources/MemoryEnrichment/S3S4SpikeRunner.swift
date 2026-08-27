import Accelerate
import CoreGraphics
import CoreImage
import CoreML
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct S3ParityMetrics: Codable, Sendable {
    public let imageCosineSimilarity: Double
    public let textCosineSimilarity: Double
}

public struct S3InferenceMetrics: Codable, Sendable {
    public let imageCount: Int
    public let textQueryCount: Int
    public let imageP95Milliseconds: Double
    public let textP95Milliseconds: Double
    public let visualRecallAt10: Double
    public let captureTimerP95Milliseconds: Double
    public let captureTimerIntervalsOver100Milliseconds: Int
    public let maximumConcurrentInferenceJobs: Int
}

public struct S3PackagingMetrics: Codable, Sendable {
    public let modelVersion: String
    public let artifactCount: Int
    public let verifiedArtifactCount: Int
    public let bundledFootprintBytes: Int
    public let runtimeDownloadAllowed: Bool
    public let computeUnits: String
}

public struct S4ScanMetrics: Codable, Sendable {
    public let startedAtEpoch: Double
    public let endedAtEpoch: Double
    public let vectorCount: Int
    public let dimension: Int
    public let fileBytes: Int
    public let vectorFileSHA256: String
    public let unfilteredSampleCount: Int
    public let unfilteredP95Milliseconds: Double
    public let unfilteredP99Milliseconds: Double
    public let filteredCandidateCount: Int
    public let filteredP95Milliseconds: Double
    public let maximumScalarScoreError: Double
    public let stableOrderingMatched: Bool
    public let truncatedFileDetectedBeforeResults: Bool
}

public struct S3S4SpikeReport: Codable, Sendable {
    public let schemaVersion: Int
    public let parity: S3ParityMetrics
    public let inference: S3InferenceMetrics
    public let packaging: S3PackagingMetrics
    public let exactVectorScan: S4ScanMetrics
}

private struct VisualCorpusRecord: Codable {
    let id: String
    let category: String
    let variation: Int
}

private struct VisualQueryRecord: Codable {
    let id: String
    let category: String
    let text: String
}

public enum S3S4SpikeRunner {
    private static let categories = [
        "apple", "bicycle", "calendar", "camera", "cat",
        "coffee", "document", "flower", "guitar", "mountain",
    ]
    private static let queryTemplates = [
        "a photo of a %@", "find the %@", "an image showing a %@", "the %@ picture",
        "a clear %@", "a colorful %@", "a simple %@ icon", "a large %@",
        "show me a %@", "the visible %@",
    ]

    public static func run(
        outputDirectory: URL,
        referenceImageModelURL: URL,
        referenceTextModelURL: URL
    ) async throws -> S3S4SpikeReport {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let raw = outputDirectory.appending(path: "raw", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let visualFrames = raw.appending(path: "visual-frames", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: visualFrames, withIntermediateDirectories: true)
        let imageContext = CIContext(options: [.useSoftwareRenderer: false])

        let resourceRoot = try MobileCLIPRuntime.bundledResourceRoot()
        let manifest = try JSONDecoder().decode(
            ModelResourceManifest.self,
            from: Data(contentsOf: resourceRoot.appending(path: "model-manifest.json"))
        )
        try ModelResourceIntegrity.verify(manifest, root: resourceRoot)
        let bundled = try MobileCLIPRuntime.bundled(computeUnits: .all)
        let reference = try MobileCLIPRuntime(
            imageModelURL: referenceImageModelURL,
            textModelURL: referenceTextModelURL,
            tokenizerRoot: resourceRoot,
            computeUnits: .all
        )

        let parityImageA = try render(categoryIndex: 0, variation: 0)
        let parityImageB = try render(categoryIndex: 0, variation: 0)
        let bundledImageReference = try await bundled.embed(image: MobileCLIPPixelBuffer(parityImageA))
        let sourceImageReference = try await reference.embed(image: MobileCLIPPixelBuffer(parityImageB))
        let bundledTextReference = try await bundled.embed(text: "a photo of an apple")
        let sourceTextReference = try await reference.embed(text: "a photo of an apple")
        let parity = S3ParityMetrics(
            imageCosineSimilarity: Double(dot(bundledImageReference, sourceImageReference)),
            textCosineSimilarity: Double(dot(bundledTextReference, sourceTextReference))
        )
        try writeFloatVectors([bundledImageReference], to: raw.appending(path: "packaged-parity-image.f32"))
        try writeFloatVectors([sourceImageReference], to: raw.appending(path: "source-parity-image.f32"))
        try writeFloatVectors([bundledTextReference], to: raw.appending(path: "packaged-parity-text.f32"))
        try writeFloatVectors([sourceTextReference], to: raw.appending(path: "source-parity-text.f32"))

        _ = try await bundled.embed(image: MobileCLIPPixelBuffer(render(categoryIndex: 1, variation: 0)))
        _ = try await bundled.embed(text: "warmup bicycle")

        let responsiveness = CaptureResponsivenessProbe()
        responsiveness.start()
        var imageLatencies: [Double] = []
        var imageEmbeddings: [[Float]] = []
        var corpusRecords: [VisualCorpusRecord] = []
        for categoryIndex in categories.indices {
            for variation in 0 ..< 50 {
                let buffer = try render(categoryIndex: categoryIndex, variation: variation)
                let imageID = "image-\(String(format: "%03d", corpusRecords.count))"
                try writePNG(
                    buffer: buffer,
                    context: imageContext,
                    to: visualFrames.appending(path: "\(imageID).png")
                )
                let started = ContinuousClock.now
                let embedding = try await bundled.embed(image: MobileCLIPPixelBuffer(buffer))
                imageLatencies.append(started.duration(to: .now).milliseconds)
                imageEmbeddings.append(embedding)
                corpusRecords.append(
                    VisualCorpusRecord(
                        id: imageID,
                        category: categories[categoryIndex],
                        variation: variation
                    )
                )
            }
        }

        var textLatencies: [Double] = []
        var textEmbeddings: [[Float]] = []
        var queries: [VisualQueryRecord] = []
        for category in categories {
            for template in queryTemplates {
                let text = String(format: template, category)
                let started = ContinuousClock.now
                textEmbeddings.append(try await bundled.embed(text: text))
                textLatencies.append(started.duration(to: .now).milliseconds)
                queries.append(
                    VisualQueryRecord(
                        id: "query-\(String(format: "%03d", queries.count))",
                        category: category,
                        text: text
                    )
                )
            }
        }
        let timerMetrics = responsiveness.stop()

        var recallHits = 0
        for (queryIndex, query) in queries.enumerated() {
            var ranked: [VectorSearchResult] = []
            ranked.reserveCapacity(imageEmbeddings.count)
            for imageIndex in imageEmbeddings.indices {
                ranked.append(VectorSearchResult(
                    index: imageIndex,
                    score: dot(textEmbeddings[queryIndex], imageEmbeddings[imageIndex])
                ))
            }
            ranked.sort {
                $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
            }
            if ranked.prefix(10).contains(where: { corpusRecords[$0.index].category == query.category }) {
                recallHits += 1
            }
        }

        try writeJSON(corpusRecords, to: raw.appending(path: "visual-corpus.json"))
        try writeJSON(queries, to: raw.appending(path: "visual-queries.json"))
        try writeFloatVectors(imageEmbeddings, to: raw.appending(path: "image-embeddings.f32"))
        try writeFloatVectors(textEmbeddings, to: raw.appending(path: "text-embeddings.f32"))

        let vectorScanStartedAtEpoch = Date().timeIntervalSince1970
        let vectorURL = outputDirectory.appending(path: "archive-1m.f16")
        defer { try? FileManager.default.removeItem(at: vectorURL) }
        let prototypes = try ExactVectorBenchmarkCorpus.write(
            vectorCount: 1_000_000,
            dimension: 512,
            modelVersion: MobileCLIPRuntime.version,
            to: vectorURL
        )
        let vectorFileBytes = try fileSize(vectorURL)
        let vectorFileHash = try ModelResourceIntegrity.sha256(of: vectorURL)
        let scanner = try ExactVectorScanner(url: vectorURL)
        let query = prototypes[7]
        _ = try scanner.search(query: query, range: 0 ..< 1_000_000, limit: 10)
        var unfilteredDurations: [Double] = []
        var firstOrdering: [Int] = []
        var stableOrdering = true
        for sample in 0 ..< 20 {
            let started = ContinuousClock.now
            let results = try scanner.search(query: query, range: 0 ..< 1_000_000, limit: 10)
            unfilteredDurations.append(started.duration(to: .now).milliseconds)
            if sample == 0 {
                firstOrdering = results.map(\.index)
            } else if results.map(\.index) != firstOrdering {
                stableOrdering = false
            }
        }
        var filteredDurations: [Double] = []
        for _ in 0 ..< 20 {
            let started = ContinuousClock.now
            _ = try scanner.search(query: query, range: 300_000 ..< 400_000, limit: 10)
            filteredDurations.append(started.duration(to: .now).milliseconds)
        }

        let parityCount = 4_096
        let accelerated = try scanner.search(query: query, range: 0 ..< parityCount, limit: 10)
        let scalar = scalarTopK(
            query: query,
            prototypes: prototypes,
            vectorCount: parityCount,
            limit: 10
        )
        let maximumScalarError = zip(accelerated, scalar).map { accelerated, reference in
            abs(accelerated.score - reference.score)
        }.max() ?? 0

        let truncatedURL = raw.appending(path: "truncated-vector-fixture.f16")
        let truncatedData = ExactVectorFileWriter.headerData(
            dimension: 512,
            vectorCount: 10,
            modelVersion: MobileCLIPRuntime.version
        ) + Data([0])
        try truncatedData.write(to: truncatedURL, options: .atomic)
        let truncatedDetected: Bool
        do {
            _ = try ExactVectorScanner(url: truncatedURL)
            truncatedDetected = false
        } catch ExactVectorError.truncatedPayload {
            truncatedDetected = true
        }
        let vectorScanEndedAtEpoch = Date().timeIntervalSince1970

        let report = S3S4SpikeReport(
            schemaVersion: 1,
            parity: parity,
            inference: S3InferenceMetrics(
                imageCount: imageEmbeddings.count,
                textQueryCount: textEmbeddings.count,
                imageP95Milliseconds: percentile(imageLatencies, 0.95),
                textP95Milliseconds: percentile(textLatencies, 0.95),
                visualRecallAt10: ratio(recallHits, queries.count),
                captureTimerP95Milliseconds: percentile(timerMetrics.intervalsMilliseconds, 0.95),
                captureTimerIntervalsOver100Milliseconds: timerMetrics.intervalsMilliseconds.filter { $0 > 100 }.count,
                maximumConcurrentInferenceJobs: 1
            ),
            packaging: S3PackagingMetrics(
                modelVersion: manifest.version,
                artifactCount: manifest.artifacts.count,
                verifiedArtifactCount: manifest.artifacts.count,
                bundledFootprintBytes: try directorySize(resourceRoot),
                runtimeDownloadAllowed: false,
                computeUnits: "MLComputeUnits.all (Neural Engine where available)"
            ),
            exactVectorScan: S4ScanMetrics(
                startedAtEpoch: vectorScanStartedAtEpoch,
                endedAtEpoch: vectorScanEndedAtEpoch,
                vectorCount: scanner.header.vectorCount,
                dimension: scanner.header.dimension,
                fileBytes: vectorFileBytes,
                vectorFileSHA256: vectorFileHash,
                unfilteredSampleCount: unfilteredDurations.count,
                unfilteredP95Milliseconds: percentile(unfilteredDurations, 0.95),
                unfilteredP99Milliseconds: percentile(unfilteredDurations, 0.99),
                filteredCandidateCount: 100_000,
                filteredP95Milliseconds: percentile(filteredDurations, 0.95),
                maximumScalarScoreError: Double(maximumScalarError),
                stableOrderingMatched: stableOrdering && accelerated.map(\.index) == scalar.map(\.index),
                truncatedFileDetectedBeforeResults: truncatedDetected
            )
        )
        try writeJSON(report, to: outputDirectory.appending(path: "report.json"))
        try Data("complete\n".utf8).write(
            to: outputDirectory.appending(path: "s3-s4-complete.marker"),
            options: .atomic
        )
        return report
    }

    private static func render(categoryIndex: Int, variation: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA,
            pixelAttributes as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CocoaError(.coderInvalidValue)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: base,
                  width: 256,
                  height: 256,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                      | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else {
            throw CocoaError(.coderInvalidValue)
        }
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.88, 0.12, 0.14), (0.10, 0.42, 0.88), (0.12, 0.64, 0.28),
            (0.18, 0.20, 0.26), (0.86, 0.50, 0.12), (0.42, 0.20, 0.08),
            (0.28, 0.46, 0.82), (0.72, 0.18, 0.62), (0.56, 0.28, 0.12), (0.20, 0.50, 0.42),
        ]
        let color = palette[categoryIndex]
        let background = 0.92 + CGFloat(variation % 5) * 0.01
        context.setFillColor(CGColor(red: background, green: background, blue: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        let inset = CGFloat(22 + variation % 8)
        context.fillEllipse(in: CGRect(x: inset, y: 66, width: 256 - inset * 2, height: 156))
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fill(CGRect(x: 12, y: 14, width: 232, height: 55))

        let label = categories[categoryIndex].uppercased()
        let fontSize: CGFloat = label.count > 7 ? 25 : 32
        let textAttributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
            kCTForegroundColorAttributeName: CGColor(gray: 0.05, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, label as CFString, textAttributes as CFDictionary)
        )
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: max(10, (256 - width) / 2), y: 27)
        CTLineDraw(line, context)
        return pixelBuffer
    }

    private static func scalarTopK(
        query: [Float],
        prototypes: [[Float]],
        vectorCount: Int,
        limit: Int
    ) -> [VectorSearchResult] {
        var results: [VectorSearchResult] = []
        results.reserveCapacity(vectorCount)
        for index in 0 ..< vectorCount {
            var score: Float = 0
            let prototypeIndex: Int = index % prototypes.count
            let vector: [Float] = prototypes[prototypeIndex]
            for component in query.indices { score += query[component] * vector[component] }
            results.append(VectorSearchResult(index: index, score: score))
        }
        results.sort {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
        return results.prefix(limit).map { $0 }
    }

    private static func dot(_ left: [Float], _ right: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(left, 1, right, 1, &result, vDSP_Length(min(left.count, right.count)))
        return result
    }

    private static func writeFloatVectors(_ vectors: [[Float]], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for vector in vectors {
            try vector.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        }
    }

    private static func writePNG(buffer: CVPixelBuffer, context: CIContext, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func directorySize(_ root: URL) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        return total
    }

    private static func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * quantile)) - 1))]
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 1 : Double(numerator) / Double(denominator)
    }
}

private final class CaptureResponsivenessProbe: @unchecked Sendable {
    struct Metrics { let intervalsMilliseconds: [Double] }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.justinhou.deepshelves.s3.capture-probe")
    private var timer: DispatchSourceTimer?
    private var lastTick = ContinuousClock.now
    private var intervals: [Double] = []

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        lastTick = .now
        timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ContinuousClock.now
            lock.lock()
            intervals.append(lastTick.duration(to: now).milliseconds)
            lastTick = now
            lock.unlock()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() -> Metrics {
        timer?.cancel()
        queue.sync {}
        lock.lock()
        let values = intervals
        lock.unlock()
        return Metrics(intervalsMilliseconds: values)
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
