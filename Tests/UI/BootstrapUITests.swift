import XCTest

@MainActor
final class BootstrapUITests: XCTestCase {
    func testBootstrapWindowAppears() {
        let application = XCUIApplication()
        application.launchArguments = [
            "--lm009-open-main",
            "--lm009-state-file",
            temporaryStateURL().path,
        ]
        application.launch()
        XCTAssertTrue(application.staticTexts["Local Memory"].waitForExistence(timeout: 5))
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "runtime-state.json")
    }
}
