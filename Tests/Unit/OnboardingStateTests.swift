import Darwin
import Foundation
import MemoryDesignSystem
import XCTest

final class OnboardingStateTests: XCTestCase {
    func testFourStepVocabularyAndTruthfulDefaultsAreStable() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .permissions, .privacy, .ready])
        XCTAssertEqual(OnboardingSnapshot.default.step, .welcome)
        XCTAssertFalse(OnboardingSnapshot.default.isComplete)
        XCTAssertEqual(OnboardingDefaults.retentionDays, 30)
        XCTAssertEqual(OnboardingDefaults.storageCapGigabytes, 20)
        XCTAssertEqual(
            OnboardingDefaults.foregroundOnlyStatement,
            "Local Memory records only your active window. Background windows, notifications, the Dock, and the desktop are not stored."
        )
        XCTAssertFalse(OnboardingDefaults.visiblePermissionKinds.contains(.microphone))
    }

    func testOnboardingStateRoundTripsOwnerOnlyAndResumesExactStep() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = root.appending(path: "onboarding-state.json")
        let store = FileOnboardingStateStore(fileURL: file)
        let expected = OnboardingSnapshot(
            step: .privacy,
            screenRecording: .denied,
            accessibility: .granted,
            explicitPermissionActions: [.screenRecording: 1],
            launchCount: 2,
            isComplete: false
        )

        try await store.save(expected)

        let restored = try await store.load()
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(try posixMode(at: root), 0o700)
        XCTAssertEqual(try posixMode(at: file), 0o600)
    }

    func testLaunchAndRelaunchNeverRegisterAnImplicitPermissionAction() async throws {
        let store = InMemoryOnboardingStateStore()
        let coordinator = OnboardingCoordinator(store: store)

        var snapshot = try await coordinator.launch(
            overrides: [.screenRecording: .denied, .accessibility: .denied]
        )
        XCTAssertEqual(snapshot.launchCount, 1)
        XCTAssertEqual(snapshot.explicitPermissionActions[.screenRecording, default: 0], 0)

        snapshot = try await coordinator.registerExplicitPermissionAction(.screenRecording)
        XCTAssertEqual(snapshot.explicitPermissionActions[.screenRecording], 1)

        snapshot = try await coordinator.launch(overrides: [.screenRecording: .denied])
        XCTAssertEqual(snapshot.launchCount, 2)
        XCTAssertEqual(snapshot.explicitPermissionActions[.screenRecording], 1)
    }

    func testGrantedDeniedAndRevokedTransitionsStayNavigable() async throws {
        let coordinator = OnboardingCoordinator(store: InMemoryOnboardingStateStore())
        var snapshot = try await coordinator.launch(overrides: [.screenRecording: .denied])
        XCTAssertEqual(snapshot.screenRecording, .denied)
        XCTAssertFalse(snapshot.canRecord)

        snapshot = try await coordinator.updatePermission(.screenRecording, status: .granted)
        XCTAssertTrue(snapshot.canRecord)

        snapshot = try await coordinator.updatePermission(.screenRecording, status: .revoked)
        XCTAssertEqual(snapshot.screenRecording, .revoked)
        XCTAssertFalse(snapshot.canRecord)
        XCTAssertEqual(snapshot.screenRecording.presentation.actionTitle, "Open System Settings")
    }

    func testStepNavigationAndCompletionAreResumable() async throws {
        let coordinator = OnboardingCoordinator(store: InMemoryOnboardingStateStore())
        _ = try await coordinator.launch(overrides: [:])
        var snapshot = try await coordinator.advance()
        XCTAssertEqual(snapshot.step, .permissions)
        snapshot = try await coordinator.advance()
        XCTAssertEqual(snapshot.step, .privacy)
        snapshot = try await coordinator.retreat()
        XCTAssertEqual(snapshot.step, .permissions)
        _ = try await coordinator.advance()
        snapshot = try await coordinator.advance()
        XCTAssertEqual(snapshot.step, .ready)
        let completed = try await coordinator.complete()
        XCTAssertTrue(completed.isComplete)
        XCTAssertEqual(completed.step, .ready)
    }

    func testVoiceOverTranscriptIsCanonicalAndContainsNoMicrophonePrompt() throws {
        let data = OnboardingAccessibilityTranscript.canonicalData
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let committed = try Data(
            contentsOf: root.appending(path: "Results/LM-014/voiceover.txt")
        )

        XCTAssertEqual(data, committed)
        XCTAssertTrue(text.contains("Step 2 of 4, Permissions"))
        XCTAssertTrue(text.contains("Screen Recording, Required"))
        XCTAssertTrue(text.contains("Accessibility, Recommended"))
        XCTAssertTrue(text.contains(OnboardingDefaults.foregroundOnlyStatement))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("microphone"))
    }

    private func posixMode(at url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & 0o777
    }
}
