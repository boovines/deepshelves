import XCTest

@MainActor
final class SearchStateBindingUITests: XCTestCase {
    func testWarmFixtureSharesQueryAndSettledOrderingBetweenMainAndPanel() {
        let application = launch(fixture: "warm")
        application.descendants(matching: .any)["sidebar.search"].click()
        let mainQuery = application.textFields["main.searchField"]
        XCTAssertTrue(mainQuery.waitForExistence(timeout: 3))
        mainQuery.typeText("Safari")
        let resultID = "search.result.00000000-0000-4000-8000-000000000102"
        XCTAssertTrue(
            application.descendants(matching: .any)[
                "moment.afternoon-research"
            ].waitForExistence(timeout: 3)
        )

        application.typeKey(.space, modifierFlags: [.option])

        let panelQuery = application.textFields["search.query"]
        XCTAssertTrue(panelQuery.waitForExistence(timeout: 3))
        XCTAssertEqual(panelQuery.value as? String, "Safari")
        XCTAssertTrue(application.buttons[resultID].waitForExistence(timeout: 3))
    }

    func testSlowFixtureClearsWarmResultsAndNeverShowsStaleResultsWhileLoading() {
        let application = launch(fixture: "slow")
        application.descendants(matching: .any)["sidebar.search"].click()
        let query = application.textFields["main.searchField"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertTrue(
            application.descendants(matching: .any)[
                "moment.morning-planning"
            ].waitForExistence(timeout: 3)
        )

        query.typeText("Safari")

        XCTAssertTrue(
            application.descendants(matching: .any)["search.loading"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            application.descendants(matching: .any)["moment.morning-planning"].exists
        )
        XCTAssertTrue(
            application.descendants(matching: .any)[
                "moment.afternoon-research"
            ].waitForExistence(timeout: 3)
        )
    }

    func testErrorFixtureSettlesToContentFreeDiagnostic() {
        let application = launch(fixture: "error")
        application.descendants(matching: .any)["sidebar.search"].click()
        let query = application.textFields["main.searchField"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))

        query.typeText("failure fixture")

        let error = application.descendants(matching: .any)["search.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(
            application.staticTexts["search.errorCode"].label,
            "Diagnostic code: LM-SEARCH-QUERY"
        )
        XCTAssertFalse(application.staticTexts["failure fixture"].exists)
    }

    private func launch(fixture: String) -> XCUIApplication {
        let application = XCUIApplication()
        let stateRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        application.launchArguments = [
            "--lm010-shell",
            "--lm039-search-fixture",
            fixture,
            "--lm009-state-file",
            stateRoot.appending(path: "runtime.json").path,
            "--lm010-navigation-state-file",
            stateRoot.appending(path: "navigation.json").path,
            "--lm015-search-panel-state-file",
            stateRoot.appending(path: "search-panel.json").path,
        ]
        application.launch()
        XCTAssertTrue(
            application.descendants(matching: .any)["main.root"].waitForExistence(timeout: 5)
        )
        return application
    }
}
