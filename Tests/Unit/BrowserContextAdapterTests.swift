import Foundation
import MemoryCapture
import MemoryContracts
import XCTest

final class BrowserContextAdapterTests: XCTestCase {
    func testSupportedContextMatrixMeetsAccuracyAndSerializesNoSensitiveURLComponents() throws {
        let configuration = try loadFixtureConfiguration()
        let fixtures = LM021BrowserContextFixture.make(seed: configuration.seed)

        XCTAssertEqual(fixtures.count, configuration.contextCount)
        var exact = 0
        var approved = 0
        var privateCount = 0
        var unavailableCounts: [String: Int] = [:]
        for fixture in fixtures {
            let actual = BrowserAddressFieldAdapter().inspect(fixture.observation)
            if actual == fixture.expectedResolution {
                exact += 1
            }
            switch actual {
            case let .approved(output):
                approved += 1
                XCTAssertEqual(output.targetWindowID, fixture.observation.target.windowID, fixture.id)
                XCTAssertEqual(output.context.origin.host, fixture.expectedHost, fixture.id)
                let encoded = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
                XCTAssertFalse(encoded.contains("credential-sentinel"), fixture.id)
                XCTAssertFalse(encoded.contains("query-sentinel"), fixture.id)
                XCTAssertFalse(encoded.contains("fragment-sentinel"), fixture.id)
                XCTAssertFalse(encoded.contains("@"), fixture.id)
                XCTAssertFalse(output.context.isPrivateContext, fixture.id)
            case let .privateContext(output):
                privateCount += 1
                XCTAssertEqual(output.targetWindowID, fixture.observation.target.windowID, fixture.id)
                let encoded = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
                XCTAssertFalse(encoded.contains("example.test"), fixture.id)
                XCTAssertFalse(encoded.contains("sentinel"), fixture.id)
            case let .unavailable(reason):
                unavailableCounts[reason.rawValue, default: 0] += 1
            }
        }

        XCTAssertGreaterThanOrEqual(
            Double(exact) / Double(fixtures.count),
            configuration.minimumExactAccuracy
        )
        XCTAssertEqual(approved, configuration.approvedCount)
        XCTAssertEqual(privateCount, configuration.privateCount)
        XCTAssertEqual(unavailableCounts, configuration.unavailableCounts)
    }

    func testEverySupportedBrowserUsesAnExplicitAdapterAndBundleAllowlist() throws {
        let registry = BrowserAdapterRegistry.production

        XCTAssertEqual(Set(registry.adapters.map(\.browser)), Set(SupportedBrowser.allCases))
        XCTAssertEqual(registry.adapter(for: "com.apple.Safari")?.browser, .safari)
        XCTAssertEqual(registry.adapter(for: "com.google.Chrome")?.browser, .chrome)
        XCTAssertEqual(registry.adapter(for: "company.thebrowser.Browser")?.browser, .arcDia)
        XCTAssertEqual(registry.adapter(for: "company.thebrowser.dia")?.browser, .arcDia)
        XCTAssertEqual(registry.adapter(for: "com.microsoft.edgemac")?.browser, .edge)
        XCTAssertEqual(registry.adapter(for: "org.mozilla.firefox")?.browser, .firefox)
        XCTAssertNil(registry.adapter(for: "com.example.lookalike-browser"))
    }

    func testTargetAssociationRequiresSamePIDAndNormalizedBounds() throws {
        let approved = BrowserContextObservation.fixture(browser: .chrome)
        var wrongPID = approved
        wrongPID.observedProcessID += 1
        var wrongBounds = approved
        wrongBounds.observedWindowBounds = PointRect(x: 900, y: 700, width: 200, height: 100)

        XCTAssertApproved(BrowserAddressFieldAdapter().inspect(approved))
        XCTAssertEqual(
            BrowserAddressFieldAdapter().inspect(wrongPID),
            .unavailable(.targetWindowMismatch)
        )
        XCTAssertEqual(
            BrowserAddressFieldAdapter().inspect(wrongBounds),
            .unavailable(.targetWindowMismatch)
        )
    }

    func testAmbiguousAddressFieldsAndUnknownPrivateStateFailClosed() throws {
        var ambiguous = BrowserContextObservation.fixture(browser: .firefox)
        ambiguous.addressCandidates.append(ambiguous.addressCandidates[0])
        var unknownPrivate = BrowserContextObservation.fixture(browser: .safari)
        unknownPrivate.privateState = .unknown

        XCTAssertEqual(
            BrowserAddressFieldAdapter().inspect(ambiguous),
            .unavailable(.ambiguousAddressField)
        )
        XCTAssertEqual(
            BrowserAddressFieldAdapter().inspect(unknownPrivate),
            .unavailable(.privateStateUnavailable)
        )
    }

    func testPrivateOutputContainsClassificationAndTargetIdentityButNoContent() throws {
        var observation = BrowserContextObservation.fixture(browser: .arcDia)
        observation.privateState = .privateContext
        observation.windowTitle = "SENSITIVE_PRIVATE_TITLE_SENTINEL"
        observation.addressCandidates = [
            BrowserAddressCandidate(
                role: "AXTextField",
                value: "https://private.example.test/SENSITIVE_PATH_SENTINEL",
                descriptor: "Address and search bar",
                isFocused: true
            ),
        ]

        guard case let .privateContext(output) = BrowserAddressFieldAdapter().inspect(observation) else {
            return XCTFail("Expected content-free private classification")
        }
        let encoded = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SENSITIVE"))
        XCTAssertFalse(encoded.contains("example.test"))
    }

    func testOnlyHTTPOriginsAndDefaultPortsAreRepresentable() throws {
        var defaultPort = BrowserContextObservation.fixture(browser: .edge)
        defaultPort.addressCandidates = [
            BrowserAdapterRegistry.production.adapter(for: defaultPort.target.bundleIdentifier)!
                .fixtureAddressCandidate(value: "HTTPS://Example.COM:443/safe"),
        ]
        var nonDefaultPort = defaultPort
        nonDefaultPort.addressCandidates = [
            BrowserAdapterRegistry.production.adapter(for: nonDefaultPort.target.bundleIdentifier)!
                .fixtureAddressCandidate(value: "https://example.com:8443/safe"),
        ]
        var fileURL = defaultPort
        fileURL.addressCandidates = [
            BrowserAdapterRegistry.production.adapter(for: fileURL.target.bundleIdentifier)!
                .fixtureAddressCandidate(value: "file:///Users/fixture/private"),
        ]

        guard case let .approved(output) = BrowserAddressFieldAdapter().inspect(defaultPort) else {
            return XCTFail("Expected normalized default HTTPS port")
        }
        XCTAssertEqual(output.serializedURL, "https://example.com/safe")
        XCTAssertEqual(
            BrowserAddressFieldAdapter().inspect(nonDefaultPort),
            .unavailable(.unsupportedURL)
        )
        XCTAssertEqual(
            BrowserAddressFieldAdapter().inspect(fileURL),
            .unavailable(.unsupportedURL)
        )
    }

    func testUnsupportedBundleCannotBorrowASupportedAdapterShape() throws {
        var observation = BrowserContextObservation.fixture(browser: .chrome)
        observation.target = BrowserResolvedTarget(
            windowID: observation.target.windowID,
            processID: observation.target.processID,
            bundleIdentifier: "com.example.lookalike-browser",
            bounds: observation.target.bounds
        )

        XCTAssertEqual(
            BrowserAddressFieldAdapter().inspect(observation),
            .unavailable(.unsupportedBrowser)
        )
    }

    private func loadFixtureConfiguration() throws -> LM021FixtureConfiguration {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM021/browser-context-matrix.json")
        return try JSONDecoder().decode(
            LM021FixtureConfiguration.self,
            from: Data(contentsOf: sourceURL)
        )
    }
}

private struct LM021FixtureConfiguration: Decodable {
    let seed: UInt64
    let contextCount: Int
    let approvedCount: Int
    let privateCount: Int
    let unavailableCounts: [String: Int]
    let minimumExactAccuracy: Double
}

private func XCTAssertApproved(
    _ resolution: BrowserContextResolution,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .approved = resolution else {
        return XCTFail("Expected approved context, got \(resolution)", file: file, line: line)
    }
}

private extension BrowserContextObservation {
    static func fixture(browser: SupportedBrowser) -> Self {
        let adapter = BrowserAdapterRegistry.production.adapters.first { $0.browser == browser }!
        return Self(
            target: BrowserResolvedTarget(
                windowID: 71,
                processID: 42,
                bundleIdentifier: adapter.bundleIdentifiers.first!,
                bounds: PointRect(x: 100, y: 80, width: 900, height: 640)
            ),
            observedProcessID: 42,
            observedWindowBounds: PointRect(x: 100, y: 80, width: 900, height: 640),
            windowTitle: "Approved Window",
            privateState: .publicContext,
            addressCandidates: [adapter.fixtureAddressCandidate(
                value: "https://User:credential-sentinel@Example.COM/safe/path?token=query-sentinel#fragment-sentinel"
            )]
        )
    }
}
