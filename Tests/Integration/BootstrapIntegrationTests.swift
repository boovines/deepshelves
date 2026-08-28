import MemoryContracts
import XCTest

final class BootstrapIntegrationTests: XCTestCase {
    func testContractVersionIsV2WithV1ReadCompatibility() {
        XCTAssertEqual(BootstrapContract.schemaVersion, 2)
        XCTAssertEqual(BootstrapContract.minimumReadableSchemaVersion, 1)
    }
}
