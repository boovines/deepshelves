import XCTest

@MainActor
final class MainShellUITests: XCTestCase {
    func testRestoresSectionAndSelectionAcrossRelaunch() {
        let stateURL = temporaryStateURL()
        var application = launchShell(stateURL: stateURL, size: "default")

        let timelineSection = application.descendants(matching: .any)["sidebar.timeline"]
        XCTAssertTrue(timelineSection.waitForExistence(timeout: 5))
        timelineSection.click()
        XCTAssertTrue(application.staticTexts["Timeline"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.buttons["moment.afternoon-research"].waitForExistence(timeout: 2))
        application.buttons["moment.afternoon-research"].click()
        XCTAssertTrue(
            application.staticTexts["inspector.title"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(application.staticTexts["Afternoon research"].exists)
        sleep(1)
        application.terminate()

        application = launchShell(stateURL: stateURL, size: "default")
        XCTAssertTrue(application.staticTexts["Timeline"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            application.staticTexts["inspector.title"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(application.staticTexts["Afternoon research"].exists)
    }

    func testMinimumWindowHidesInspectorAndKeepsNavigationUsable() {
        let application = launchShell(stateURL: temporaryStateURL(), size: "minimum")
        let window = application.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(window.frame.width, 840)
        XCTAssertLessThan(window.frame.width, 900)
        XCTAssertGreaterThanOrEqual(window.frame.height, 560)

        XCTAssertTrue(application.descendants(matching: .any)["sidebar.search"].exists)
        XCTAssertFalse(application.otherElements["main.inspector"].exists)
        application.descendants(matching: .any)["sidebar.timeline"].click()
        XCTAssertTrue(application.staticTexts["Timeline"].waitForExistence(timeout: 2))
        XCTAssertTrue(application.buttons["moment.afternoon-research"].exists)
    }

    func testSettingsSceneUsesNativeSpecifiedGeometry() throws {
        let application = launchShell(stateURL: temporaryStateURL(), size: "default")
        let settingsButton = application.buttons["main.openSettings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.click()

        XCTAssertTrue(application.staticTexts["Capture"].waitForExistence(timeout: 5))
        let windows = application.windows.allElementsBoundByIndex
        XCTAssertEqual(windows.count, 2)
        let settingsWindow = try XCTUnwrap(windows.min { $0.frame.width < $1.frame.width })
        XCTAssertGreaterThanOrEqual(settingsWindow.frame.width, 680)
        XCTAssertLessThan(settingsWindow.frame.width, 720)
        XCTAssertGreaterThanOrEqual(settingsWindow.frame.height, 560)
    }

    private func launchShell(stateURL: URL, size: String) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm010-shell",
            "--lm009-state-file",
            temporaryStateURL().path,
            "--lm010-navigation-state-file",
            stateURL.path,
            "--lm010-window-size",
            size,
        ]
        application.launch()
        return application
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "state.json")
    }
}
