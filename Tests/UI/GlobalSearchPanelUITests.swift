import XCTest

@MainActor
final class GlobalSearchPanelUITests: XCTestCase {
    func testDefaultOptionSpaceShortcutPresentsPanel() {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm010-shell",
            "--lm009-state-file",
            temporaryStateURL(fileName: "runtime.json").path,
            "--lm010-navigation-state-file",
            temporaryStateURL(fileName: "navigation.json").path,
            "--lm015-search-panel-state-file",
            temporaryStateURL(fileName: "search-panel.json").path,
        ]
        application.launch()
        XCTAssertTrue(application.descendants(matching: .any)["main.root"].waitForExistence(timeout: 5))

        application.typeKey(.space, modifierFlags: [.option])
        XCTAssertTrue(
            application.descendants(matching: .any)["search.content"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(application.textFields["search.query"].exists)
    }

    func testPanelUsesFrozenGeometryFocusEscapeAndAppearanceBudgets() throws {
        let application = launchSearchPanel(measuresWarmPresentation: true)
        let panel = application.descendants(matching: .any)["search.content"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(panel.frame.width, 760, accuracy: 2)
        XCTAssertEqual(panel.frame.height, 620, accuracy: 2)

        let query = application.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.typeText("Safari")
        XCTAssertEqual(query.value as? String, "Safari")
        XCTAssertTrue(application.buttons[
            "search.result.00000000-0000-4000-8000-000000000102"
        ].waitForExistence(timeout: 2))

        let timing = application.staticTexts["search.presentationTiming"]
        XCTAssertTrue(timing.waitForExistence(timeout: 2))
        let timingText = [timing.label, timing.value as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        let values = try parseTiming(timingText)
        print("LM015_S6_TIMING cold_ms=\(values.cold) warm_ms=\(values.warm)")
        XCTAssertLessThan(values.cold, 400)
        XCTAssertLessThan(values.warm, 150)

        query.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(panel, timeout: 2))
    }

    func testPanelSelectionPersistsIntoSharedMainNavigationState() {
        let navigationStateURL = temporaryStateURL(fileName: "navigation.json")
        var application = launchSearchPanel(
            navigationStateURL: navigationStateURL,
            measuresWarmPresentation: false
        )
        let resultID = "search.result.00000000-0000-4000-8000-000000000102"
        let result = application.buttons[resultID]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.click()
        sleep(1)
        application.terminate()

        application = XCUIApplication()
        application.launchArguments = [
            "--lm010-shell",
            "--lm009-state-file",
            temporaryStateURL(fileName: "runtime.json").path,
            "--lm010-navigation-state-file",
            navigationStateURL.path,
        ]
        application.launch()
        XCTAssertTrue(application.staticTexts["Afternoon research"].waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts["inspector.title"].waitForExistence(timeout: 3))
    }

    func testShortcutCollisionOffersOneRecoverableSettingsAction() {
        let application = XCUIApplication()
        let panelStateURL = temporaryStateURL(fileName: "search-panel.json")
        application.launchArguments = [
            "--lm015-shortcut-collision",
            "--lm009-state-file",
            temporaryStateURL(fileName: "runtime.json").path,
            "--lm010-navigation-state-file",
            temporaryStateURL(fileName: "navigation.json").path,
            "--lm015-search-panel-state-file",
            panelStateURL.path,
        ]
        application.launch()

        XCTAssertTrue(application.staticTexts["Shortcut unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(application.staticTexts["LM-SHORTCUT-409"].exists)
        let recovery = application.buttons["settings.shortcutRecovery"]
        XCTAssertTrue(recovery.exists)
        recovery.click()
        XCTAssertTrue(application.staticTexts["Active"].waitForExistence(timeout: 3))
        XCTAssertFalse(application.buttons["settings.shortcutRecovery"].exists)
        XCTAssertTrue(waitForPersistedShortcutKey("k", at: panelStateURL))
    }

    private func launchSearchPanel(
        navigationStateURL: URL? = nil,
        measuresWarmPresentation: Bool
    ) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm015-search-panel",
            "--lm009-state-file",
            temporaryStateURL(fileName: "runtime.json").path,
            "--lm010-navigation-state-file",
            (navigationStateURL ?? temporaryStateURL(fileName: "navigation.json")).path,
            "--lm015-search-panel-state-file",
            temporaryStateURL(fileName: "search-panel.json").path,
        ]
        if measuresWarmPresentation {
            application.launchArguments.append("--lm015-measure-warm")
        }
        application.launch()
        return application
    }

    private func temporaryStateURL(fileName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    private func parseTiming(_ label: String) throws -> (cold: Int, warm: Int) {
        let pattern = #"[0-9]+"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(label.startIndex..., in: label)
        let matches = expression.matches(in: label, range: range)
        let coldMatch = try XCTUnwrap(matches.first, "Unexpected timing label: \(label)")
        let warmMatch = try XCTUnwrap(matches.dropFirst().first, "Unexpected timing label: \(label)")
        let coldRange = try XCTUnwrap(Range(coldMatch.range, in: label))
        let warmRange = try XCTUnwrap(Range(warmMatch.range, in: label))
        return (
            try XCTUnwrap(Int(label[coldRange])),
            try XCTUnwrap(Int(label[warmRange]))
        )
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForPersistedShortcutKey(_ key: String, at url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let shortcut = object["shortcut"] as? [String: Any],
               shortcut["key"] as? String == key
            {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }
}
