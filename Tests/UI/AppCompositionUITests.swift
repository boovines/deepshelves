import XCTest

@MainActor
final class AppCompositionUITests: XCTestCase {
    func testDefaultLaunchKeepsMainWindowClosed() {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm009-state-file",
            temporaryStateURL().path,
            "--lm009-runtime",
            "recording",
        ]
        application.launch()

        let running = application.wait(for: .runningBackground, timeout: 5)
            || application.state == .runningForeground
        XCTAssertTrue(running)
        XCTAssertEqual(application.windows.count, 0)
    }

    func testMenuPreviewTracksEveryFakeRuntimeState() {
        let expectations = [
            ("recording", "Recording", "Pause Recording"),
            ("paused", "Paused", "Resume Recording"),
            ("permission-required", "Recording unavailable", "Review Permissions…"),
            ("disk-full", "Recording unavailable", "Manage Storage…"),
            ("indexing", "Indexing", "Pause Recording"),
        ]

        for (runtime, status, action) in expectations {
            let application = launchPreview(runtime: runtime, stateURL: temporaryStateURL())
            let statusElement = application.staticTexts["menu.status"]
            XCTAssertTrue(statusElement.waitForExistence(timeout: 5), runtime)
            XCTAssertTrue(
                application.staticTexts[status].waitForExistence(timeout: 2),
                runtime
            )
            XCTAssertTrue(application.buttons[action].exists, runtime)
            XCTAssertTrue(application.staticTexts["Foreground window only"].exists, runtime)
            application.terminate()
        }
    }

    func testPausedStatePersistsAcrossRelaunch() {
        let stateURL = temporaryStateURL()
        var application = launchPreview(runtime: "recording", stateURL: stateURL)
        let primaryAction = application.buttons["menu.primaryAction"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        XCTAssertEqual(primaryAction.label, "Pause Recording")
        primaryAction.click()
        XCTAssertTrue(application.staticTexts["Paused"].waitForExistence(timeout: 5))
        application.terminate()

        application = XCUIApplication()
        application.launchArguments = [
            "--lm009-menu-preview",
            "--lm009-state-file",
            stateURL.path,
        ]
        application.launch()
        let restoredStatus = application.staticTexts["menu.status"]
        XCTAssertTrue(restoredStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts["Paused"].waitForExistence(timeout: 5))
        XCTAssertEqual(application.buttons["menu.primaryAction"].label, "Resume Recording")
    }

    private func launchPreview(runtime: String, stateURL: URL) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm009-menu-preview",
            "--lm009-state-file",
            stateURL.path,
            "--lm009-runtime",
            runtime,
        ]
        application.launch()
        return application
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "runtime-state.json")
    }
}
