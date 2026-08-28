import Darwin
import Foundation
import MemoryDesignSystem
import XCTest

final class GlobalSearchPanelStateTests: XCTestCase {
    func testDefaultShortcutAndPanelGeometryMatchTheFrozenUXContract() {
        XCTAssertEqual(GlobalSearchShortcut.default.key, .space)
        XCTAssertEqual(GlobalSearchShortcut.default.modifiers, [.option])
        XCTAssertEqual(GlobalSearchShortcut.default.displayName, "Option–Space")
        XCTAssertEqual(GlobalSearchPanelDefaults.width, 760)
        XCTAssertEqual(GlobalSearchPanelDefaults.height, 620)
        XCTAssertEqual(GlobalSearchPanelDefaults.minimumWidth, 640)
        XCTAssertEqual(GlobalSearchPanelDefaults.minimumHeight, 480)
        XCTAssertEqual(GlobalSearchPanelDefaults.warmAppearanceBudgetMilliseconds, 150)
        XCTAssertEqual(GlobalSearchPanelDefaults.coldAppearanceBudgetMilliseconds, 400)
    }

    func testPlacementUsesRememberedDisplayAndCentersInsideItsVisibleFrame() throws {
        let primary = SearchPanelDisplayDescriptor(
            identifier: "primary",
            visibleFrame: SearchPanelRectangle(x: 0, y: 0, width: 1_440, height: 900),
            containsPointer: true
        )
        let remembered = SearchPanelDisplayDescriptor(
            identifier: "remembered",
            visibleFrame: SearchPanelRectangle(x: 1_440, y: 80, width: 1_920, height: 1_080),
            containsPointer: false
        )

        let placement = try GlobalSearchPanelPlacement.resolve(
            displays: [primary, remembered],
            rememberedDisplayIdentifier: "remembered"
        )

        XCTAssertEqual(placement.displayIdentifier, "remembered")
        XCTAssertEqual(placement.frame.width, 760)
        XCTAssertEqual(placement.frame.height, 620)
        XCTAssertEqual(placement.frame.x, 2_020)
        XCTAssertEqual(placement.frame.y, 310)
    }

    func testPlacementFallsBackToPointerDisplayAndClampsToMinimumSize() throws {
        let compact = SearchPanelDisplayDescriptor(
            identifier: "compact",
            visibleFrame: SearchPanelRectangle(x: -640, y: 0, width: 640, height: 480),
            containsPointer: true
        )
        let other = SearchPanelDisplayDescriptor(
            identifier: "other",
            visibleFrame: SearchPanelRectangle(x: 0, y: 0, width: 1_200, height: 800),
            containsPointer: false
        )

        let placement = try GlobalSearchPanelPlacement.resolve(
            displays: [other, compact],
            rememberedDisplayIdentifier: "missing"
        )

        XCTAssertEqual(placement.displayIdentifier, "compact")
        XCTAssertEqual(placement.frame, compact.visibleFrame)
    }

    func testEmptyDisplayInventoryFailsClosed() {
        XCTAssertThrowsError(
            try GlobalSearchPanelPlacement.resolve(
                displays: [],
                rememberedDisplayIdentifier: nil
            )
        ) { error in
            XCTAssertEqual(error as? GlobalSearchPanelStateError, .noAvailableDisplay)
        }
    }

    func testShortcutCollisionHasOneRecoverableSettingsAction() {
        let collision = GlobalShortcutRegistrationState.collision(
            shortcut: .default,
            diagnosticCode: "LM-SHORTCUT-409"
        )

        XCTAssertFalse(collision.isRegistered)
        XCTAssertEqual(collision.statusLabel, "Shortcut unavailable")
        XCTAssertEqual(collision.recoveryActionTitle, "Choose a Different Shortcut…")
        XCTAssertEqual(collision.diagnosticCode, "LM-SHORTCUT-409")
        XCTAssertEqual(
            collision.recovering(with: GlobalSearchShortcut(key: .k, modifiers: [.command])),
            .inactive(shortcut: GlobalSearchShortcut(key: .k, modifiers: [.command]))
        )
    }

    func testEscapeAlwaysClosesTransientSearchPanelWithoutChangingNavigation() {
        let navigation = MainNavigationSnapshot(
            section: .timeline,
            selectedMomentID: UUID(uuidString: "00000000-0000-4000-8000-000000000102")!,
            inspectorRequested: true
        )
        let result = GlobalSearchPanelEscapeBehavior.apply(to: navigation)

        XCTAssertEqual(result.navigation, navigation)
        XCTAssertTrue(result.shouldClosePanel)
    }

    func testPanelStateRoundTripsOwnerOnlyAndRemembersDisplay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = root.appending(path: "search-panel-state.json")
        let store = FileGlobalSearchPanelStateStore(fileURL: file)
        let expected = GlobalSearchPanelSnapshot(
            shortcut: GlobalSearchShortcut(key: .k, modifiers: [.command, .shift]),
            rememberedDisplayIdentifier: "display-42",
            registrationState: .registered(
                shortcut: GlobalSearchShortcut(key: .k, modifiers: [.command, .shift])
            )
        )

        try await store.save(expected)

        let restored = try await store.load()
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(try posixMode(at: root), 0o700)
        XCTAssertEqual(try posixMode(at: file), 0o600)
    }

    private func posixMode(at url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & 0o777
    }
}
