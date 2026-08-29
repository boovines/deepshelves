import CryptoKit
import Foundation
import MemoryContracts
import XCTest

@testable import MemoryAgentAccess

final class ImageResourceAuthorityTests: XCTestCase {
    func testCapabilityRequiresExactly256Bits() throws {
        let now = Date(timeIntervalSince1970: 1_777_700_000)
        let authority = ImageResourceAuthority(
            key: Data(repeating: 0xA1, count: 16),
            now: { now }
        )

        XCTAssertThrowsError(
            try authority.issue(
                frameID: UUID(),
                policy: imagePolicy(now: now, allowsImages: true)
            )
        ) { XCTAssertEqual($0 as? ImageResourceError, .invalidCapability) }
        XCTAssertThrowsError(try authority.validate(resourceID: "opaque")) {
            XCTAssertEqual($0 as? ImageResourceError, .invalidCapability)
        }
    }

    func testOpaqueResourceExpiresAndIsBoundToPolicyAndFrame() throws {
        let clock = ImageClock(now: Date(timeIntervalSince1970: 1_777_700_000))
        let authority = ImageResourceAuthority(
            key: Data(repeating: 0xA9, count: 32),
            now: { clock.value }
        )
        let policy = try imagePolicy(now: clock.value, allowsImages: true)
        let frameID = UUID(uuidString: "69000000-0000-4000-8000-000000000001")!

        let resource = try authority.issue(frameID: frameID, policy: policy)
        XCTAssertFalse(resource.resourceID.contains(frameID.uuidString.lowercased()))
        XCTAssertFalse(resource.resourceID.contains(policy.id.uuidString.lowercased()))
        let claim = try authority.validate(resourceID: resource.resourceID)
        XCTAssertEqual(claim.frameID, frameID)
        XCTAssertEqual(claim.policyID, policy.id)

        var tampered = resource.resourceID
        tampered.replaceSubrange(
            tampered.startIndex...tampered.startIndex,
            with: tampered.first == "A" ? "B" : "A"
        )
        XCTAssertThrowsError(try authority.validate(resourceID: tampered))

        clock.value = resource.expiresAt
        XCTAssertThrowsError(try authority.validate(resourceID: resource.resourceID)) {
            XCTAssertEqual($0 as? ImageResourceError, .expired)
        }
    }

    func testImageOptInAndBoundsFailBeforeBytesLoad() async throws {
        let now = Date(timeIntervalSince1970: 1_777_700_000)
        let authority = ImageResourceAuthority(
            key: Data(repeating: 0xB7, count: 32),
            now: { now }
        )
        XCTAssertThrowsError(
            try authority.issue(
                frameID: UUID(),
                policy: imagePolicy(now: now, allowsImages: false)
            )
        ) { XCTAssertEqual($0 as? ImageResourceError, .policyDenied) }

        let claim = ImageResourceClaim(
            frameID: UUID(),
            policyID: UUID(),
            expiresAt: now.addingTimeInterval(60)
        )
        let loadCounter = ImageLoadCounter()
        await assertThrowsErrorAsync(
            try await BoundedImageResourceReader.read(
                claim: claim,
                metadata: ImageResourceMetadata(
                    frameID: claim.frameID,
                    width: 1_921,
                    height: 1_080,
                    byteCount: 4,
                    sha256: Data(SHA256.hash(data: Data([1, 2, 3, 4])))
                ),
                load: {
                    await loadCounter.markLoaded()
                    return Data([1, 2, 3, 4])
                }
            )
        )
        let loaded = await loadCounter.wasLoaded()
        XCTAssertFalse(loaded)
    }

    func testDeletedResourceCancellationAndHashMismatchFailClosed() async throws {
        let now = Date(timeIntervalSince1970: 1_777_700_000)
        let claim = ImageResourceClaim(
            frameID: UUID(),
            policyID: UUID(),
            expiresAt: now.addingTimeInterval(60)
        )
        let metadata = ImageResourceMetadata(
            frameID: claim.frameID,
            width: 1,
            height: 1,
            byteCount: 4,
            sha256: Data(repeating: 0, count: 32)
        )
        await assertThrowsErrorAsync(
            try await BoundedImageResourceReader.read(
                claim: claim,
                metadata: metadata,
                load: { Data([1, 2, 3, 4]) }
            )
        )

        let cancelled = Task {
            try await BoundedImageResourceReader.read(
                claim: claim,
                metadata: metadata,
                load: { Data([1, 2, 3, 4]) }
            )
        }
        cancelled.cancel()
        await assertThrowsErrorAsync(try await cancelled.value)
    }
}

private final class ImageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(now: Date) { stored = now }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor ImageLoadCounter {
    private var loaded = false
    func markLoaded() { loaded = true }
    func wasLoaded() -> Bool { loaded }
}

private func imagePolicy(now: Date, allowsImages: Bool) throws -> AccessPolicy {
    try AccessPolicy(
        id: UUID(uuidString: "69000000-0000-4000-8000-000000000002")!,
        name: "Image fixture",
        allowedInterval: DateInterval(
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1)
        ),
        allowedBundleIDs: ["com.example.allowed"],
        allowedHosts: [],
        allowImageResources: allowsImages,
        maxResults: 10,
        expiresAt: now.addingTimeInterval(3_600),
        createdByUser: true
    )
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
