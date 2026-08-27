import MemoryDesignSystem
import MemoryStore
import XCTest

final class BaselineDefaultsTests: XCTestCase {
    func testS5DefaultsAreFrozen() {
        XCTAssertEqual(LM008StoreDefaults.keyByteCount, 32)
        XCTAssertEqual(LM008StoreDefaults.journalMode, "WAL")
        XCTAssertEqual(LM008StoreDefaults.pageSize, 4_096)
        XCTAssertEqual(LM008StoreDefaults.busyTimeoutMilliseconds, 5_000)
        XCTAssertEqual(LM008StoreDefaults.maximumEncryptionOverheadFraction, 0.20)
        XCTAssertEqual(LM008StoreDefaults.crashPointCount, 10_000)
    }

    func testS6DefaultsAreFrozen() {
        XCTAssertEqual(LM008UIDefaults.panelWidth, 760)
        XCTAssertEqual(LM008UIDefaults.panelHeight, 620)
        XCTAssertEqual(LM008UIDefaults.initialCardCount, 60)
        XCTAssertEqual(LM008UIDefaults.fixtureCardCount, 10_000)
        XCTAssertEqual(LM008UIDefaults.timelineHours, 24)
        XCTAssertEqual(LM008UIDefaults.minimumFastScrollFramesPerSecond, 55)
        XCTAssertEqual(LM008UIDefaults.decodeCacheEntryLimit, 96)
    }

    func testS7DefaultsForbidRuntimeNetwork() {
        XCTAssertFalse(LM008StoreDefaults.runtimeNetworkingAllowed)
        XCTAssertFalse(LM008UIDefaults.remoteResourcesAllowed)
    }
}
