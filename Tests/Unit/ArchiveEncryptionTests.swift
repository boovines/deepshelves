import XCTest

@testable import MemoryStore

final class ArchiveEncryptionTests: XCTestCase {
    func testFileBackedArchiveRequiresA256BitKeyAndVerifiesCipherOnEveryOpen() throws {
        let fixture = try LM059ArchiveFixture(name: "cipher")
        defer { fixture.remove() }
        let key = Data(repeating: 0x59, count: LM008StoreDefaults.keyByteCount)

        XCTAssertThrowsError(
            try ArchiveDatabase(
                applicationSupportDirectory: fixture.applicationSupport,
                encryptionKey: Data(repeating: 0x59, count: 31)
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveDatabaseError, .invalidKeyLength)
        }

        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: key
        )
        XCTAssertFalse(try archive.cipherVersion().isEmpty)
        XCTAssertTrue(try archive.cipherIntegrityCheck())

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: key
        )
        XCTAssertTrue(try reopened.cipherIntegrityCheck())
        XCTAssertThrowsError(
            try ArchiveDatabase(
                applicationSupportDirectory: fixture.applicationSupport,
                encryptionKey: Data(repeating: 0xA5, count: LM008StoreDefaults.keyByteCount)
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveDatabaseError, .encryptedArchiveUnavailable)
        }
    }

    func testKeyManagerCreatesOnlyForFreshArchiveAndRecoversExistingKey() throws {
        let fixture = try LM059ArchiveFixture(name: "key-manager")
        defer { fixture.remove() }
        let store = LM059InMemoryKeyStore()
        let manager = ArchiveKeyManager(store: store)
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )

        let generated = try manager.resolve(paths: paths)
        XCTAssertEqual(generated.origin, .generated)
        XCTAssertEqual(generated.key.count, LM008StoreDefaults.keyByteCount)
        XCTAssertEqual(store.generateCount, 1)

        _ = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: generated.key
        )
        let recovered = try manager.resolve(paths: paths)
        XCTAssertEqual(recovered.origin, .existing)
        XCTAssertEqual(recovered.key, generated.key)
        XCTAssertEqual(store.generateCount, 1)
    }

    func testMissingKeyForExistingArchiveIsExplicitlyUnrecoverableAndNeverRegenerated() throws {
        let fixture = try LM059ArchiveFixture(name: "missing")
        defer { fixture.remove() }
        let store = LM059InMemoryKeyStore()
        let manager = ArchiveKeyManager(store: store)
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let initial = try manager.resolve(paths: paths)
        _ = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: initial.key
        )
        store.removeValue()

        XCTAssertThrowsError(try manager.resolve(paths: paths)) { error in
            XCTAssertEqual(error as? ArchiveKeyManagerError, .keyMissingForExistingArchive)
        }
        XCTAssertEqual(store.generateCount, 1)
    }

    func testMissingKeyDoesNotRegenerateWhenOnlyNonDatabaseArchiveDataRemains() throws {
        let fixture = try LM059ArchiveFixture(name: "orphan-media")
        defer { fixture.remove() }
        let store = LM059InMemoryKeyStore()
        let manager = ArchiveKeyManager(store: store)
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        try Data("encrypted-media-placeholder".utf8).write(
            to: paths.media.appending(path: "orphan.mov")
        )

        XCTAssertThrowsError(try manager.resolve(paths: paths)) { error in
            XCTAssertEqual(error as? ArchiveKeyManagerError, .keyMissingForExistingArchive)
        }
        XCTAssertEqual(store.generateCount, 0)
    }

    func testResetRejectsEveryNonExactConfirmationWithoutSideEffects() throws {
        let fixture = try LM059ArchiveFixture(name: "confirmation")
        defer { fixture.remove() }
        let store = LM059InMemoryKeyStore()
        let manager = ArchiveKeyManager(store: store)
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let initial = try manager.resolve(paths: paths)
        _ = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: initial.key
        )
        let databaseBytes = try Data(contentsOf: paths.databaseFile)
        let reset = ArchiveResetCoordinator(store: store)

        for value in [
            "",
            "delete local memory archive",
            "DELETE LOCAL MEMORY",
            " DELETE LOCAL MEMORY ARCHIVE",
            "DELETE LOCAL MEMORY ARCHIVE ",
        ] {
            XCTAssertThrowsError(
                try reset.reset(
                    paths: paths,
                    typedConfirmation: value
                )
            ) { error in
                XCTAssertEqual(error as? ArchiveResetError, .confirmationMismatch)
            }
            XCTAssertEqual(try Data(contentsOf: paths.databaseFile), databaseBytes)
            XCTAssertEqual(
                try store.fetch(account: SharedKeychainKeyStore.archiveAccount), initial.key)
        }
    }

    func testExactResetDeletesWholeArchiveAndKeyThenPermitsFreshEncryptedBootstrap() throws {
        let fixture = try LM059ArchiveFixture(name: "reset")
        defer { fixture.remove() }
        let store = LM059InMemoryKeyStore()
        let manager = ArchiveKeyManager(store: store)
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let initial = try manager.resolve(paths: paths)
        _ = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: initial.key
        )
        let mediaSentinel = paths.media.appending(path: "LM059_RESET_SENTINEL.mov")
        try Data("LM059_RESET_SENTINEL".utf8).write(to: mediaSentinel)

        let receipt = try ArchiveResetCoordinator(store: store).reset(
            paths: paths,
            typedConfirmation: ArchiveResetCoordinator.requiredConfirmation
        )
        XCTAssertEqual(receipt.deletedRoot, paths.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertNil(try store.fetch(account: SharedKeychainKeyStore.archiveAccount))

        let freshPaths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let fresh = try manager.resolve(paths: freshPaths)
        XCTAssertEqual(fresh.origin, .generated)
        XCTAssertNotEqual(fresh.key, initial.key)
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fresh.key
        )
        XCTAssertTrue(try archive.cipherIntegrityCheck())
    }

    func testResetRollsArchiveBackWhenKeyDeletionFails() throws {
        let fixture = try LM059ArchiveFixture(name: "rollback")
        defer { fixture.remove() }
        let store = LM059InMemoryKeyStore()
        let manager = ArchiveKeyManager(store: store)
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let initial = try manager.resolve(paths: paths)
        _ = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: initial.key
        )
        store.deleteError = .injectedDeleteFailure

        XCTAssertThrowsError(
            try ArchiveResetCoordinator(store: store).reset(
                paths: paths,
                typedConfirmation: ArchiveResetCoordinator.requiredConfirmation
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databaseFile.path))
        XCTAssertEqual(try store.fetch(account: SharedKeychainKeyStore.archiveAccount), initial.key)
        XCTAssertTrue(
            try ArchiveDatabase(
                applicationSupportDirectory: fixture.applicationSupport,
                encryptionKey: initial.key
            ).cipherIntegrityCheck()
        )
    }
}

private enum LM059StoreError: Error {
    case injectedDeleteFailure
}

private final class LM059InMemoryKeyStore: ArchiveKeyStoring, @unchecked Sendable {
    private var value: Data?
    private(set) var generateCount = 0
    var deleteError: LM059StoreError?

    func fetch(account _: String) throws -> Data? {
        value
    }

    func generateAndStore(account _: String) throws -> Data {
        generateCount += 1
        let generated = Data(
            (0..<LM008StoreDefaults.keyByteCount).map {
                UInt8(($0 + generateCount) % 255)
            })
        value = generated
        return generated
    }

    func store(_ key: Data, account _: String) throws {
        value = key
    }

    func delete(account _: String) throws {
        if let deleteError { throw deleteError }
        value = nil
    }

    func removeValue() {
        value = nil
    }
}

private struct LM059ArchiveFixture {
    let root: URL
    let applicationSupport: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm059-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        applicationSupport = root.appending(
            path: "Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
