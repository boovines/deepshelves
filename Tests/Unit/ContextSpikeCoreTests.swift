import Foundation
import MemoryEnrichment
import XCTest

final class ContextSpikeCoreTests: XCTestCase {
    func testAXProjectionIsBoundedAndSuppressesSecureFieldValues() throws {
        let secret = "S2_PROHIBITED_PASSWORD_SENTINEL"
        let ordinary = AXFixtureNode(
            role: "AXStaticText",
            title: "Approved visible context",
            frame: ContextRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)
        )
        let secure = AXFixtureNode(
            role: "AXSecureTextField",
            title: "Password",
            value: secret,
            frame: ContextRect(x: 0.1, y: 0.3, width: 0.5, height: 0.1)
        )
        let excess = (0 ..< 40).map { index in
            AXFixtureNode(role: "AXStaticText", title: "row-\(index)")
        }
        let root = AXFixtureNode(role: "AXWindow", children: [ordinary, secure] + excess)

        let projection = BoundedAXProjector(
            limits: AXTraversalLimits(maximumNodes: 12, maximumDepth: 4, maximumStringLength: 64)
        ).project(root)

        XCTAssertLessThanOrEqual(projection.nodesVisited, 12)
        XCTAssertTrue(projection.wasTruncated)
        XCTAssertTrue(projection.spans.contains { $0.text == "Approved visible context" })
        XCTAssertFalse(projection.spans.contains { $0.text.contains(secret) })
        XCTAssertTrue(projection.spans.contains { $0.text == "Password" })
    }

    func testBrowserAdapterRequiresTargetAssociationAndNormalizesURL() throws {
        let fixture = BrowserContextFixture(
            family: .chromium,
            bundleID: "com.google.Chrome",
            resolvedWindowToken: "window-7",
            observationWindowToken: "window-7",
            isPrivateHint: false,
            nodes: [
                AXFixtureNode(
                    role: "AXTextField",
                    value: "https://User:pass@Example.COM/safe/path?token=secret#fragment",
                    description: "Address and search bar",
                    identifier: "address-bar"
                ),
            ]
        )

        let decision = BrowserContextAdapter().inspect(fixture, siteRulesExist: true)
        guard case let .approved(context) = decision else {
            return XCTFail("Expected an approved browser context, got \(decision)")
        }
        XCTAssertEqual(context.scheme, "https")
        XCTAssertEqual(context.host, "example.com")
        XCTAssertEqual(context.path, "/safe/path")
        XCTAssertFalse(context.serializedURL.contains("User"))
        XCTAssertFalse(context.serializedURL.contains("secret"))
        XCTAssertFalse(context.serializedURL.contains("fragment"))

        var mismatched = fixture
        mismatched.observationWindowToken = "background-window"
        XCTAssertEqual(
            BrowserContextAdapter().inspect(mismatched, siteRulesExist: true),
            .suppressed(.targetWindowMismatch)
        )
    }

    func testBrowserAdapterFailsClosedForPrivateOrUnavailableSiteContext() throws {
        let privateFixture = BrowserContextFixture(
            family: .safari,
            bundleID: "com.apple.Safari",
            resolvedWindowToken: "private-window",
            observationWindowToken: "private-window",
            isPrivateHint: true,
            nodes: [AXFixtureNode(role: "AXDocument", value: "https://private.example/")]
        )
        XCTAssertEqual(
            BrowserContextAdapter().inspect(privateFixture, siteRulesExist: false),
            .suppressed(.privateContext)
        )

        let unavailable = BrowserContextFixture(
            family: .firefox,
            bundleID: "org.mozilla.firefox",
            resolvedWindowToken: "window-1",
            observationWindowToken: "window-1",
            isPrivateHint: false,
            nodes: [AXFixtureNode(role: "AXStaticText", title: "No address observation")]
        )
        XCTAssertEqual(
            BrowserContextAdapter().inspect(unavailable, siteRulesExist: true),
            .suppressed(.urlUnavailableWithSiteRule)
        )
        XCTAssertEqual(
            BrowserContextAdapter().inspect(unavailable, siteRulesExist: false),
            .metadataOnly
        )
    }

    func testAXOCRMergeIsStableAndPrefersAXForOverlappingDuplicateText() throws {
        let sharedBounds = ContextRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        let ax = [
            ContextTextObservation(text: "Quarterly Plan", source: .accessibility, bounds: sharedBounds),
            ContextTextObservation(text: "AX unique", source: .accessibility, bounds: nil),
        ]
        let ocr = [
            ContextTextObservation(text: "quarterly   plan", source: .visionOCR, bounds: sharedBounds),
            ContextTextObservation(
                text: "OCR unique",
                source: .visionOCR,
                bounds: ContextRect(x: 0.1, y: 0.5, width: 0.25, height: 0.1),
                confidence: 0.98
            ),
        ]

        let merger = AXOCRMerger()
        let first = merger.merge(accessibility: ax, ocr: ocr)
        let second = merger.merge(accessibility: ax.reversed(), ocr: ocr.reversed())

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.filter { $0.normalizedText == "quarterly plan" }.count, 1)
        XCTAssertEqual(first.first { $0.normalizedText == "quarterly plan" }?.source, .accessibility)
        XCTAssertEqual(Set(first.map(\.normalizedText)), ["quarterly plan", "ax unique", "ocr unique"])
    }

    func testPrivacyProjectionDropsEveryArtifactForDeniedOrMismatchedContexts() throws {
        let sentinel = "S2_FORBIDDEN_DERIVATIVE_SENTINEL"
        let candidate = ContextArtifactBundle(
            media: sentinel,
            thumbnail: sentinel,
            text: sentinel,
            title: sentinel,
            url: sentinel,
            vector: sentinel,
            cache: sentinel,
            log: sentinel
        )
        let gate = ContextPrivacyGate()

        for decision in ContextPrivacyDecision.allCases where decision != .allowed {
            XCTAssertTrue(
                gate.project(
                    candidate,
                    decision: decision,
                    approvedWindowToken: "approved",
                    observationWindowToken: "approved"
                ).isEmpty,
                decision.rawValue
            )
        }
        XCTAssertTrue(
            gate.project(
                candidate,
                decision: .allowed,
                approvedWindowToken: "approved",
                observationWindowToken: "background"
            ).isEmpty
        )
        XCTAssertEqual(
            gate.project(
                candidate,
                decision: .allowed,
                approvedWindowToken: "approved",
                observationWindowToken: "approved"
            ),
            candidate
        )
    }

    func testS2FixtureCatalogPinsRequiredCountsAndContexts() throws {
        let catalog = S2FixtureCatalog.make(seed: 0xD335_5EED)
        XCTAssertEqual(catalog.axFixtures.count, 250)
        XCTAssertEqual(catalog.ocrFixtures.count, 200)
        XCTAssertEqual(catalog.privacyFixtures.count, 190)
        XCTAssertGreaterThanOrEqual(catalog.browserFixtures.count, 500)

        let contexts = Set(catalog.axFixtures.map(\.contextID))
        let required: Set<String> = [
            "safari", "chrome", "arc-dia", "edge", "firefox", "finder", "notes", "mail",
            "calendar", "preview-pdf", "terminal", "vscode", "xcode", "slack", "electron",
        ]
        XCTAssertTrue(required.isSubset(of: contexts))
        XCTAssertEqual(catalog.ocrFixtures.filter(\.isHighContrastLatin).count, 150)
    }
}
