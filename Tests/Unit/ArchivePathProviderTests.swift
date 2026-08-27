import MemoryStore
import XCTest

final class ArchivePathProviderTests: XCTestCase {
    func testCreatesOwnerOnlyArchiveTree() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let support = temporaryRoot.appendingPathComponent("Application Support", isDirectory: true)
        let paths = try ArchivePathProvider.prepare(applicationSupportDirectory: support)

        XCTAssertEqual(paths.root, support.appendingPathComponent("LocalMemory", isDirectory: true))
        for directory in paths.directories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, ArchivePathProvider.directoryPermissions)
        }
        XCTAssertEqual(ArchivePathProvider.filePermissions, 0o600)
    }

    func testRootNameCannotEscapeApplicationSupport() throws {
        let support = URL(fileURLWithPath: "/tmp/deepshelves-test-support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = try ArchivePathProvider.prepare(applicationSupportDirectory: support)
        XCTAssertTrue(paths.root.path.hasPrefix(support.path + "/"))
    }
}

