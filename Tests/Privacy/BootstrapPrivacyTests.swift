import MemoryContracts
import XCTest

final class BootstrapPrivacyTests: XCTestCase {
    func testBootstrapStatusContainsNoUserContent() throws {
        let value = BootstrapStatus(component: "local-memory", schemaVersion: 1, state: "bootstrap")
        let data = try JSONEncoder().encode(value)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("http"))
        XCTAssertFalse(text.contains("user"))
    }
}

