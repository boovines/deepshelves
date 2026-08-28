import XCTest

@MainActor
final class ShellAccessibilityUITests: XCTestCase {
    func testPlanElevenSectionFocusSettingsAndHistoryShortcuts() {
        let application = launchShell()
        XCTAssertTrue(application.descendants(matching: .any)["sidebar.search"].waitForExistence(timeout: 5))
        application.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(application.descendants(matching: .any)["Timeline accessibility list"].waitForExistence(timeout: 2))
        application.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(application.descendants(matching: .any)["Today, 2 PM, 42 recorded minutes, 18 gap minutes"].waitForExistence(timeout: 2))
        application.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(application.descendants(matching: .any)["Timeline accessibility list"].waitForExistence(timeout: 2))
        application.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(application.descendants(matching: .any)["Today, 2 PM, 42 recorded minutes, 18 gap minutes"].waitForExistence(timeout: 2))

        application.typeKey("1", modifierFlags: .command)
        let query = application.descendants(matching: .any)["Search your local memory"]
        XCTAssertTrue(query.waitForExistence(timeout: 2))
        application.typeKey("f", modifierFlags: .command)
        application.typeText("lamp shade")
        XCTAssertEqual(query.value as? String, "lamp shade")

        application.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(application.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 5))
    }

    func testMomentKeyboardActionsUseTransientSafetyAndRestoreFocus() {
        let application = launchShell()
        let first = application.buttons["moment.morning-planning"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.click()

        let inspectorToggle = application.buttons["main.toggleInspector"]
        XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 2))
        inspectorToggle.click()
        XCTAssertFalse(application.descendants(matching: .any)["main.inspector"].waitForExistence(timeout: 1))
        application.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(application.descendants(matching: .any)["inspector.title"].waitForExistence(timeout: 2))

        application.typeKey(.space, modifierFlags: [])
        let quickLook = application.staticTexts["Synthetic local Quick Look preview"]
        XCTAssertTrue(quickLook.waitForExistence(timeout: 2))
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(quickLook.waitForExistence(timeout: 1))

        application.typeKey(.rightArrow, modifierFlags: .option)
        let inspectorTitle = application.descendants(matching: .any)["inspector.title"]
        XCTAssertTrue(inspectorTitle.waitForExistence(timeout: 2))
        XCTAssertTrue(accessibleText(inspectorTitle).contains("Afternoon research"))
        application.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(application.staticTexts["Revisit is unavailable for this synthetic fixture."].waitForExistence(timeout: 2))

        application.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(application.descendants(matching: .any)["moment.forgetConfirmation"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.buttons["Cancel"].exists)
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(application.descendants(matching: .any)["moment.forgetConfirmation"].waitForExistence(timeout: 1))
        application.typeKey(.leftArrow, modifierFlags: .option)
        XCTAssertTrue(accessibleText(inspectorTitle).contains("Morning planning"))
    }

    func testStandardEmptyLoadingAndErrorStates() {
        var application = launchShell(contentState: "empty")
        XCTAssertTrue(application.staticTexts["Your screen memory will appear here after recording begins."].waitForExistence(timeout: 5))
        XCTAssertTrue(application.buttons["Check Capture Status"].exists)
        application.terminate()

        application = launchShell(contentState: "loading")
        XCTAssertTrue(application.descendants(matching: .any)["Loading local memory…"].waitForExistence(timeout: 5))
        application.terminate()

        application = launchShell(contentState: "error")
        XCTAssertTrue(application.staticTexts["Diagnostic code: LM-SHELL-500"].waitForExistence(timeout: 5))
        XCTAssertTrue(application.buttons["Try Again"].exists)
    }

    func testEnglishAndPseudoLocalizedVoiceOverProjections() {
        var application = launchShell()
        let first = application.buttons["moment.morning-planning"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.label.contains("Calendar"))
        XCTAssertTrue(first.label.contains("example.test"))
        XCTAssertTrue(first.label.contains("1 of 3"))
        application.descendants(matching: .any)["sidebar.timeline"].click()
        XCTAssertTrue(application.descendants(matching: .any)["Timeline accessibility list"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.staticTexts["Permission lost gap, 11:30 AM to 11:45 AM"].exists)
        application.descendants(matching: .any)["sidebar.activity"].click()
        XCTAssertTrue(application.descendants(matching: .any)["Today, 2 PM, 42 recorded minutes, 18 gap minutes"].waitForExistence(timeout: 2))
        application.terminate()

        application = launchShell(contentState: "empty", pseudoLocalized: true)
        XCTAssertTrue(application.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Check Capture Status'")
        ).firstMatch.waitForExistence(timeout: 5))
        for identifier in ["sidebar.search", "sidebar.timeline", "sidebar.activity", "sidebar.settings"] {
            XCTAssertTrue(application.descendants(matching: .any)[identifier].exists)
        }
    }

    func testCommandMenusExposeTheCompleteKeyboardVocabulary() {
        let application = launchShell()
        XCTAssertTrue(application.descendants(matching: .any)["sidebar.search"].waitForExistence(timeout: 5))

        application.menuBars.menuBarItems["Navigate"].click()
        for item in ["Search", "Timeline", "Activity", "Back", "Forward", "Global Search Panel — Option-Space"] {
            XCTAssertTrue(application.menuItems[item].exists)
        }
        application.typeKey(.escape, modifierFlags: [])

        application.menuBars.menuBarItems["Moment"].click()
        for item in [
            "Quick Look",
            "Open Detail",
            "Revisit Source",
            "Previous Application Transition",
            "Next Application Transition",
            "Forget Selected Moment…",
            "Close Transient UI",
        ] {
            XCTAssertTrue(application.menuItems[item].exists)
        }
    }

    private func launchShell(
        contentState: String = "ready",
        pseudoLocalized: Bool = false
    ) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm010-shell",
            "--lm009-state-file",
            temporaryStateURL(fileName: "runtime.json").path,
            "--lm010-navigation-state-file",
            temporaryStateURL(fileName: "navigation.json").path,
            "--lm015-search-panel-state-file",
            temporaryStateURL(fileName: "search.json").path,
            "--lm016-content-state",
            contentState,
        ]
        if pseudoLocalized {
            application.launchArguments.append("--lm016-pseudo-localization")
        }
        application.launch()
        return application
    }

    private func temporaryStateURL(fileName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    private func accessibleText(_ element: XCUIElement) -> String {
        [element.label, element.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
    }

}
