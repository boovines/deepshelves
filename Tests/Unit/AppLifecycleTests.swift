import Foundation
import MemoryCapture
import Testing

@Suite("LM-009 application lifecycle")
struct AppLifecycleTests {
    @Test("Every fake runtime state has an exact menu projection")
    func menuProjectionMatchesRuntimeState() {
        let expectations: [LocalMemoryRuntimeStatus: RuntimeMenuProjection] = [
            .recording: RuntimeMenuProjection(
                statusLabel: "Recording",
                statusSymbol: "record.circle",
                primaryActionLabel: "Pause Recording"
            ),
            .paused: RuntimeMenuProjection(
                statusLabel: "Paused",
                statusSymbol: "pause.circle",
                primaryActionLabel: "Resume Recording"
            ),
            .permissionRequired: RuntimeMenuProjection(
                statusLabel: "Recording unavailable",
                statusSymbol: "exclamationmark.triangle",
                primaryActionLabel: "Review Permissions…"
            ),
            .diskFull: RuntimeMenuProjection(
                statusLabel: "Recording unavailable",
                statusSymbol: "externaldrive.badge.exclamationmark",
                primaryActionLabel: "Manage Storage…"
            ),
            .indexing: RuntimeMenuProjection(
                statusLabel: "Indexing",
                statusSymbol: "arrow.triangle.2.circlepath",
                primaryActionLabel: "Pause Recording"
            ),
        ]

        #expect(Set(expectations.keys) == Set(LocalMemoryRuntimeStatus.allCases))
        for status in LocalMemoryRuntimeStatus.allCases {
            #expect(status.menuProjection == expectations[status])
        }
    }

    @Test("A relaunch restores runtime state but never restores a main window implicitly")
    func relaunchRestoresOnlyRuntimeState() async throws {
        let stateURL = temporaryStateURL()
        let first = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )

        let firstLaunch = try await first.launch(initialStatus: .recording)
        #expect(firstLaunch.status == .recording)
        #expect(firstLaunch.launchCount == 1)
        #expect(firstLaunch.mainWindowVisible == false)

        _ = try await first.setMainWindowVisible(true)
        _ = try await first.transition(to: .paused)

        let relaunched = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )
        let secondLaunch = try await relaunched.launch(initialStatus: .diskFull)
        #expect(secondLaunch.status == .paused)
        #expect(secondLaunch.launchCount == 2)
        #expect(secondLaunch.mainWindowVisible == false)

        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Pause toggling is deterministic and unavailable states do not pretend to resume")
    func pauseToggleBehavior() async throws {
        let lifecycle = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: temporaryStateURL())
        )
        _ = try await lifecycle.launch(initialStatus: .recording)
        #expect(try await lifecycle.performPrimaryAction().status == .paused)
        #expect(try await lifecycle.performPrimaryAction().status == .recording)
        _ = try await lifecycle.transition(to: .indexing)
        #expect(try await lifecycle.performPrimaryAction().status == .paused)
        _ = try await lifecycle.transition(to: .permissionRequired)
        #expect(try await lifecycle.performPrimaryAction().status == .permissionRequired)
        _ = try await lifecycle.transition(to: .diskFull)
        #expect(try await lifecycle.performPrimaryAction().status == .diskFull)
    }

    @Test("Corrupt state fails closed without presenting a window")
    func corruptStateFailsClosed() async throws {
        let stateURL = temporaryStateURL()
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: stateURL)

        let lifecycle = LocalMemoryAppLifecycle(
            store: FileAppLifecycleStateStore(fileURL: stateURL)
        )
        let snapshot = try await lifecycle.launch(initialStatus: .recording)
        #expect(snapshot.status == .permissionRequired)
        #expect(snapshot.mainWindowVisible == false)
        #expect(snapshot.recoveryReason == .invalidPersistedState)
    }

    @Test("Normal launch is explicitly menu-bar only")
    func defaultLaunchHasNoMainWindow() {
        #expect(AppLifecycleDefaults.opensMainWindowAtLaunch == false)
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "runtime-state.json")
    }
}
