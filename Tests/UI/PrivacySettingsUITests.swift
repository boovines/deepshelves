import XCTest

@MainActor
final class PrivacySettingsUITests: XCTestCase {
    func testApplicationExclusionAppliesImmediatelyPreviewsAndPersistsAcrossRelaunch() {
        let policyStateURL = temporaryStateURL(fileName: "privacy-policy.json")
        var application = launchPrivacySettings(policyStateURL: policyStateURL)
        let pane = application.descendants(matching: .any)["privacy.settingsPane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts["Foreground window only"].exists)
        XCTAssertTrue(application.staticTexts["Excluded by default"].exists)

        let applicationField = application.textFields["privacy.applicationField"]
        XCTAssertTrue(applicationField.waitForExistence(timeout: 2))
        applicationField.click()
        applicationField.typeText("com.example.private-notes")
        application.buttons["privacy.addApplication"].click()

        XCTAssertTrue(
            application.staticTexts["Block com.example.private-notes"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            application.staticTexts["Privacy rules applied immediately."]
                .waitForExistence(timeout: 3)
        )

        let scrollView = application.scrollViews.firstMatch
        for _ in 0..<3 { scrollView.swipeUp() }
        let testContext = application.buttons["privacy.testContext"]
        XCTAssertTrue(testContext.waitForExistence(timeout: 3))
        testContext.click()
        XCTAssertTrue(
            application.descendants(matching: .any)["privacy.previewResult"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(application.staticTexts["Capture blocked"].exists)
        XCTAssertTrue(application.staticTexts["Block com.example.private-notes"].exists)

        application.terminate()
        application = launchPrivacySettings(policyStateURL: policyStateURL)
        XCTAssertTrue(
            application.staticTexts["Block com.example.private-notes"]
                .waitForExistence(timeout: 5)
        )
    }

    func testRulePrecedenceControlsAndTypedTimelineGapsAreAccessible() {
        let policyStateURL = temporaryStateURL(fileName: "privacy-policy.json")
        var application = launchPrivacySettings(policyStateURL: policyStateURL)
        let applicationField = application.textFields["privacy.applicationField"]
        XCTAssertTrue(applicationField.waitForExistence(timeout: 5))
        for bundleIdentifier in ["com.example.one", "com.example.two"] {
            applicationField.click()
            applicationField.typeText(bundleIdentifier)
            application.buttons["privacy.addApplication"].click()
            XCTAssertTrue(
                application.staticTexts["Block \(bundleIdentifier)"]
                    .waitForExistence(timeout: 3)
            )
        }
        XCTAssertTrue(application.staticTexts["#1"].exists)
        XCTAssertTrue(application.staticTexts["#2"].exists)
        let moveEarlier = application.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Move Block com.example.two earlier'")
        ).firstMatch
        XCTAssertTrue(moveEarlier.waitForExistence(timeout: 2))
        moveEarlier.click()
        XCTAssertTrue(
            application.staticTexts["Privacy rules applied immediately."]
                .waitForExistence(timeout: 3)
        )
        application.terminate()

        application = launchTimeline()
        let timelineSection = application.descendants(matching: .any)["sidebar.timeline"]
        XCTAssertTrue(timelineSection.waitForExistence(timeout: 5))
        timelineSection.click()
        for reason in ["excluded", "permissionLost", "filterFailed", "protectedSurface"] {
            XCTAssertTrue(
                application.descendants(matching: .any)["timeline.gap.\(reason)"]
                    .waitForExistence(timeout: 2),
                reason
            )
        }
        let excluded = application.descendants(matching: .any)["timeline.gap.excluded"]
        XCTAssertTrue(excluded.label.contains("no application details stored"))
        XCTAssertFalse(excluded.label.contains("com.example"))
    }

    private func launchPrivacySettings(policyStateURL: URL) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm056-open-privacy-settings",
            "--lm056-policy-state-file",
            policyStateURL.path,
            "--lm009-state-file",
            temporaryStateURL(fileName: "runtime.json").path,
            "--lm010-navigation-state-file",
            temporaryStateURL(fileName: "navigation.json").path,
            "--lm015-search-panel-state-file",
            temporaryStateURL(fileName: "search.json").path,
        ]
        application.launch()
        return application
    }

    private func launchTimeline() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm010-shell",
            "--lm009-state-file",
            temporaryStateURL(fileName: "runtime.json").path,
            "--lm010-navigation-state-file",
            temporaryStateURL(fileName: "navigation.json").path,
        ]
        application.launch()
        return application
    }

    private func temporaryStateURL(fileName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: fileName)
    }
}
