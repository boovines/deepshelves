import MemoryContracts
import XCTest

final class BootstrapContractTests: XCTestCase {
    func testStatusRoundTripsThroughJSON() throws {
        let value = BootstrapStatus(component: "test", schemaVersion: 1, state: "ready")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(BootstrapStatus.self, from: encoded)
        XCTAssertEqual(decoded, value)
    }
}

