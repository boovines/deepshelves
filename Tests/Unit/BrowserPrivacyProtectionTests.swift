import Foundation
import MemoryCapture
import MemoryContracts
import XCTest

final class BrowserPrivacyProtectionTests: XCTestCase {
    func testFrozenBrowserPrivateRevokeAndVersionMatrixHasZeroLeakage() async throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.cases.count, 200)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, 200)

        for testCase in fixture.cases {
            let browser = try XCTUnwrap(SupportedBrowser(rawValue: testCase.browser))
            var observation = BrowserContextObservation.lm057Fixture(browser: browser)
            let permissionHealth: CapturePermissionHealthSnapshot
            let rawResolution: BrowserContextResolution
            switch testCase.scenario {
            case "healthy":
                permissionHealth = .lm057Granted
                rawResolution = BrowserAddressFieldAdapter().inspect(observation)
            case "private":
                permissionHealth = .lm057Granted
                observation.privateState = .privateContext
                rawResolution = BrowserAddressFieldAdapter().inspect(observation)
            case "urlUnavailable":
                permissionHealth = .lm057Granted
                rawResolution = .unavailable(.urlUnavailable)
            case "permissionRevoked":
                permissionHealth = CapturePermissionHealthSnapshot(
                    screenRecording: .granted,
                    accessibility: .revoked,
                    refreshCount: 2,
                    systemPromptWasRequested: false
                )
                rawResolution = BrowserAddressFieldAdapter().inspect(observation)
            case "versionChanged":
                permissionHealth = .lm057Granted
                rawResolution = BrowserAddressFieldAdapter().inspect(observation)
            default:
                return XCTFail("Unknown scenario \(testCase.scenario)")
            }

            let coordinator = ProtectedBrowserContextCoordinator()
            if testCase.scenario == "versionChanged" {
                _ = await coordinator.evaluate(
                    bundleIdentifier: observation.target.bundleIdentifier,
                    applicationVersion: testCase.initialVersion,
                    rawResolution: rawResolution,
                    permissionHealth: permissionHealth,
                    privateBrowserHandling: .exclude,
                    hasProtectedSiteRules: true
                )
            }
            let projection = await coordinator.evaluate(
                bundleIdentifier: observation.target.bundleIdentifier,
                applicationVersion: testCase.nextVersion ?? testCase.initialVersion,
                rawResolution: rawResolution,
                permissionHealth: permissionHealth,
                privateBrowserHandling: .exclude,
                hasProtectedSiteRules: true
            )
            XCTAssertEqual(projection.isCaptureAllowed, testCase.expectedAllowed, testCase.id)
            XCTAssertEqual(projection.issue?.rawValue, testCase.expectedIssue, testCase.id)
            XCTAssertEqual(projection.contentFieldCount, 0, testCase.id)
            if !testCase.expectedAllowed {
                XCTAssertNotNil(projection.userVisibleReason, testCase.id)
                XCTAssertNil(
                    BrowserProtectionExposureGate.project(
                        "LM057_MATRIX_SENTINEL",
                        projection: projection
                    ),
                    testCase.id
                )
            }
        }
    }

    func testPermissionHealthDistinguishesInitialDenialRevocationAndRecoveryWithoutPrompting()
        async
    {
        let monitor = CapturePermissionHealthMonitor()

        let denied = await monitor.refresh(
            observation: CapturePermissionObservation(
                screenRecordingGranted: false,
                accessibilityGranted: false
            )
        )
        XCTAssertEqual(denied.screenRecording, .denied)
        XCTAssertEqual(denied.accessibility, .denied)
        XCTAssertFalse(denied.recordingAvailable)
        XCTAssertFalse(denied.protectedBrowserContextAvailable)

        let granted = await monitor.refresh(
            observation: CapturePermissionObservation(
                screenRecordingGranted: true,
                accessibilityGranted: true
            )
        )
        XCTAssertEqual(granted.screenRecording, .granted)
        XCTAssertEqual(granted.accessibility, .granted)
        XCTAssertTrue(granted.recordingAvailable)
        XCTAssertTrue(granted.protectedBrowserContextAvailable)

        let revoked = await monitor.refresh(
            observation: CapturePermissionObservation(
                screenRecordingGranted: false,
                accessibilityGranted: false
            )
        )
        XCTAssertEqual(revoked.screenRecording, .revoked)
        XCTAssertEqual(revoked.accessibility, .revoked)
        XCTAssertEqual(revoked.refreshCount, 3)
        XCTAssertFalse(revoked.systemPromptWasRequested)

        let recovered = await monitor.refresh(
            observation: CapturePermissionObservation(
                screenRecordingGranted: true,
                accessibilityGranted: true
            )
        )
        XCTAssertEqual(recovered.screenRecording, .granted)
        XCTAssertEqual(recovered.accessibility, .granted)
        XCTAssertFalse(recovered.systemPromptWasRequested)
    }

    func testEverySupportedBrowserPassesHealthyPublicContextMatrix() async throws {
        for browser in SupportedBrowser.allCases {
            let fixture = BrowserContextObservation.lm057Fixture(browser: browser)
            let rawResolution = BrowserAddressFieldAdapter().inspect(fixture)
            let coordinator = ProtectedBrowserContextCoordinator()
            let health = CapturePermissionHealthSnapshot.lm057Granted
            let projection = await coordinator.evaluate(
                bundleIdentifier: fixture.target.bundleIdentifier,
                applicationVersion: "126.0.1",
                rawResolution: rawResolution,
                permissionHealth: health,
                privateBrowserHandling: .exclude,
                hasProtectedSiteRules: true
            )

            XCTAssertNil(projection.issue, browser.rawValue)
            XCTAssertNil(projection.userVisibleReason, browser.rawValue)
            XCTAssertNil(projection.timelineGapReason, browser.rawValue)
            guard case .approved(let approved) = projection.browserContext else {
                return XCTFail("Expected approved context for \(browser.rawValue)")
            }
            XCTAssertEqual(approved.context.family, browser.contractFamily)
            XCTAssertEqual(approved.context.origin.host, "docs.example.test")
        }
    }

    func testPrivateMatrixIsContentFreeAndPolicyControlled() async throws {
        for browser in SupportedBrowser.allCases {
            var fixture = BrowserContextObservation.lm057Fixture(browser: browser)
            fixture.privateState = .privateContext
            fixture.windowTitle = "LM057_PRIVATE_TITLE_SENTINEL"
            fixture.addressCandidates = [
                BrowserAddressCandidate(
                    role: "AXTextField",
                    value: "https" + "://private.example.test/LM057_PRIVATE_URL_SENTINEL",
                    descriptor: "Address",
                    isFocused: true
                )
            ]
            let rawResolution = BrowserAddressFieldAdapter().inspect(fixture)
            let coordinator = ProtectedBrowserContextCoordinator()

            let excluded = await coordinator.evaluate(
                bundleIdentifier: fixture.target.bundleIdentifier,
                applicationVersion: "126.0.1",
                rawResolution: rawResolution,
                permissionHealth: .lm057Granted,
                privateBrowserHandling: .exclude,
                hasProtectedSiteRules: false
            )
            XCTAssertEqual(excluded.issue, .privateContextExcluded, browser.rawValue)
            XCTAssertEqual(excluded.timelineGapReason, .excluded, browser.rawValue)
            XCTAssertEqual(excluded.contentFieldCount, 0, browser.rawValue)
            let encoded = String(decoding: try JSONEncoder().encode(excluded), as: UTF8.self)
            XCTAssertFalse(encoded.contains("LM057_PRIVATE"), browser.rawValue)
            XCTAssertFalse(encoded.contains("private.example.test"), browser.rawValue)

            let allowed = await ProtectedBrowserContextCoordinator().evaluate(
                bundleIdentifier: fixture.target.bundleIdentifier,
                applicationVersion: "126.0.1",
                rawResolution: rawResolution,
                permissionHealth: .lm057Granted,
                privateBrowserHandling: .allow,
                hasProtectedSiteRules: false
            )
            XCTAssertNil(allowed.issue, browser.rawValue)
            guard case .privateContext = allowed.browserContext else {
                return XCTFail("Expected content-free private classification")
            }

            let protected = await ProtectedBrowserContextCoordinator().evaluate(
                bundleIdentifier: fixture.target.bundleIdentifier,
                applicationVersion: "126.0.1",
                rawResolution: rawResolution,
                permissionHealth: .lm057Granted,
                privateBrowserHandling: .allow,
                hasProtectedSiteRules: true
            )
            XCTAssertEqual(protected.issue, .protectedURLContextUnavailable)
            XCTAssertEqual(protected.timelineGapReason, .filterFailed)
        }
    }

    func testEveryUnavailableReasonFailsClosedWithVisibleContentFreeExplanation() async throws {
        let fixture = BrowserContextObservation.lm057Fixture(browser: .chrome)
        for reason in BrowserContextUnavailableReason.allCases {
            let coordinator = ProtectedBrowserContextCoordinator()
            let projection = await coordinator.evaluate(
                bundleIdentifier: fixture.target.bundleIdentifier,
                applicationVersion: "126.0.1",
                rawResolution: .unavailable(reason),
                permissionHealth: .lm057Granted,
                privateBrowserHandling: .exclude,
                hasProtectedSiteRules: true
            )
            XCTAssertEqual(projection.issue, .protectedURLContextUnavailable, reason.rawValue)
            XCTAssertNotNil(projection.userVisibleReason, reason.rawValue)
            XCTAssertEqual(projection.timelineGapReason, .filterFailed, reason.rawValue)
            XCTAssertEqual(projection.contentFieldCount, 0, reason.rawValue)
            XCTAssertNil(
                BrowserProtectionExposureGate.project(
                    "LM057_UNAVAILABLE_SENTINEL",
                    projection: projection
                ),
                reason.rawValue
            )
        }
    }

    func testBrowserVersionChangeCreatesOneContentFreeGapBeforeRevalidatedContext() async throws {
        let fixture = BrowserContextObservation.lm057Fixture(browser: .firefox)
        let rawResolution = BrowserAddressFieldAdapter().inspect(fixture)
        let coordinator = ProtectedBrowserContextCoordinator()

        let initial = await coordinator.evaluate(
            bundleIdentifier: fixture.target.bundleIdentifier,
            applicationVersion: "126.0.1",
            rawResolution: rawResolution,
            permissionHealth: .lm057Granted,
            privateBrowserHandling: .exclude,
            hasProtectedSiteRules: true
        )
        XCTAssertNil(initial.issue)

        let changed = await coordinator.evaluate(
            bundleIdentifier: fixture.target.bundleIdentifier,
            applicationVersion: "127.0.0",
            rawResolution: rawResolution,
            permissionHealth: .lm057Granted,
            privateBrowserHandling: .exclude,
            hasProtectedSiteRules: true
        )
        XCTAssertEqual(changed.issue, .browserVersionChanged)
        XCTAssertEqual(changed.timelineGapReason, .filterFailed)
        guard case .unavailable(.browserVersionChanged) = changed.browserContext else {
            return XCTFail("Version transition must fail closed")
        }
        XCTAssertNil(
            BrowserProtectionExposureGate.project(
                "LM057_VERSION_CHANGE_SENTINEL",
                projection: changed
            )
        )

        let revalidated = await coordinator.evaluate(
            bundleIdentifier: fixture.target.bundleIdentifier,
            applicationVersion: "127.0.0",
            rawResolution: rawResolution,
            permissionHealth: .lm057Granted,
            privateBrowserHandling: .exclude,
            hasProtectedSiteRules: true
        )
        XCTAssertNil(revalidated.issue)
        guard case .approved = revalidated.browserContext else {
            return XCTFail("Stable revalidated version should resume")
        }
    }

    func testPermissionRevocationBlocksBeforeBrowserContentProjection() async {
        let fixture = BrowserContextObservation.lm057Fixture(browser: .safari)
        let rawResolution = BrowserAddressFieldAdapter().inspect(fixture)
        let permissionMonitor = CapturePermissionHealthMonitor()
        _ = await permissionMonitor.refresh(
            observation: CapturePermissionObservation(
                screenRecordingGranted: true,
                accessibilityGranted: true
            )
        )

        for observation in [
            CapturePermissionObservation(
                screenRecordingGranted: false,
                accessibilityGranted: true
            ),
            CapturePermissionObservation(
                screenRecordingGranted: true,
                accessibilityGranted: false
            ),
        ] {
            let health = await permissionMonitor.refresh(observation: observation)
            let projection = await ProtectedBrowserContextCoordinator().evaluate(
                bundleIdentifier: fixture.target.bundleIdentifier,
                applicationVersion: "126.0.1",
                rawResolution: rawResolution,
                permissionHealth: health,
                privateBrowserHandling: .exclude,
                hasProtectedSiteRules: true
            )
            XCTAssertNotNil(projection.issue)
            XCTAssertEqual(projection.timelineGapReason, .permissionLost)
            XCTAssertEqual(projection.contentFieldCount, 0)
            XCTAssertNil(
                BrowserProtectionExposureGate.project(
                    "LM057_PERMISSION_REVOKE_SENTINEL",
                    projection: projection
                )
            )
        }
    }

    func testPrivateHandlingSettingPersistsAndReloadsTheLivePolicyImmediately() async throws {
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        let policy = PrivacyPolicy(configuration: defaults)
        let store = InMemoryPrivacyPolicySettingsStore()
        let controller = PrivacyPolicySettingsController(
            defaultConfiguration: defaults,
            policy: policy,
            store: store
        )
        _ = try await controller.load()

        let receipt = try await controller.replacePrivateBrowserHandling(.allow)
        XCTAssertEqual(receipt.configuration.privateBrowserHandling, .allow)
        XCTAssertEqual(receipt.policyGeneration, 2)
        let stored = await store.load()
        XCTAssertEqual(stored?.privateBrowserHandling, .allow)

        let privateContext = PrivacyEvaluationContext(
            targetWindowID: 570,
            processID: 5_700,
            bundleIdentifier: "com.google.Chrome",
            targetIsUniquelyResolved: true,
            recordingIsActive: true,
            screenIsLocked: false,
            secureInputIsActive: false,
            browserContext: .privateContext(
                PrivateBrowserContextOutput(targetWindowID: 570, family: .chrome)
            )
        )
        let policyResult = await policy.prefilter(context: privateContext)
        XCTAssertTrue(policyResult.decision.isAllowed)
    }

    private func loadFixture() throws -> LM057BrowserProtectionFixture {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM057/browser-protection-matrix.json")
        return try JSONDecoder().decode(
            LM057BrowserProtectionFixture.self,
            from: Data(contentsOf: sourceURL)
        )
    }
}

private struct LM057BrowserProtectionFixture: Decodable {
    let schemaVersion: Int
    let seed: UInt64
    let cases: [LM057BrowserProtectionCase]
}

private struct LM057BrowserProtectionCase: Decodable {
    let id: String
    let browser: String
    let scenario: String
    let initialVersion: String
    let nextVersion: String?
    let expectedAllowed: Bool
    let expectedIssue: String?
}

extension CapturePermissionHealthSnapshot {
    fileprivate static let lm057Granted = CapturePermissionHealthSnapshot(
        screenRecording: .granted,
        accessibility: .granted,
        refreshCount: 1,
        systemPromptWasRequested: false
    )
}

extension BrowserContextObservation {
    fileprivate static func lm057Fixture(browser: SupportedBrowser) -> Self {
        let adapter = BrowserAdapterRegistry.production.adapters.first { $0.browser == browser }!
        return Self(
            target: BrowserResolvedTarget(
                windowID: 570,
                processID: 5_700,
                bundleIdentifier: adapter.bundleIdentifiers.first!,
                bounds: PointRect(x: 120, y: 90, width: 960, height: 640)
            ),
            observedProcessID: 5_700,
            observedWindowBounds: PointRect(x: 120, y: 90, width: 960, height: 640),
            windowTitle: "Synthetic browser fixture",
            privateState: .publicContext,
            addressCandidates: [
                adapter.fixtureAddressCandidate(
                    value: "https" + "://docs.example.test/approved?secret=LM057_QUERY_SENTINEL"
                )
            ]
        )
    }
}
