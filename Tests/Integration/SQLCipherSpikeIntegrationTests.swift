import Foundation
import MemoryStore
import XCTest

final class SQLCipherSpikeIntegrationTests: XCTestCase {
    func testEncryptedDatabaseRoundTripRejectsWrongKeyAndHidesSentinel() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lm008-sqlcipher-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "archive.sqlite3")
        let key = Data(repeating: 0x5A, count: LM008StoreDefaults.keyByteCount)
        let sentinel = "LM008-PLAINTEXT-SENTINEL-7F6E"

        let database = try SQLCipherSpikeDatabase(path: databaseURL, key: key)
        try database.insert(id: 1, text: sentinel)
        XCTAssertEqual(try database.text(id: 1), sentinel)
        XCTAssertFalse(try database.cipherVersion().isEmpty)
        try database.checkpoint()

        let bytes = try Data(contentsOf: databaseURL)
        XCTAssertNil(bytes.range(of: Data(sentinel.utf8)))
        XCTAssertThrowsError(
            try SQLCipherSpikeDatabase(
                path: databaseURL,
                key: Data(repeating: 0xA5, count: LM008StoreDefaults.keyByteCount)
            ).text(id: 1)
        )
    }

    func testKeyLengthFailsClosed() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "lm008-invalid-key-\(UUID().uuidString).sqlite3")
        XCTAssertThrowsError(
            try SQLCipherSpikeDatabase(path: databaseURL, key: Data(repeating: 0, count: 31))
        )
    }

    func testConcurrentRepresentativeWorkloadRemainsConsistent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lm008-concurrency-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SQLCipherSpikeDatabase(
            path: root.appending(path: "archive.sqlite3"),
            key: Data(repeating: 0x17, count: LM008StoreDefaults.keyByteCount)
        )

        let result = try await database.runConcurrentRepresentativeWorkload(
            iterationsPerRole: 50
        )
        XCTAssertEqual(result.roleCount, 5)
        XCTAssertEqual(result.failedOperationCount, 0)
        XCTAssertGreaterThan(result.successfulOperationCount, 0)
        XCTAssertTrue(result.integrityCheckPassed)
    }
}
