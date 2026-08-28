import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testReturnKeepsOnboardingDefaultActionOutsideTheMainShell() {
        let application = launchOnboarding(
            stateURL: temporaryStateURL(),
            screenRecording: "granted",
            accessibility: "granted"
        )

        XCTAssertTrue(element("onboarding.welcome", in: application).waitForExistence(timeout: 5))
        application.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("onboarding.permissions", in: application).waitForExistence(timeout: 3))
    }

    func testDeniedPathResumesWithoutRepeatingPermissionAction() {
        let stateURL = temporaryStateURL()
        var application = launchOnboarding(
            stateURL: stateURL,
            screenRecording: "denied",
            accessibility: "denied"
        )

        XCTAssertTrue(element("onboarding.welcome", in: application).waitForExistence(timeout: 5))
        application.buttons["onboarding.continue"].click()
        let screenPermission = application.descendants(matching: .any)[
            "onboarding.permission.screenRecording"
        ]
        XCTAssertTrue(screenPermission.waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts["Permission required"].exists)
        XCTAssertTrue(screenPermission.label.contains("Permission required"))
        XCTAssertEqual(permissionActionCount(in: stateURL), 0)

        application.buttons.matching(identifier: "Open System Settings").firstMatch.click()
        XCTAssertTrue(waitForPermissionActionCount(1, in: stateURL))
        application.terminate()

        application = launchOnboarding(
            stateURL: stateURL,
            screenRecording: "denied",
            accessibility: "denied"
        )
        XCTAssertTrue(element("onboarding.permissions", in: application).waitForExistence(timeout: 5))
        let restoredPermission = application.descendants(matching: .any)[
            "onboarding.permission.screenRecording"
        ]
        XCTAssertTrue(restoredPermission.waitForExistence(timeout: 3))
        XCTAssertTrue(restoredPermission.label.contains("Permission required"))
        XCTAssertEqual(
            permissionActionCount(in: stateURL),
            1,
            "Relaunch must not implicitly trigger or register another system permission action"
        )
    }

    func testGrantedPathShowsPrivacyPreviewAndCompletesOnboarding() {
        let application = launchOnboarding(
            stateURL: temporaryStateURL(),
            screenRecording: "granted",
            accessibility: "granted"
        )

        XCTAssertTrue(element("onboarding.welcome", in: application).waitForExistence(timeout: 5))
        application.buttons["onboarding.continue"].click()
        XCTAssertTrue(application.staticTexts["Granted"].waitForExistence(timeout: 3))
        XCTAssertEqual(application.staticTexts.matching(identifier: "Microphone").count, 0)

        application.buttons["onboarding.continue"].click()
        XCTAssertTrue(element("onboarding.privacy", in: application).waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts[
            "Local Memory records only your active window. Background windows, notifications, the Dock, and the desktop are not stored."
        ].exists)
        XCTAssertTrue(element("onboarding.preview", in: application).exists)
        XCTAssertTrue(element("onboarding.preview.active", in: application).exists)
        XCTAssertTrue(element("onboarding.preview.background", in: application).exists)
        XCTAssertTrue(element("onboarding.preview.saved", in: application).exists)

        application.buttons["onboarding.continue"].click()
        XCTAssertTrue(element("onboarding.ready", in: application).waitForExistence(timeout: 3))
        XCTAssertTrue(application.staticTexts["30 days"].exists)
        XCTAssertTrue(application.staticTexts["20 GB"].exists)
        application.buttons["onboarding.finish"].click()
        XCTAssertTrue(element("main.root", in: application).waitForExistence(timeout: 5))
        XCTAssertFalse(element("onboarding.root", in: application).exists)
    }

    func testRevokedPathIsExplicitAndStillNavigable() {
        let application = launchOnboarding(
            stateURL: temporaryStateURL(),
            screenRecording: "revoked",
            accessibility: "revoked"
        )

        XCTAssertTrue(element("onboarding.welcome", in: application).waitForExistence(timeout: 5))
        application.buttons["onboarding.continue"].click()
        XCTAssertTrue(application.staticTexts["Permission revoked"].waitForExistence(timeout: 3))
        XCTAssertTrue(application.buttons.matching(identifier: "Open System Settings").firstMatch.exists)
        application.buttons["onboarding.continue"].click()
        XCTAssertTrue(element("onboarding.privacy", in: application).waitForExistence(timeout: 3))
        application.buttons["onboarding.back"].click()
        XCTAssertTrue(element("onboarding.permissions", in: application).waitForExistence(timeout: 3))
    }

    private func launchOnboarding(
        stateURL: URL,
        screenRecording: String,
        accessibility: String
    ) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm014-onboarding",
            "--lm014-onboarding-state-file",
            stateURL.path,
            "--lm014-screen-permission",
            screenRecording,
            "--lm014-accessibility-permission",
            accessibility,
            "--lm014-suppress-system-settings",
            "--lm009-state-file",
            temporaryStateURL().path,
        ]
        application.launch()
        return application
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "onboarding-state.json")
    }

    private func element(_ identifier: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any)[identifier]
    }

    private func waitForPermissionActionCount(_ expected: Int, in stateURL: URL) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if permissionActionCount(in: stateURL) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }

    private func permissionActionCount(in stateURL: URL) -> Int? {
        guard let data = try? Data(contentsOf: stateURL),
              let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data)
        else { return nil }
        return snapshot.explicitPermissionActions[.screenRecording, default: 0]
    }
}

private struct PersistedSnapshot: Decodable {
    let explicitPermissionActions: [PersistedPermissionKind: Int]
}

private enum PersistedPermissionKind: String, Decodable, Hashable {
    case screenRecording
    case accessibility
    case microphone
}
