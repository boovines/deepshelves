import Foundation
import MemoryCapture
import MemoryContracts
import MemoryStore
import XCTest

final class PrivacyPolicyTests: XCTestCase {
    func testFixedExclusionsCannotBeRemovedOrOverridden() async throws {
        let configuration = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory",
            rules: [
                PrivacyRule(
                    id: "allow-self",
                    matcher: .application("com.justinhou.deepshelves.localmemory"),
                    action: .allow
                ),
                PrivacyRule(
                    id: "allow-login",
                    matcher: .application("com.apple.loginwindow"),
                    action: .allow
                ),
            ]
        )
        let policy = PrivacyPolicy(configuration: configuration)

        for bundleID in configuration.fixedExcludedBundleIdentifiers {
            let result = await policy.prefilter(context: .fixture(bundleIdentifier: bundleID))
            XCTAssertDenied(result, reason: .fixedApplicationExclusion, bundleID)
        }

        let encoded = try JSONEncoder().encode(configuration)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedText.contains("fixedExcludedBundleIdentifiers"))
        let restored = try JSONDecoder().decode(
            PrivacyPolicyConfiguration.self,
            from: encoded
        )
        XCTAssertEqual(
            restored.fixedExcludedBundleIdentifiers,
            configuration.fixedExcludedBundleIdentifiers
        )
    }

    func testPasswordManagerDefaultsAreVersionedAndEditableButDenyUntilRemoved() async throws {
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        XCTAssertFalse(defaults.passwordManagerDefaultsVersion.isEmpty)
        XCTAssertTrue(
            defaults.excludedPasswordManagerBundleIdentifiers.contains("com.1password.1password"))

        let defaultPolicy = PrivacyPolicy(configuration: defaults)
        XCTAssertDenied(
            await defaultPolicy.prefilter(
                context: .fixture(bundleIdentifier: "com.1password.1password")
            ),
            reason: .passwordManagerExclusion
        )

        let edited = defaults.replacingPasswordManagerExclusions([])
        let editedPolicy = PrivacyPolicy(configuration: edited)
        XCTAssertAllowed(
            await editedPolicy.prefilter(
                context: .fixture(bundleIdentifier: "com.1password.1password")
            )
        )
    }

    func testPrivateContextsDenyByDefaultAndProduceContentFreeAudit() async throws {
        let policy = PrivacyPolicy(
            configuration: .personalDefault(
                selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
            )
        )
        let context = PrivacyEvaluationContext.fixture(
            bundleIdentifier: "com.google.Chrome",
            browserContext: .privateContext(
                PrivateBrowserContextOutput(targetWindowID: 71, family: .chrome)
            )
        )

        let result = await policy.prefilter(context: context)
        guard case .denied(let decision) = result else {
            return XCTFail("Expected private context denial")
        }
        XCTAssertEqual(decision.reason, .privateBrowserDefault)
        XCTAssertNil(decision.audit.bundleIdentifier)
        XCTAssertNil(decision.audit.host)
        XCTAssertTrue(decision.audit.privateContext)
        XCTAssertEqual(decision.audit.contentFieldCount, 0)
    }

    func testPrivateDefaultCanBeExplicitlyEditedWhenNoSitePolicyNeedsURLContext() async throws {
        let defaults = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        let policy = PrivacyPolicy(
            configuration: defaults.replacingPrivateBrowserHandling(.allow)
        )
        let result = await policy.prefilter(
            context: .fixture(
                bundleIdentifier: "com.google.Chrome",
                browserContext: .privateContext(
                    PrivateBrowserContextOutput(targetWindowID: 71, family: .chrome)
                )
            )
        )

        XCTAssertAllowed(result)
        XCTAssertTrue(result.decision.audit.privateContext)
        XCTAssertNil(result.decision.audit.host)
    }

    func testCaptureRuntimeUncertaintyPrecedesEditableRules() async throws {
        let policy = PrivacyPolicy(
            configuration: .personalDefault(
                selfBundleIdentifier: "com.justinhou.deepshelves.localmemory",
                rules: [
                    PrivacyRule(
                        id: "allow-all-fixtures",
                        matcher: .application("com.example.fixture"),
                        action: .allow
                    )
                ]
            )
        )
        var context = PrivacyEvaluationContext.fixture(bundleIdentifier: "com.example.fixture")

        context.recordingIsActive = false
        XCTAssertDenied(await policy.prefilter(context: context), reason: .recordingStopped)
        context.recordingIsActive = true
        context.screenIsLocked = true
        XCTAssertDenied(await policy.prefilter(context: context), reason: .screenLocked)
        context.screenIsLocked = false
        context.secureInputIsActive = true
        XCTAssertDenied(await policy.prefilter(context: context), reason: .secureInputActive)
    }

    func testUserRulesUseLastMatchingRuleAfterHigherPriorityDefaults() async throws {
        let rules = [
            PrivacyRule(id: "deny-example", matcher: .hostSuffix("example.test"), action: .deny),
            PrivacyRule(id: "allow-docs", matcher: .hostExact("docs.example.test"), action: .allow),
            PrivacyRule(
                id: "deny-browser", matcher: .application("com.google.Chrome"), action: .deny),
            PrivacyRule(
                id: "allow-docs-last", matcher: .hostExact("docs.example.test"), action: .allow),
        ]
        let policy = PrivacyPolicy(
            configuration: .personalDefault(
                selfBundleIdentifier: "com.justinhou.deepshelves.localmemory",
                rules: rules
            )
        )

        let docs = await policy.prefilter(context: .browserFixture(host: "docs.example.test"))
        let other = await policy.prefilter(context: .browserFixture(host: "other.example.test"))

        XCTAssertAllowed(docs, matchedRuleID: "allow-docs-last")
        XCTAssertDenied(other, reason: .userRule, matchedRuleID: "deny-browser")
    }

    func testSiteRulesFailClosedWhenSupportedBrowserContextIsUnavailable() async throws {
        let policy = PrivacyPolicy(
            configuration: .personalDefault(
                selfBundleIdentifier: "com.justinhou.deepshelves.localmemory",
                rules: [
                    PrivacyRule(id: "deny-bank", matcher: .hostSuffix("bank.test"), action: .deny)
                ]
            )
        )
        let unavailableReasons = BrowserContextUnavailableReason.allCases
        for reason in unavailableReasons {
            let context = PrivacyEvaluationContext.fixture(
                bundleIdentifier: "com.google.Chrome",
                browserContext: .unavailable(reason)
            )
            XCTAssertDenied(
                await policy.prefilter(context: context),
                reason: .browserContextUnavailable,
                reason.rawValue
            )
        }
    }

    func testFinalRecheckRejectsTargetContextAndPolicyGenerationRaces() async throws {
        let initial = PrivacyPolicyConfiguration.personalDefault(
            selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
        )
        let policy = PrivacyPolicy(configuration: initial)
        let context = PrivacyEvaluationContext.browserFixture(host: "docs.example.test")
        let prefilter = await policy.prefilter(context: context)
        guard case .allowed(let approval) = prefilter else {
            return XCTFail("Expected prefilter approval")
        }

        var changedTarget = context
        changedTarget.targetWindowID = 72
        XCTAssertDenied(
            await policy.finalRecheck(approval: approval, context: changedTarget),
            reason: .staleTargetOrContext
        )

        var changedEpoch = context
        changedEpoch.captureEpochID = UUID()
        XCTAssertDenied(
            await policy.finalRecheck(approval: approval, context: changedEpoch),
            reason: .staleTargetOrContext
        )

        await policy.replaceConfiguration(
            initial.replacingRules([
                PrivacyRule(
                    id: "deny-docs", matcher: .hostExact("docs.example.test"), action: .deny)
            ])
        )
        XCTAssertDenied(
            await policy.finalRecheck(approval: approval, context: context),
            reason: .stalePolicyGeneration
        )
    }

    func testDeniedAndUncertainPropertyCorpusProjectsZeroArtifacts() async throws {
        let configuration = try loadFixtureConfiguration()
        let policy = PrivacyPolicy(
            configuration: .personalDefault(
                selfBundleIdentifier: "com.justinhou.deepshelves.localmemory",
                rules: [
                    PrivacyRule(
                        id: "deny-sensitive", matcher: .hostSuffix("sensitive.test"), action: .deny)
                ]
            )
        )
        let artifacts = PrivacyArtifactBundle.sentinel("LM022_PROHIBITED_CONTENT_SENTINEL")
        let fixtures = LM022PrivacyFixture.make(seed: configuration.seed)
        XCTAssertEqual(fixtures.count, configuration.caseCount)
        XCTAssertEqual(configuration.pixelPayloadCountForEveryCase, 0)
        XCTAssertEqual(configuration.derivedArtifactCountForEveryCase, 0)
        XCTAssertEqual(
            Dictionary(grouping: fixtures, by: \.expectedReason).mapValues(\.count),
            configuration.reasonCounts
        )

        for fixture in fixtures {
            let result = await policy.prefilter(context: fixture.context)
            XCTAssertDenied(result, reason: fixture.expectedReason, fixture.id)
            XCTAssertTrue(
                PrivacyPersistenceGate.project(artifacts, decision: result.decision).isEmpty,
                fixture.id
            )
        }
    }

    func testPolicyDecisionAuditPersistsOnlyCanonicalNonContentFields() async throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let policy = PrivacyPolicy(
            configuration: .personalDefault(
                selfBundleIdentifier: "com.justinhou.deepshelves.localmemory"
            )
        )
        let result = await policy.prefilter(
            context: .fixture(bundleIdentifier: "com.apple.loginwindow")
        )
        let audit = result.decision.audit

        try archive.recordPolicyDecision(
            id: audit.id,
            decidedAt: audit.decidedAt,
            bundleIdentifier: audit.bundleIdentifier,
            host: audit.host,
            privateContext: audit.privateContext,
            result: audit.result.rawValue,
            matchedRuleID: audit.matchedRuleID
        )
        let rows = try archive.policyDecisionRecords()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, audit.id)
        XCTAssertNil(rows[0].bundleIdentifier)
        XCTAssertNil(rows[0].host)
        XCTAssertEqual(rows[0].result, "denied")
        XCTAssertEqual(rows[0].matchedRuleID, PrivacyPolicyConfiguration.fixedRuleID)
        XCTAssertEqual(rows[0].contentFieldCount, 0)
    }

    func testPolicyAuditStoreRejectsContentBearingFieldInjection() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        XCTAssertThrowsError(
            try archive.recordPolicyDecision(
                id: UUID(),
                decidedAt: Date(),
                bundleIdentifier: "com.example.fixture",
                host: "query.example.test/path?secret=LM022_SENTINEL",
                privateContext: false,
                result: "allowed",
                matchedRuleID: "allow"
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveDatabaseError, .invalidPolicyDecisionAudit)
        }
        XCTAssertEqual(try archive.policyDecisionRecords().count, 0)
    }

    private func loadFixtureConfiguration() throws -> LM022FixtureConfiguration {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM022/privacy-policy-corpus.json")
        return try JSONDecoder().decode(
            LM022FixtureConfiguration.self,
            from: Data(contentsOf: sourceURL)
        )
    }
}

private struct LM022FixtureConfiguration: Decodable {
    let seed: UInt64
    let caseCount: Int
    let categories: [String: Int]
    let pixelPayloadCountForEveryCase: Int
    let derivedArtifactCountForEveryCase: Int

    var reasonCounts: [PrivacyPolicyReason: Int] {
        [
            .ambiguousTarget: categories["ambiguousTarget", default: 0],
            .missingTarget: categories["missingTarget", default: 0],
            .privateBrowserDefault: categories["privateContext", default: 0],
            .userRule: categories["siteDenied", default: 0],
            .browserContextUnavailable: categories["urlContextUnavailable", default: 0],
        ]
    }
}

private func XCTAssertAllowed(
    _ result: PrivacyPrefilterResult,
    matchedRuleID: String? = nil,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .allowed(let approval) = result else {
        return XCTFail("Expected allowed: \(message)", file: file, line: line)
    }
    XCTAssertEqual(approval.decision.matchedRuleID, matchedRuleID, file: file, line: line)
}

private func XCTAssertDenied(
    _ result: PrivacyPrefilterResult,
    reason: PrivacyPolicyReason,
    matchedRuleID: String? = nil,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .denied(let decision) = result else {
        return XCTFail("Expected denied: \(message)", file: file, line: line)
    }
    XCTAssertEqual(decision.reason, reason, message, file: file, line: line)
    if let matchedRuleID {
        XCTAssertEqual(decision.matchedRuleID, matchedRuleID, message, file: file, line: line)
    }
}

private func XCTAssertDenied(
    _ decision: PrivacyPolicyDecision,
    reason: PrivacyPolicyReason,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(decision.isAllowed, message, file: file, line: line)
    XCTAssertEqual(decision.reason, reason, message, file: file, line: line)
}

extension PrivacyEvaluationContext {
    fileprivate static func fixture(
        bundleIdentifier: String,
        browserContext: BrowserContextResolution? = nil
    ) -> Self {
        Self(
            targetWindowID: 71,
            processID: 42,
            bundleIdentifier: bundleIdentifier,
            targetIsUniquelyResolved: true,
            recordingIsActive: true,
            screenIsLocked: false,
            secureInputIsActive: false,
            browserContext: browserContext
        )
    }

    fileprivate static func browserFixture(host: String) -> Self {
        let origin = try! BrowserOrigin(scheme: "https", host: host, path: "/approved")
        let browser = try! BrowserContext(family: .chrome, origin: origin, isPrivateContext: false)
        return fixture(
            bundleIdentifier: "com.google.Chrome",
            browserContext: .approved(
                ApprovedBrowserContextOutput(
                    targetWindowID: 71,
                    context: browser,
                    serializedURL: "https" + "://" + host + "/approved"
                )
            )
        )
    }
}
