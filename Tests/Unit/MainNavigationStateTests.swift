import Darwin
import Foundation
import MemoryDesignSystem
import XCTest

final class MainNavigationStateTests: XCTestCase {
    func testWindowGeometryMatchesNativeUXSpecification() {
        XCTAssertEqual(MainWindowDefaults.defaultWidth, 1_120)
        XCTAssertEqual(MainWindowDefaults.defaultHeight, 760)
        XCTAssertEqual(MainWindowDefaults.minimumWidth, 840)
        XCTAssertEqual(MainWindowDefaults.minimumHeight, 560)
        XCTAssertEqual(MainWindowDefaults.sidebarIdealWidth, 184)
        XCTAssertEqual(MainWindowDefaults.sidebarWidthRange, 168...240)
        XCTAssertEqual(MainWindowDefaults.inspectorIdealWidth, 264)
        XCTAssertEqual(MainWindowDefaults.inspectorWidthRange, 220...360)
        XCTAssertEqual(MainWindowDefaults.settingsWidth, 680)
        XCTAssertEqual(MainWindowDefaults.settingsHeight, 560)
    }

    func testInspectorCollapsesBelowNineHundredPointsOrWhenDismissed() {
        XCTAssertFalse(MainWindowDefaults.showsInspector(width: 899, requested: true))
        XCTAssertTrue(MainWindowDefaults.showsInspector(width: 900, requested: true))
        XCTAssertFalse(MainWindowDefaults.showsInspector(width: 1_120, requested: false))
    }

    func testNavigationVocabularyAndDefaultsAreStable() {
        XCTAssertEqual(
            MainNavigationSection.allCases,
            [.search, .timeline, .activity, .settings]
        )
        XCTAssertEqual(MainNavigationSnapshot.default.section, .timeline)
        XCTAssertNil(MainNavigationSnapshot.default.selectedMomentID)
        XCTAssertFalse(MainNavigationSnapshot.default.inspectorRequested)
    }

    func testNavigationStateRoundTripsWithOwnerOnlyPermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = root.appending(path: "navigation-state.json")
        let store = FileMainNavigationStateStore(fileURL: fileURL)
        let selectedMomentID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-4000-8000-000000000102")
        )
        let expected = MainNavigationSnapshot(
            section: .timeline,
            selectedMomentID: selectedMomentID,
            inspectorRequested: false
        )

        try await store.save(expected)

        let restored = try await store.load()
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(try posixMode(at: root), 0o700)
        XCTAssertEqual(try posixMode(at: fileURL), 0o600)
    }

    func testMalformedRestorationStateFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appending(path: "navigation-state.json")
        try Data("not-json".utf8).write(to: fileURL)
        let store = FileMainNavigationStateStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Malformed navigation state must not be accepted")
        } catch let error as MainNavigationStateStoreError {
            XCTAssertEqual(error, .invalidState)
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
