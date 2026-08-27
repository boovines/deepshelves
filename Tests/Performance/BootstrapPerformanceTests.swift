import MemoryContracts
import XCTest

final class BootstrapPerformanceTests: XCTestCase {
    func testStatusEncodingPerformance() throws {
        let value = BootstrapStatus(component: "local-memory", schemaVersion: 1, state: "bootstrap")
        measure {
            _ = try? JSONEncoder().encode(value)
        }
    }
}

