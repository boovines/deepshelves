import Foundation
import MemoryCapture
import MemoryContracts
import XCTest

final class PrivacyPolicySettingsTests: XCTestCase {
    func testChangeDuringCaptureCorpusPersistsAndExposesNothingAfterEffectiveTime() async throws {
        let fixture = try loadPolicyChangeFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.cases.count, 100)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, 100)

        for testCase in fixture.cases {
            let defaults = PrivacyPolicyConfiguration.personalDefault(
                selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
            )
            let policy = PrivacyPolicy(configuration: defaults)
            let store = InMemoryPrivacyPolicySettingsStore()
            let clock = LM056SettingsClock(testCase.effectiveNanoseconds)
            let controller = PrivacyPolicySettingsController(
                defaultConfiguration: defaults,
                policy: policy,
                store: store,
                clock: clock
            )
            _ = try await controller.load()

            let context = PrivacyEvaluationContext.lm056Fixture(
                bundleIdentifier: testCase.bundleIdentifier
            )
            let initial = await policy.prefilter(context: context)
            guard case .allowed(let approval) = initial else {
                return XCTFail("Expected pre-change approval for \(testCase.id)")
            }

            let receipt = try await controller.appendApplicationExclusion(
                bundleIdentifier: testCase.bundleIdentifier,
                ruleID: testCase.ruleID
            )
            XCTAssertEqual(
                receipt.effectiveNanoseconds,
                testCase.effectiveNanoseconds,
                testCase.id
            )
            XCTAssertEqual(
                receipt.policyGeneration,
                testCase.expectedPolicyGeneration,
                testCase.id
            )

            let staleDecision = await policy.finalRecheck(
                approval: approval,
                context: context
            )
            XCTAssertEqual(staleDecision.reason, .stalePolicyGeneration, testCase.id)
            XCTAssertTrue(
                PrivacyPersistenceGate.project(
                    .sentinel("LM056_EXCLUDED_APP_SENTINEL"),
                    decision: staleDecision
                ).isEmpty,
                testCase.id
            )
            XCTAssertNil(
                PrivacyPolicyExposureGate.project(
                    "LM056_UI_EXCLUDED_APP_SENTINEL",
                    decision: staleDecision
                ),
                testCase.id
            )
            XCTAssertNil(
                PrivacyPolicyExposureGate.project(
                    "LM056_HELPER_EXCLUDED_APP_SENTINEL",
                    decision: staleDecision
                ),
                testCase.id
            )

            let current = await policy.prefilter(context: context)
            XCTAssertFalse(current.decision.isAllowed, testCase.id)
            XCTAssertEqual(
                current.decision.reason.rawValue,
                testCase.expectedDenialReason,
                testCase.id
            )
            XCTAssertEqual(current.decision.matchedRuleID, testCase.ruleID, testCase.id)
            let gap = try PrivacyPolicyTimelineGapProjector.gap(
                for: current.decision,
                startedAt: Date(timeIntervalSince1970: 56),
                endedAt: Date(timeIntervalSince1970: 57)
            )
            XCTAssertEqual(gap.reason.rawValue, testCase.expectedGapReason, testCase.id)
            XCTAssertNil(gap.approvedBundleID, testCase.id)

            let persisted = await store.load()
            XCTAssertEqual(persisted?.rules.last?.id, testCase.ruleID, testCase.id)
        }
    }

    func testApplicationExclusionTakesEffectBeforeAnyLaterCandidateCanPersist() async throws {
        let bundleIdentifier = "com.example.private-notes"
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        let policy = PrivacyPolicy(configuration: defaults)
        let store = InMemoryPrivacyPolicySettingsStore()
        let clock = LM056SettingsClock(2_000_000_000)
        let controller = PrivacyPolicySettingsController(
            defaultConfiguration: defaults,
            policy: policy,
            store: store,
            clock: clock
        )
        _ = try await controller.load()

        let context = PrivacyEvaluationContext.lm056Fixture(bundleIdentifier: bundleIdentifier)
        let before = await policy.prefilter(context: context)
        guard case .allowed(let staleApproval) = before else {
            return XCTFail("Expected the fixture application to begin allowed")
        }

        clock.advance(by: 50)
        let receipt = try await controller.appendApplicationExclusion(
            bundleIdentifier: bundleIdentifier,
            ruleID: "exclude-private-notes"
        )
        XCTAssertEqual(receipt.effectiveNanoseconds, 2_000_000_050)
        XCTAssertEqual(receipt.policyGeneration, 2)

        let staleDecision = await policy.finalRecheck(
            approval: staleApproval,
            context: context
        )
        XCTAssertEqual(staleDecision.reason, .stalePolicyGeneration)
        XCTAssertTrue(
            PrivacyPersistenceGate.project(
                .sentinel("LM056_EXCLUDED_APP_SENTINEL"),
                decision: staleDecision
            ).isEmpty
        )
        XCTAssertNil(
            PrivacyPolicyExposureGate.project(
                "LM056_EXCLUDED_APP_SENTINEL",
                decision: staleDecision
            )
        )

        let after = await policy.prefilter(context: context)
        XCTAssertFalse(after.decision.isAllowed)
        XCTAssertEqual(after.decision.reason, .userRule)
        XCTAssertEqual(after.decision.matchedRuleID, "exclude-private-notes")
        let gap = try PrivacyPolicyTimelineGapProjector.gap(
            for: after.decision,
            startedAt: Date(timeIntervalSince1970: 2_000),
            endedAt: Date(timeIntervalSince1970: 2_001)
        )
        XCTAssertEqual(gap.reason, .excluded)
        XCTAssertNil(gap.approvedBundleID)
    }

    func testRuleOrderingIsPersistedAndLastMatchingRuleWinsAfterImmediateReload() async throws {
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory",
            rules: [
                PrivacyRule(
                    id: "deny-example",
                    matcher: .application("com.example.editor"),
                    action: .deny
                ),
                PrivacyRule(
                    id: "allow-example-last",
                    matcher: .application("com.example.editor"),
                    action: .allow
                ),
            ]
        )
        let policy = PrivacyPolicy(configuration: defaults)
        let store = InMemoryPrivacyPolicySettingsStore(configuration: defaults)
        let controller = PrivacyPolicySettingsController(
            defaultConfiguration: defaults,
            policy: policy,
            store: store,
            clock: LM056SettingsClock(3_000_000_000)
        )
        _ = try await controller.load()
        let context = PrivacyEvaluationContext.lm056Fixture(
            bundleIdentifier: "com.example.editor"
        )

        let initialPreview = try await controller.preview(context: context)
        XCTAssertTrue(initialPreview.isAllowed)
        let receipt = try await controller.moveRule(id: "allow-example-last", to: 0)
        XCTAssertEqual(
            receipt.configuration.rules.map(\.id),
            [
                "allow-example-last", "deny-example",
            ])
        let preview = try await controller.preview(context: context)
        XCTAssertFalse(preview.isAllowed)
        XCTAssertEqual(preview.matchedRuleID, "deny-example")
        let stored = await store.load()
        XCTAssertEqual(
            stored?.rules.map(\.id),
            [
                "allow-example-last", "deny-example",
            ])
    }

    func testPolicyPreviewSupportsSiteRulesWithoutHidingTheMatchedRule() async throws {
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        let policy = PrivacyPolicy(configuration: defaults)
        let controller = PrivacyPolicySettingsController(
            defaultConfiguration: defaults,
            policy: policy,
            store: InMemoryPrivacyPolicySettingsStore(),
            clock: LM056SettingsClock(4_000_000_000)
        )
        _ = try await controller.load()
        _ = try await controller.appendSiteExclusion(
            host: "Example.Test.",
            includeSubdomains: true,
            ruleID: "exclude-example-sites"
        )

        let preview = try await controller.preview(
            context: .lm056BrowserFixture(host: "docs.example.test")
        )
        XCTAssertFalse(preview.isAllowed)
        XCTAssertEqual(preview.reason, .userRule)
        XCTAssertEqual(preview.matchedRuleID, "exclude-example-sites")
        XCTAssertEqual(preview.visibleRuleLabel, "Block example.test and subdomains")
    }

    func testFileStoreRoundTripsOwnerOnlyConfigurationAndRejectsInvalidState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "lm056-settings-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "privacy-policy.json")
        let store = FilePrivacyPolicySettingsStore(fileURL: fileURL)
        let configuration = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory",
            rules: [
                PrivacyRule(
                    id: "exclude-mail",
                    matcher: .application("com.apple.mail"),
                    action: .deny
                )
            ]
        )

        try await store.save(configuration)
        let restored = try await store.load()
        XCTAssertEqual(restored, configuration)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)

        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        await assertThrowsErrorAsync(try await store.load())
    }

    func testInvalidAndDuplicateRulesFailWithoutReplacingTheLivePolicy() async throws {
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        let policy = PrivacyPolicy(configuration: defaults)
        let controller = PrivacyPolicySettingsController(
            defaultConfiguration: defaults,
            policy: policy,
            store: InMemoryPrivacyPolicySettingsStore(),
            clock: LM056SettingsClock(5_000_000_000)
        )
        _ = try await controller.load()

        await assertThrowsErrorAsync(
            try await controller.replaceRules([
                PrivacyRule(
                    id: "duplicate", matcher: .application("com.example.one"), action: .deny),
                PrivacyRule(
                    id: "duplicate", matcher: .application("com.example.two"), action: .deny),
            ])
        )
        await assertThrowsErrorAsync(
            try await controller.appendApplicationExclusion(
                bundleIdentifier: "   ",
                ruleID: "empty-application"
            )
        )
        let snapshot = await controller.snapshot()
        XCTAssertTrue(snapshot.configuration.rules.isEmpty)
        let liveResult = await policy.prefilter(
            context: .lm056Fixture(bundleIdentifier: "com.example.one")
        )
        XCTAssertTrue(liveResult.decision.isAllowed)
    }

    func testEveryPolicyDenialProducesAContentFreeTypedTimelineGap() throws {
        let expectations: [PrivacyPolicyReason: RecordingGapReason] = [
            .userRule: .excluded,
            .fixedApplicationExclusion: .excluded,
            .passwordManagerExclusion: .excluded,
            .privateBrowserDefault: .excluded,
            .recordingStopped: .paused,
            .screenLocked: .protectedSurface,
            .secureInputActive: .protectedSurface,
            .missingTarget: .noWindow,
            .ambiguousTarget: .ambiguousWindow,
            .browserContextUnavailable: .filterFailed,
            .staleTargetOrContext: .filterFailed,
            .stalePolicyGeneration: .filterFailed,
        ]
        for (policyReason, gapReason) in expectations {
            let gap = try PrivacyPolicyTimelineGapProjector.gap(
                for: policyReason,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 11)
            )
            XCTAssertEqual(gap.reason, gapReason, policyReason.rawValue)
            XCTAssertNil(gap.approvedBundleID, policyReason.rawValue)
        }
    }

    func testAllowedPolicyReasonCannotBeProjectedAsAGap() {
        XCTAssertThrowsError(
            try PrivacyPolicyTimelineGapProjector.gap(
                for: .defaultAllow,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 11)
            )
        ) { error in
            XCTAssertEqual(
                error as? PrivacyPolicySettingsError,
                .allowedDecisionCannotCreateGap
            )
        }
    }

    private func loadPolicyChangeFixture() throws -> LM056PolicyChangeFixture {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM056/change-during-capture.json")
        return try JSONDecoder().decode(
            LM056PolicyChangeFixture.self,
            from: Data(contentsOf: sourceURL)
        )
    }
}

private struct LM056PolicyChangeFixture: Decodable {
    let schemaVersion: Int
    let seed: UInt64
    let cases: [LM056PolicyChangeCase]
}

private struct LM056PolicyChangeCase: Decodable {
    let id: String
    let bundleIdentifier: String
    let ruleID: String
    let effectiveNanoseconds: UInt64
    let expectedPolicyGeneration: UInt64
    let expectedDenialReason: String
    let expectedGapReason: String
}

private final class LM056SettingsClock: ActivityMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func nowNanoseconds() -> UInt64 {
        lock.withLock { value }
    }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { value &+= nanoseconds }
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

extension PrivacyEvaluationContext {
    fileprivate static func lm056Fixture(bundleIdentifier: String) -> Self {
        Self(
            targetWindowID: 56,
            processID: 560,
            bundleIdentifier: bundleIdentifier,
            targetIsUniquelyResolved: true,
            recordingIsActive: true,
            screenIsLocked: false,
            secureInputIsActive: false,
            browserContext: nil,
            captureEpochID: UUID(uuidString: "00000000-0000-0000-0000-000000000056")
        )
    }

    fileprivate static func lm056BrowserFixture(host: String) -> Self {
        let origin = try! BrowserOrigin(scheme: "https", host: host, path: "/approved")
        let browser = try! BrowserContext(
            family: .chrome,
            origin: origin,
            isPrivateContext: false
        )
        var context = lm056Fixture(bundleIdentifier: "com.google.Chrome")
        context.browserContext = .approved(
            ApprovedBrowserContextOutput(
                targetWindowID: 56,
                context: browser,
                serializedURL: "https://\(host)/approved"
            )
        )
        return context
    }
}
