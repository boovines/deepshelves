import Accelerate
import CryptoKit
import Darwin
import Foundation
import MemoryContracts
import MemoryStore
import XCTest

@testable import MemorySearch

final class ExactVisualVectorSearchTests: XCTestCase {
    func testSparsePrefilterScoresScalarParityAndStableTopK() async throws {
        let fixture = try VectorSearchFixture(
            vectors: [
                unit(0),
                unit(0),
                unit(0),
                normalized([0.6, 0.8]),
                unit(1),
            ]
        )
        defer { fixture.remove() }
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        let candidates = [
            fixture.candidate(0, id: uuid(2), date: old),
            fixture.candidate(1, id: uuid(3), date: recent),
            fixture.candidate(2, id: uuid(1), date: recent),
            fixture.candidate(3, id: uuid(4), date: recent),
        ]
        let snapshot = fixture.snapshot(candidates: candidates)

        let results = try await ExactVisualVectorSearcher(chunkCandidateCount: 2).search(
            query: unit(0),
            snapshot: snapshot,
            limit: 4
        )

        XCTAssertEqual(results.map(\.frameID), [uuid(1), uuid(3), uuid(2), uuid(4)])
        XCTAssertEqual(results[0].score, 1, accuracy: 0.001)
        XCTAssertEqual(results[3].score, 0.6, accuracy: 0.001)
        XCTAssertFalse(results.contains(where: { $0.frameID == uuid(5) }))
    }

    func testCancellationIsCheckedBeforeMapping() async throws {
        let fixture = try VectorSearchFixture(vectors: [unit(0)])
        defer { fixture.remove() }
        let query = unit(0)
        let snapshot = fixture.snapshot(candidates: [
            fixture.candidate(0, id: uuid(1), date: Date())
        ])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExactVisualVectorSearcher().search(
                query: query,
                snapshot: snapshot,
                limit: 1
            )
        }

        do {
            _ = try await task.value
            XCTFail("cancelled search must not map or return results")
        } catch is CancellationError {
        }
    }

    func testWinnerChecksumMismatchFailsClosed() async throws {
        let fixture = try VectorSearchFixture(vectors: [unit(0), unit(1)])
        defer { fixture.remove() }
        let valid = fixture.candidate(0, id: uuid(1), date: Date())
        let corrupted = ArchiveVectorScanCandidate(
            frameID: valid.frameID,
            capturedAt: valid.capturedAt,
            byteOffset: valid.byteOffset,
            norm: valid.norm,
            contentHash: Data(repeating: 0xFF, count: 32)
        )

        do {
            _ = try await ExactVisualVectorSearcher().search(
                query: unit(0),
                snapshot: fixture.snapshot(candidates: [corrupted]),
                limit: 1
            )
            XCTFail("corrupt result evidence must fail the complete search")
        } catch {
            XCTAssertEqual(error as? ExactVisualVectorSearchError, .checksumMismatch)
        }
    }

    func testFileChangeAndHeaderTamperAreRejectedBeforeResults() async throws {
        let truncated = try VectorSearchFixture(vectors: [unit(0)])
        defer { truncated.remove() }
        let truncatedSnapshot = truncated.snapshot(candidates: [
            truncated.candidate(0, id: uuid(1), date: Date())
        ])
        let handle = try FileHandle(forWritingTo: truncated.url)
        try handle.truncate(atOffset: UInt64(truncatedSnapshot.fileByteCount - 1))
        try handle.close()
        do {
            _ = try await ExactVisualVectorSearcher().search(
                query: unit(0), snapshot: truncatedSnapshot, limit: 1)
            XCTFail("changed file must fail")
        } catch {
            XCTAssertEqual(error as? ExactVisualVectorSearchError, .fileChanged)
        }

        let tampered = try VectorSearchFixture(vectors: [unit(0)])
        defer { tampered.remove() }
        let descriptor = Darwin.open(tampered.url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var byte: UInt8 = 0
        XCTAssertEqual(pwrite(descriptor, &byte, 1, 0), 1)
        XCTAssertEqual(fsync(descriptor), 0)
        Darwin.close(descriptor)
        do {
            _ = try await ExactVisualVectorSearcher().search(
                query: unit(0),
                snapshot: tampered.snapshot(candidates: [
                    tampered.candidate(0, id: uuid(1), date: Date())
                ]),
                limit: 1
            )
            XCTFail("tampered header must fail")
        } catch {
            XCTAssertEqual(error as? ExactVisualVectorSearchError, .invalidHeader)
        }

        let malformed = try VectorSearchFixture(vectors: [unit(0)])
        defer { malformed.remove() }
        let valid = malformed.candidate(0, id: uuid(1), date: Date())
        let invalid = ArchiveVectorScanCandidate(
            frameID: valid.frameID,
            capturedAt: valid.capturedAt,
            byteOffset: -1,
            norm: valid.norm,
            contentHash: valid.contentHash
        )
        do {
            _ = try await ExactVisualVectorSearcher().search(
                query: unit(0),
                snapshot: malformed.snapshot(candidates: [invalid]),
                limit: 1
            )
            XCTFail("malformed snapshot offset must fail before a mapped-memory copy")
        } catch {
            XCTAssertEqual(error as? ExactVisualVectorSearchError, .invalidSnapshot)
        }
    }

    func testScaleBenchmarkAt100k500kAnd1M() async throws {
        guard ProcessInfo.processInfo.environment["LM052_SCALE_TESTS"] == "1" else {
            throw XCTSkip("Run only from the LM-052 scale gate")
        }
        let fixture = try ScaleVectorSearchFixture(vectorCount: 1_000_000)
        defer { fixture.remove() }
        let searcher = ExactVisualVectorSearcher(chunkCandidateCount: 16_384)
        let query = unit(0)
        let baselineResidentBytes = residentBytes()
        var metrics: [[String: Double]] = []
        for vectorCount in [100_000, 500_000, 1_000_000] {
            let snapshot = fixture.snapshot(vectorCount: vectorCount)
            _ = try await searcher.search(query: query, snapshot: snapshot, limit: 10)
            var durations: [Double] = []
            for _ in 0..<20 {
                let started = ContinuousClock.now
                let results = try await searcher.search(
                    query: query, snapshot: snapshot, limit: 10)
                durations.append(started.duration(to: .now).milliseconds)
                XCTAssertEqual(results.count, 10)
                XCTAssertEqual(results[0].score, 1, accuracy: 0.001)
            }
            metrics.append([
                "vectorCount": Double(vectorCount),
                "p95Milliseconds": percentile(durations, 0.95),
                "p99Milliseconds": percentile(durations, 0.99),
            ])
        }
        let incrementalResidentMegabytes =
            Double(max(0, residentBytes() - baselineResidentBytes)) / 1_048_576
        let encoded = try JSONSerialization.data(
            withJSONObject: [
                "scales": metrics,
                "incrementalResidentMegabytes": incrementalResidentMegabytes,
            ], options: [.sortedKeys])
        print("LM052_SCALE_METRICS \(String(decoding: encoded, as: UTF8.self))")
        XCTAssertLessThan(try XCTUnwrap(metrics.last?["p95Milliseconds"]), 750)
        XCTAssertLessThan(try XCTUnwrap(metrics.last?["p99Milliseconds"]), 1_000)
        XCTAssertLessThan(try XCTUnwrap(metrics.first?["p95Milliseconds"]), 250)
        XCTAssertLessThan(incrementalResidentMegabytes, 500)
    }

    func testLM055MillionFrameHybridLatencyAndMemory() async throws {
        guard ProcessInfo.processInfo.environment["LM055_SCALE_TESTS"] == "1" else {
            throw XCTSkip("Run only from the LM-055 scale gate")
        }
        let fixture = try ScaleVectorSearchFixture(vectorCount: 1_000_000)
        defer { fixture.remove() }
        let snapshot = fixture.snapshot(vectorCount: 1_000_000)
        let visual = LM055MillionVisualEngine(snapshot: snapshot)
        let lexical = LM055MillionLexicalEngine()
        let now = Date(timeIntervalSince1970: 1_000_001)
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: -1),
            end: now
        )
        let policy = try AccessPolicy(
            id: UUID(uuidString: "55000000-0000-0000-0000-000000000001")!,
            name: "LM-055 million-frame benchmark",
            allowedInterval: interval,
            allowedBundleIDs: ["com.example.scale"],
            allowedHosts: [],
            maxResults: 100,
            expiresAt: now.addingTimeInterval(3_600),
            createdByUser: true
        )
        let request = try SearchRequest(
            query: "million frame fixture",
            interval: nil,
            bundleIDs: [],
            hosts: [],
            mode: .hybrid,
            pageSize: 100,
            cursor: nil,
            accessPolicy: policy
        )
        let engine = try HybridSearchEngine(
            lexical: lexical,
            visual: visual,
            cursorSigningKey: Data(repeating: 0x55, count: 32),
            now: { now }
        )
        let baselineResidentBytes = residentBytes()
        _ = try await engine.search(request)
        var durations: [Double] = []
        for _ in 0..<20 {
            let started = ContinuousClock.now
            let page = try await engine.search(request)
            durations.append(started.duration(to: .now).milliseconds)
            XCTAssertEqual(page.results.count, 100)
            XCTAssertNil(page.nextCursor)
        }
        let p95 = percentile(durations, 0.95)
        let p99 = percentile(durations, 0.99)
        let incrementalResidentMegabytes =
            Double(max(0, residentBytes() - baselineResidentBytes)) / 1_048_576
        let encoded = try JSONSerialization.data(
            withJSONObject: [
                "vectorCount": 1_000_000,
                "sampleCount": durations.count,
                "p95Milliseconds": p95,
                "p99Milliseconds": p99,
                "incrementalResidentMegabytes": incrementalResidentMegabytes,
                "resultCount": 100,
            ],
            options: [.sortedKeys]
        )
        print("LM055_SCALE_METRICS \(String(decoding: encoded, as: UTF8.self))")
        XCTAssertLessThan(p95, 750)
        XCTAssertLessThan(p99, 1_000)
        XCTAssertLessThan(incrementalResidentMegabytes, 500)
    }

    private func unit(_ index: Int) -> [Float] {
        var values = [Float](repeating: 0, count: 512)
        values[index] = 1
        return values
    }

    private func normalized(_ prefix: [Float]) -> [Float] {
        prefix + [Float](repeating: 0, count: 512 - prefix.count)
    }

    private func uuid(_ value: UInt64) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", value))!
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1)
        return sorted[index]
    }

    private func residentBytes() -> Int64 {
        var information = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int64(information.resident_size) : 0
    }
}

private struct LM055MillionVisualEngine: SearchEngine {
    let snapshot: ArchiveVectorScanSnapshot

    func search(_ request: SearchRequest) async throws -> SearchPage {
        XCTAssertEqual(request.mode, .visualOnly)
        try await Task.sleep(for: .milliseconds(8))
        let matches = try await ExactVisualVectorSearcher(chunkCandidateCount: 16_384).search(
            query: [1] + [Float](repeating: 0, count: 511),
            snapshot: snapshot,
            limit: 100
        )
        let results = try matches.enumerated().map { offset, match in
            try LM055ScaleResult.make(
                frameID: match.frameID,
                capturedAt: match.capturedAt,
                textRank: nil,
                visualRank: offset + 1,
                source: .visual
            )
        }
        return try SearchPage(results: results, nextCursor: nil)
    }
}

private struct LM055MillionLexicalEngine: SearchEngine {
    func search(_ request: SearchRequest) async throws -> SearchPage {
        XCTAssertEqual(request.mode, .textOnly)
        try await Task.sleep(for: .milliseconds(4))
        let results = try (0..<100).map { offset in
            let value = UInt64(999_999 - offset)
            return try LM055ScaleResult.make(
                frameID: LM055ScaleResult.frameID(value),
                capturedAt: Date(timeIntervalSince1970: Double(value)),
                textRank: offset + 1,
                visualRank: nil,
                source: .accessibility
            )
        }
        return try SearchPage(results: results, nextCursor: nil)
    }
}

private enum LM055ScaleResult {
    static func frameID(_ value: UInt64) -> UUID {
        UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
                UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
            )
        )
    }

    static func make(
        frameID: UUID,
        capturedAt: Date,
        textRank: Int?,
        visualRank: Int?,
        source: SearchEvidenceSource
    ) throws -> SearchResult {
        try SearchResult(
            frameID: frameID,
            capturedAt: capturedAt,
            foreground: ForegroundContext(
                bundleID: "com.example.scale",
                applicationName: "Scale Fixture",
                processID: nil,
                windowTitle: "Scale result",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: nil,
            mediaLocator: .opaqueResourceID("lm055-\(frameID.uuidString.lowercased())"),
            evidence: [
                SearchEvidence(
                    source: source,
                    matchedText: source == .visual ? nil : "million frame fixture",
                    score: 1
                )
            ],
            textRank: textRank,
            visualRank: visualRank,
            fusedScore: 1
        )
    }
}

private final class ScaleVectorSearchFixture {
    let root: URL
    let url: URL
    let generation = UUID()
    let modelHash = Data(repeating: 0x52, count: 32)
    private let vectorHash: Data

    init(vectorCount: Int) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm052-scale-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        url = root.appending(path: "vectors.f16")
        let vector = try VectorSearchFixture.float16Bytes(Self.unitVector())
        vectorHash = Data(SHA256.hash(data: vector))
        var block = Data(capacity: vector.count * 1_024)
        for _ in 0..<1_024 { block.append(vector) }
        FileManager.default.createFile(
            atPath: url.path,
            contents: VectorSearchFixture.header(modelHash: modelHash, generation: generation),
            attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = 0
        while vectorCount - written >= 1_024 {
            try handle.write(contentsOf: block)
            written += 1_024
        }
        if written < vectorCount {
            try handle.write(contentsOf: block.prefix((vectorCount - written) * vector.count))
        }
        try handle.synchronize()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func snapshot(vectorCount: Int) -> ArchiveVectorScanSnapshot {
        var candidates: [ArchiveVectorScanCandidate] = []
        candidates.reserveCapacity(vectorCount)
        for index in 0..<vectorCount {
            candidates.append(
                ArchiveVectorScanCandidate(
                    frameID: uuid(UInt64(index)),
                    capturedAt: Date(timeIntervalSince1970: Double(index)),
                    byteOffset: Int64(192 + index * 1_024),
                    norm: 1,
                    contentHash: vectorHash
                ))
        }
        return ArchiveVectorScanSnapshot(
            fileURL: url,
            fileByteCount: Int64(192 + 1_000_000 * 1_024),
            generation: generation,
            modelHash: modelHash,
            dimension: 512,
            vectorByteCount: 1_024,
            candidates: candidates
        )
    }

    private func uuid(_ value: UInt64) -> UUID {
        UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
                UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
            ))
    }

    private static func unitVector() -> [Float] {
        [1] + [Float](repeating: 0, count: 511)
    }
}

extension Duration {
    fileprivate var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private final class VectorSearchFixture: @unchecked Sendable {
    let root: URL
    let url: URL
    let generation = UUID()
    let modelHash = Data(repeating: 0x52, count: 32)
    let encoded: [Data]
    let norms: [Double]

    init(vectors: [[Float]]) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm052-search-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        url = root.appending(path: "vectors.f16")
        var encoded: [Data] = []
        var norms: [Double] = []
        for vector in vectors {
            let result = try Self.float16(vector)
            encoded.append(result.bytes)
            norms.append(result.norm)
        }
        self.encoded = encoded
        self.norms = norms
        var contents = Self.header(modelHash: modelHash, generation: generation)
        for bytes in encoded { contents.append(bytes) }
        try contents.write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func candidate(_ index: Int, id: UUID, date: Date) -> ArchiveVectorScanCandidate {
        ArchiveVectorScanCandidate(
            frameID: id,
            capturedAt: date,
            byteOffset: Int64(192 + index * 1_024),
            norm: norms[index],
            contentHash: Data(SHA256.hash(data: encoded[index]))
        )
    }

    func snapshot(candidates: [ArchiveVectorScanCandidate]) -> ArchiveVectorScanSnapshot {
        ArchiveVectorScanSnapshot(
            fileURL: url,
            fileByteCount: Int64(192 + encoded.count * 1_024),
            generation: generation,
            modelHash: modelHash,
            dimension: 512,
            vectorByteCount: 1_024,
            candidates: candidates
        )
    }

    fileprivate static func header(modelHash: Data, generation: UUID) -> Data {
        var data = Data(repeating: 0, count: 192)
        data.replaceSubrange(0..<8, with: Data("DSVEC002".utf8))
        write(UInt32(2), at: 8, into: &data)
        write(UInt32(192), at: 12, into: &data)
        write(UInt32(512), at: 16, into: &data)
        write(UInt32(1_024), at: 20, into: &data)
        data.replaceSubrange(24..<56, with: modelHash)
        var uuid = generation.uuid
        withUnsafeBytes(of: &uuid) { data.replaceSubrange(120..<136, with: $0) }
        data.replaceSubrange(136..<168, with: Data(SHA256.hash(data: data[0..<136])))
        return data
    }

    fileprivate static func float16Bytes(_ values: [Float]) throws -> Data {
        try float16(values).bytes
    }

    private static func float16(_ values: [Float]) throws -> (bytes: Data, norm: Double) {
        var half = [UInt16](repeating: 0, count: values.count)
        let error = values.withUnsafeBytes { sourceBytes in
            half.withUnsafeMutableBytes { destinationBytes in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sourceBytes.baseAddress),
                    height: 1, width: vImagePixelCount(values.count),
                    rowBytes: values.count * MemoryLayout<Float>.size
                )
                var destination = vImage_Buffer(
                    data: destinationBytes.baseAddress,
                    height: 1, width: vImagePixelCount(values.count),
                    rowBytes: values.count * 2
                )
                return vImageConvert_PlanarFtoPlanar16F(
                    &source, &destination, vImage_Flags(kvImageNoFlags))
            }
        }
        guard error == kvImageNoError else {
            throw ExactVisualVectorSearchError.conversionFailed(Int(error))
        }
        let bytes = half.withUnsafeBytes { Data($0) }
        return (bytes, sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) }))
    }

    private static func write<T: FixedWidthInteger>(
        _ value: T, at offset: Int, into data: inout Data
    ) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) {
            data.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }
}
