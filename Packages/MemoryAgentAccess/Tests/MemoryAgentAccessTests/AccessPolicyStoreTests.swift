import Foundation
import MemoryContracts
import SharedQueryKit
import XCTest

@testable import MemoryAgentAccess

final class AccessPolicyStoreTests: XCTestCase {
    func testUserPolicyPersistsWithOwnerOnlyPermissionsAndCapabilityNeverEntersFile()
        async throws
    {
        let fixture = try PolicyFixture()
        let key = Data(repeating: 0xA5, count: 32)
        let capabilityStore = MemoryCapabilityKeyStore(key: key)
        let repository = AccessPolicyStore(
            fileURL: fixture.fileURL,
            capabilityKeyStore: capabilityStore,
            now: { fixture.clock.now }
        )

        let policy = try await repository.create(fixture.draft())
        XCTAssertFalse(policy.allowImageResources)
        let persisted = try Data(contentsOf: fixture.fileURL)
        XCTAssertNil(persisted.range(of: key))
        XCTAssertFalse(
            String(decoding: persisted, as: UTF8.self).contains(key.base64EncodedString()))
        XCTAssertEqual(try posixMode(fixture.directory), 0o700)
        XCTAssertEqual(try posixMode(fixture.fileURL), 0o600)

        let reopened = AccessPolicyStore(
            fileURL: fixture.fileURL,
            capabilityKeyStore: capabilityStore,
            now: { fixture.clock.now }
        )
        let reopenedPolicy = try await reopened.policy(id: policy.id, capability: key)
        XCTAssertEqual(reopenedPolicy, policy)
        await assertThrowsErrorAsync(
            try await reopened.policy(id: policy.id, capability: Data(repeating: 0, count: 32))
        ) { error in
            XCTAssertEqual(error as? AgentAccessPolicyError, .invalidCapability)
        }
        try await reopened.revoke(id: policy.id, capability: key)

        await assertThrowsErrorAsync(
            try await reopened.policy(id: policy.id, capability: key)
        ) { error in
            XCTAssertEqual(error as? AgentAccessPolicyError, .revoked)
        }
    }

    func testDraftBoundsAndSignedPersistenceFailClosed() async throws {
        let fixture = try PolicyFixture()
        let key = Data(repeating: 0xC3, count: 32)
        let repository = AccessPolicyStore(
            fileURL: fixture.fileURL,
            capabilityKeyStore: MemoryCapabilityKeyStore(key: key),
            now: { fixture.clock.now }
        )
        let policy = try await repository.create(fixture.draft())

        XCTAssertThrowsError(
            try AccessPolicyDraft(
                id: UUID(),
                name: "Unbounded",
                allowedInterval: DateInterval(
                    start: fixture.clock.now.addingTimeInterval(-3_600),
                    end: fixture.clock.now
                ),
                allowedBundleIDs: ["app.allowed"],
                allowedHosts: [],
                allowImageResources: true,
                maxResults: 101,
                expiresAt: fixture.clock.now.addingTimeInterval(60),
                createdByUser: true
            )
        )
        XCTAssertThrowsError(
            try AccessPolicyDraft(
                id: UUID(),
                name: "Overlong history",
                allowedInterval: DateInterval(
                    start: fixture.clock.now.addingTimeInterval(-31 * 24 * 3_600),
                    end: fixture.clock.now
                ),
                allowedBundleIDs: ["app.allowed"],
                allowedHosts: [],
                allowImageResources: false,
                maxResults: 10,
                expiresAt: fixture.clock.now.addingTimeInterval(60),
                createdByUser: true
            )
        )
        XCTAssertThrowsError(
            try AccessPolicyDraft(
                id: UUID(),
                name: "Not user created",
                allowedInterval: DateInterval(
                    start: fixture.clock.now.addingTimeInterval(-3_600),
                    end: fixture.clock.now
                ),
                allowedBundleIDs: ["app.allowed"],
                allowedHosts: [],
                allowImageResources: false,
                maxResults: 10,
                expiresAt: fixture.clock.now.addingTimeInterval(60),
                createdByUser: false
            )
        )

        var tampered = try Data(contentsOf: fixture.fileURL)
        tampered[tampered.startIndex] ^= 0x01
        try tampered.write(to: fixture.fileURL, options: .atomic)
        let tamperedRepository = AccessPolicyStore(
            fileURL: fixture.fileURL,
            capabilityKeyStore: MemoryCapabilityKeyStore(key: key),
            now: { fixture.clock.now }
        )
        await assertThrowsErrorAsync(
            try await tamperedRepository.policy(id: policy.id, capability: key)
        ) { error in
            XCTAssertEqual(error as? AgentAccessPolicyError, .corruptStore)
        }
    }

    func testExpiryAndRevocationDuringQueryFailClosedBeforeReturningContent() async throws {
        let fixture = try PolicyFixture()
        let key = Data(repeating: 0x5A, count: 32)
        let repository = AccessPolicyStore(
            fileURL: fixture.fileURL,
            capabilityKeyStore: MemoryCapabilityKeyStore(key: key),
            now: { fixture.clock.now }
        )
        let revocable = try await repository.create(fixture.draft())
        let revokeGate = QueryRaceGate()
        let revokedQuery = Task {
            try await repository.withAuthorizedPolicy(
                id: revocable.id,
                capability: key
            ) { _ in
                await revokeGate.suspendOperation()
                return "must-not-return"
            }
        }
        await revokeGate.waitUntilSuspended()
        try await repository.revoke(id: revocable.id, capability: key)
        await revokeGate.resumeOperation()
        await assertThrowsErrorAsync(try await revokedQuery.value) { error in
            XCTAssertEqual(error as? AgentAccessPolicyError, .revoked)
        }

        let expiring = try await repository.create(
            fixture.draft(
                id: UUID(uuidString: "66000000-0000-0000-0000-000000000002")!,
                expiresAt: fixture.clock.now.addingTimeInterval(60)
            )
        )
        let expiryGate = QueryRaceGate()
        let expiredQuery = Task {
            try await repository.withAuthorizedPolicy(
                id: expiring.id,
                capability: key
            ) { _ in
                await expiryGate.suspendOperation()
                return "must-not-return"
            }
        }
        await expiryGate.waitUntilSuspended()
        fixture.clock.advance(by: 61)
        await expiryGate.resumeOperation()
        await assertThrowsErrorAsync(try await expiredQuery.value) { error in
            XCTAssertEqual(error as? AgentAccessPolicyError, .expired)
        }
    }

    func testProjectionPropertyAlwaysReturnsPolicySubsetAndEmptyAllowlistsReturnNone()
        throws
    {
        let fixture = try ProjectionFixture()
        for mask in 0..<16 {
            let allowedBundles = Set(
                fixture.bundleIDs.enumerated().compactMap { index, bundleID in
                    mask & (1 << index) == 0 ? nil : bundleID
                }
            )
            let allowedHosts = Set(
                fixture.hosts.enumerated().compactMap { index, host in
                    mask & (1 << index) == 0 ? nil : host
                }
            )
            let policy = try fixture.policy(
                allowedBundles: allowedBundles,
                allowedHosts: allowedHosts
            )
            let request = try fixture.request(policy: policy)
            let projected = try AccessPolicyProjectionFilter.searchPage(
                fixture.page,
                request: request
            )

            XCTAssertTrue(
                projected.results.allSatisfy {
                    allowedBundles.contains($0.foreground.bundleID)
                        && $0.browser.map { allowedHosts.contains($0.origin.host) } ?? true
                }
            )
        }

        let emptyPolicy = try fixture.policy(allowedBundles: [], allowedHosts: [])
        XCTAssertTrue(
            try AccessPolicyProjectionFilter.searchPage(
                fixture.page,
                request: fixture.request(policy: emptyPolicy)
            ).results.isEmpty
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private actor QueryRaceGate {
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationContinuation: CheckedContinuation<Void, Never>?

    func suspendOperation() async {
        suspended = true
        for waiter in suspensionWaiters {
            waiter.resume()
        }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { operationContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resumeOperation() {
        operationContinuation?.resume()
        operationContinuation = nil
    }
}

private struct PolicyFixture: Sendable {
    let directory: URL
    let fileURL: URL
    let clock = TestClock(Date(timeIntervalSince1970: 1_777_000_000))

    init(file: StaticString = #filePath) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "lm066-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        fileURL = directory.appending(path: "agent-policies.json")
        _ = file
    }

    func draft(
        id: UUID = UUID(uuidString: "66000000-0000-0000-0000-000000000001")!,
        expiresAt: Date? = nil
    ) throws -> AccessPolicyDraft {
        let interval = DateInterval(
            start: clock.now.addingTimeInterval(-3_600),
            end: clock.now
        )
        return try AccessPolicyDraft(
            id: id,
            name: "One-hour fixture access",
            allowedInterval: interval,
            allowedBundleIDs: ["com.apple.Safari"],
            allowedHosts: ["example.com"],
            allowImageResources: false,
            maxResults: 10,
            expiresAt: expiresAt ?? clock.now.addingTimeInterval(3_600),
            createdByUser: true
        )
    }
}

private struct ProjectionFixture {
    let now = Date(timeIntervalSince1970: 1_777_000_000)
    let bundleIDs = ["app.a", "app.b", "app.c", "app.d"]
    let hosts = ["a.test", "b.test", "c.test", "d.test"]
    let page: SearchPage

    init() throws {
        let bundleIDs = ["app.a", "app.b", "app.c", "app.d"]
        let hosts = ["a.test", "b.test", "c.test", "d.test"]
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        page = try SearchPage(
            results: try bundleIDs.indices.map { index in
                try makeResult(
                    index: index,
                    bundleID: bundleIDs[index],
                    host: hosts[index],
                    now: now
                )
            },
            nextCursor: nil
        )
    }

    func policy(
        allowedBundles: Set<String>,
        allowedHosts: Set<String>
    ) throws -> AccessPolicy {
        try AccessPolicy(
            id: UUID(),
            name: "Property policy",
            allowedInterval: DateInterval(
                start: now.addingTimeInterval(-3_600),
                end: now.addingTimeInterval(1)
            ),
            allowedBundleIDs: allowedBundles,
            allowedHosts: allowedHosts,
            maxResults: 20,
            expiresAt: now.addingTimeInterval(3_600),
            createdByUser: true
        )
    }

    func request(policy: AccessPolicy) throws -> SearchRequest {
        try SearchRequest(
            query: "fixture",
            interval: policy.allowedInterval,
            bundleIDs: [],
            hosts: [],
            mode: .textOnly,
            pageSize: 20,
            cursor: nil,
            accessPolicy: policy
        )
    }
}

private func makeResult(index: Int, bundleID: String, host: String, now: Date) throws
    -> SearchResult
{
    try SearchResult(
        frameID: UUID(uuidString: String(format: "66000000-0000-0000-0000-%012d", index + 100))!,
        capturedAt: now.addingTimeInterval(TimeInterval(-index)),
        foreground: ForegroundContext(
            bundleID: bundleID,
            applicationName: bundleID,
            processID: nil,
            windowTitle: nil,
            windowBounds: try NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        ),
        browser: try BrowserContext(
            family: .safari,
            origin: BrowserOrigin(scheme: "https", host: host, path: nil),
            isPrivateContext: false
        ),
        thumbnailLocator: nil,
        mediaLocator: .opaqueResourceID("resource-\(index)"),
        evidence: [SearchEvidence(source: .application, matchedText: bundleID, score: 1)],
        textRank: index + 1,
        visualRank: nil,
        fusedScore: Double(100 - index)
    )
}

private func posixMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? Int)
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error")
    } catch {
        errorHandler(error)
    }
}
