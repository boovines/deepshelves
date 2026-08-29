import Foundation
import XCTest

@testable import MemoryStore

final class LocalDiagnosticsTests: XCTestCase {
    func testDiagnosticRecordRejectsFreeFormContentAndEncodesOnlyTypedFields() throws {
        let remoteSentinel = ["https:", "", "example.test"].joined(separator: "/")
        XCTAssertThrowsError(
            try LocalDiagnosticRecord(
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
                event: .error,
                state: .unavailable,
                captureID: nil,
                errorCode: "secret query \(remoteSentinel)",
                metrics: [:]
            )
        )

        let record = try LocalDiagnosticRecord(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            event: .resourceSample,
            state: .recording,
            captureID: UUID(uuidString: "80000000-0000-4000-8000-000000000001"),
            errorCode: nil,
            metrics: [
                .residentMemoryBytes: 512 * 1_024 * 1_024,
                .pendingIndexJobs: 12,
            ]
        )
        let encoded = try ContentFreeDiagnosticCodec.encoder.encode(record)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(text.contains("query"))
        XCTAssertFalse(text.contains("title"))
        XCTAssertFalse(text.contains("url"))
        XCTAssertEqual(
            try ContentFreeDiagnosticCodec.decoder.decode(
                LocalDiagnosticRecord.self, from: encoded), record)
    }

    func testRotatingLogIsOwnerOnlyAndStrictlyBounded() throws {
        let root = temporaryDirectory(named: "rotation")
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = try ContentFreeDiagnosticLogger(
            directory: root,
            maximumFileBytes: 768,
            maximumFiles: 3
        )
        let record = try sampleRecord()

        for _ in 0..<80 {
            try logger.append(record)
        }

        let files = try logger.logFiles()
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertTrue(try files.allSatisfy { try fileSize($0) <= 768 })
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertTrue(try files.allSatisfy { try permissions($0) == 0o600 })
    }

    func testExportRevalidatesAndContainsNoContentSentinels() throws {
        let root = temporaryDirectory(named: "export")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appending(path: "logs", directoryHint: .isDirectory)
        let exports = root.appending(path: "exports", directoryHint: .isDirectory)
        let logger = try ContentFreeDiagnosticLogger(directory: logs)
        let record = try sampleRecord()
        try logger.append(record)
        var tampered = try ContentFreeDiagnosticCodec.encoder.encode(record)
        tampered.removeLast()
        tampered.append(contentsOf: Data(",\"query\":\"secret query\"}\n".utf8))
        let logURL = try XCTUnwrap(logger.logFiles().first)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: tampered)
        try handle.close()
        let snapshot = try LocalDiagnosticsSnapshot(
            measuredAt: Date(timeIntervalSince1970: 1_800_000_100),
            energyCondition: .nominal,
            residentMemoryBytes: 512 * 1_024 * 1_024,
            databaseBytes: 20_000,
            mediaBytes: 40_000,
            logBytes: 1_000,
            projectedMonthlyStorageBytes: 2_000_000,
            pendingIndexJobs: 4,
            lastErrorCode: "LM-INDEX-RETRY"
        )

        let result = try LocalDiagnosticExporter.export(
            logger: logger,
            snapshot: snapshot,
            destinationDirectory: exports,
            now: { Date(timeIntervalSince1970: 1_800_000_200) }
        )

        XCTAssertEqual(result.preview.recordCount, 2)
        XCTAssertEqual(
            Set(result.preview.files), ["events.jsonl", "manifest.json", "metrics.json"])
        let bytes = try recursiveBytes(at: result.bundleURL)
        let remoteSentinel = ["https:", "", "example.test"].joined(separator: "/")
        for sentinel in ["secret query", "window title", remoteSentinel, "agent content"] {
            XCTAssertFalse(bytes.contains(Data(sentinel.utf8)))
        }
        XCTAssertEqual(try permissions(result.bundleURL), 0o700)
        XCTAssertTrue(
            try result.preview.files.allSatisfy {
                try permissions(result.bundleURL.appending(path: $0)) == 0o600
            }
        )
    }

    func testHealthProjectionUsesReleaseBudgetsWithoutCapturedContent() throws {
        let snapshot = try LocalDiagnosticsSnapshot(
            measuredAt: Date(timeIntervalSince1970: 1_800_000_100),
            energyCondition: .constrained,
            residentMemoryBytes: 800 * 1_024 * 1_024,
            databaseBytes: 2_000,
            mediaBytes: 3_000,
            logBytes: 400,
            projectedMonthlyStorageBytes: 21 * 1_024 * 1_024 * 1_024,
            pendingIndexJobs: 12,
            lastErrorCode: nil
        )

        let projection = LocalDiagnosticsHealthProjection(snapshot: snapshot)
        let encoded = try ContentFreeDiagnosticCodec.encoder.encode(snapshot)

        XCTAssertEqual(projection.energy, .warning)
        XCTAssertEqual(projection.memory, .critical)
        XCTAssertEqual(projection.storage, .critical)
        XCTAssertEqual(projection.indexBacklog, .warning)
        XCTAssertLessThan(encoded.count, 1_024)
    }

    func testFiveHundredLogWritesStayWithinSafeModelOverheadAndBounds() throws {
        let root = temporaryDirectory(named: "overhead")
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = try ContentFreeDiagnosticLogger(
            directory: root,
            maximumFileBytes: 64 * 1_024,
            maximumFiles: 3
        )
        let record = try sampleRecord()
        let started = ContinuousClock.now

        for _ in 0..<500 {
            try logger.append(record)
        }

        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertLessThanOrEqual(try logger.logFiles().count, 3)
    }

    private func sampleRecord() throws -> LocalDiagnosticRecord {
        try LocalDiagnosticRecord(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            event: .queueDepth,
            state: .recording,
            captureID: nil,
            errorCode: nil,
            metrics: [.pendingIndexJobs: 12]
        )
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "lm080-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func fileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }

    private func recursiveBytes(at root: URL) throws -> Data {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys
            )
        else { return Data() }
        var result = Data()
        for case let url as URL in enumerator
        where try url.resourceValues(forKeys: Set(keys)).isRegularFile == true {
            result.append(try Data(contentsOf: url))
        }
        return result
    }
}
