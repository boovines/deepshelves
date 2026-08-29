import Darwin
import Foundation
import MemoryDesignSystem
import XCTest

final class AppearanceSettingsTests: XCTestCase {
    func testFreshProfileDefaultsToLightAndAllChoicesRoundTripOwnerOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = root.appending(path: "appearance.json")
        let store = FileMemoryAppearanceStateStore(fileURL: file)

        let fresh = try await store.load()
        XCTAssertEqual(fresh, .freshProfile)
        for mode in MemoryAppearanceMode.allCases {
            try await store.save(MemoryAppearanceState(mode: mode))
            let loaded = try await store.load()
            XCTAssertEqual(loaded.mode, mode)
        }
        XCTAssertEqual(try posixMode(at: root), 0o700)
        XCTAssertEqual(try posixMode(at: file), 0o600)
    }

    func testSymlinkedAppearanceFileFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target.json")
        try Data("{}".utf8).write(to: target)
        let link = root.appending(path: "appearance.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = FileMemoryAppearanceStateStore(fileURL: link)

        do {
            _ = try await store.load()
            XCTFail("symlinked appearance state must fail closed")
        } catch let error as MemoryAppearanceStateStoreError {
            XCTAssertEqual(error, .unsafePath)
        }
    }

    private func posixMode(at url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & 0o777
    }
}
