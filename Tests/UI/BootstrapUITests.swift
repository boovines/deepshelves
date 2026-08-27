import XCTest

final class BootstrapUITests: XCTestCase {
    func testBootstrapWindowAppears() {
        let application = XCUIApplication()
        application.launch()
        XCTAssertTrue(application.staticTexts["Local Memory"].waitForExistence(timeout: 5))
    }
}

