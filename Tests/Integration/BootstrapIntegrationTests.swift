import MemoryContracts
import XCTest

final class BootstrapIntegrationTests: XCTestCase {
    func testContractVersionIsV1() {
        XCTAssertEqual(BootstrapContract.schemaVersion, 1)
    }
}

