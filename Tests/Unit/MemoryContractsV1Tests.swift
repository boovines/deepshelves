import Foundation
import MemoryContracts
import XCTest

final class MemoryContractsV1Tests: XCTestCase {
    func testCaptureEnvelopeRoundTripsWithCanonicalClockAndCoordinates() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_777_777_777.125)
        let envelope = try CaptureEnvelope(
            id: XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")),
            capturedAt: capturedAt,
            continuousTimeNanoseconds: 9_876_543_210,
            displayID: 1,
            captureEpochID: XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
            targetWindowID: 42,
            surfaceKind: .foregroundWindow,
            pixelSize: try PixelSize(width: 1440, height: 900),
            foreground: try ForegroundContext(
                bundleID: "com.apple.Safari",
                applicationName: "Safari",
                processID: 123,
                windowTitle: "Fixture",
                windowBounds: try NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
            ),
            browser: try BrowserContext(
                family: .safari,
                origin: try BrowserOrigin(scheme: "https", host: "example.com", path: "/fixture"),
                isPrivateContext: false
            ),
            activity: .active,
            reason: .contextChange,
            policyDecisionID: XCTUnwrap(UUID(uuidString: "99999999-8888-7777-6666-555555555555"))
        )

        let encoded = try ContractJSON.encode(envelope)
        let decoded = try ContractJSON.decode(CaptureEnvelope.self, from: encoded)

        XCTAssertEqual(decoded, envelope)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        XCTAssertTrue(json.contains("2026-05-03T03:09:37.125Z"))
        XCTAssertFalse(json.contains("pixelBuffer"))
    }

    func testReadyMediaChunkRoundTripsAsASingleThirtySecondEpoch() throws {
        let startedAt = Date(timeIntervalSince1970: 1_777_777_700)
        let chunk = try MediaChunk(
            id: XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000001")),
            captureEpochID: XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000002")),
            targetWindowID: 42,
            relativePath: "media/2026/05/03/20000000-0000-0000-0000-000000000001.mov",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            codec: .hevcMain,
            container: .quickTimeMovie,
            width: 1440,
            height: 900,
            frameCount: 15,
            byteCount: 4096,
            sha256: Data(repeating: 0xAB, count: 32),
            state: .ready
        )

        XCTAssertEqual(
            try ContractJSON.decode(MediaChunk.self, from: ContractJSON.encode(chunk)),
            chunk
        )
    }

    func testSearchableFrameRoundTripsOnlyApprovedRelativeLocators() throws {
        let frame = try SearchableFrame(
            id: XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001")),
            captureEpochID: XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000002")),
            targetWindowID: 42,
            capturedAt: Date(timeIntervalSince1970: 1_777_777_715.5),
            chunkID: XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000001")),
            presentationTimeMS: 15_500,
            thumbnailPath: "thumbnails/2026/05/03/30000000-0000-0000-0000-000000000001.heic",
            foreground: try fixtureForeground(),
            browser: try fixtureBrowser(),
            textState: .pending,
            visualState: .suppressed,
            isTransition: true,
            schemaVersion: 1
        )

        XCTAssertEqual(
            try ContractJSON.decode(SearchableFrame.self, from: ContractJSON.encode(frame)),
            frame
        )
    }

    func testTextSpanCanonicalizesUnicodeAndWhitespaceBeforePersistence() throws {
        let span = try TextSpan(
            id: XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000001")),
            frameID: XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001")),
            source: .visionOCR,
            text: "  Cafe\u{301}\n\tfixture  ",
            bounds: try NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1),
            confidence: 0.95,
            languageCode: "en-US",
            sensitivity: .normal
        )

        XCTAssertEqual(span.text, "Café fixture")
        XCTAssertEqual(
            try ContractJSON.decode(TextSpan.self, from: ContractJSON.encode(span)), span)
    }

    func testEnrichmentArtifactRoundTripsAValidatedRelativeFileOffset() throws {
        let artifact = try EnrichmentArtifact(
            id: XCTUnwrap(UUID(uuidString: "50000000-0000-0000-0000-000000000001")),
            frameID: XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001")),
            kind: .visualVector,
            producer: try ProducerVersion(
                name: "MobileCLIP-S0",
                semanticVersion: "1.0.0",
                modelHash: Data(repeating: 0x11, count: 32)
            ),
            createdAt: Date(timeIntervalSince1970: 1_777_777_720),
            payloadLocator: .relativeFileOffset(
                path: "vectors/mobileclip-s0/fixture.f16",
                byteOffset: 512,
                byteLength: 1024
            ),
            contentHash: Data(repeating: 0x22, count: 32),
            state: .ready
        )

        XCTAssertEqual(
            try ContractJSON.decode(EnrichmentArtifact.self, from: ContractJSON.encode(artifact)),
            artifact
        )
    }

    func testSearchRequestIsDeterministicallyClampedAndScopedByAgentPolicy() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_777_700_000),
            duration: 86_400
        )
        let policy = try AccessPolicy(
            id: XCTUnwrap(UUID(uuidString: "60000000-0000-0000-0000-000000000001")),
            name: "Fixture agent",
            allowedInterval: interval,
            allowedBundleIDs: ["com.fixture.Zeta", "com.fixture.Alpha"],
            allowedHosts: ["z.example", "a.example"],
            allowImageResources: false,
            maxResults: 25,
            expiresAt: interval.end.addingTimeInterval(3_600),
            createdByUser: true
        )
        let request = try SearchRequest(
            query: "fixture",
            interval: interval,
            bundleIDs: ["com.fixture.Alpha"],
            hosts: ["a.example"],
            mode: .hybrid,
            pageSize: 90,
            cursor: nil,
            accessPolicy: policy
        )

        XCTAssertEqual(request.pageSize, 25)
        let encoded = try ContractJSON.encode(request)
        XCTAssertEqual(try ContractJSON.decode(SearchRequest.self, from: encoded), request)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertLessThan(
            try XCTUnwrap(json.range(of: "com.fixture.Alpha")?.lowerBound),
            try XCTUnwrap(json.range(of: "com.fixture.Zeta")?.lowerBound)
        )
    }

    func testSearchPageUsesStableScoreTimeAndUUIDOrdering() throws {
        let older = try fixtureSearchResult(
            id: "70000000-0000-0000-0000-000000000001",
            capturedAt: Date(timeIntervalSince1970: 100),
            score: 0.8
        )
        let lexicalSecond = try fixtureSearchResult(
            id: "70000000-0000-0000-0000-000000000003",
            capturedAt: Date(timeIntervalSince1970: 200),
            score: 0.8
        )
        let lexicalFirst = try fixtureSearchResult(
            id: "70000000-0000-0000-0000-000000000002",
            capturedAt: Date(timeIntervalSince1970: 200),
            score: 0.8
        )
        let highest = try fixtureSearchResult(
            id: "70000000-0000-0000-0000-000000000004",
            capturedAt: Date(timeIntervalSince1970: 50),
            score: 0.9
        )

        let page = try SearchPage(
            results: [lexicalSecond, older, highest, lexicalFirst],
            nextCursor: try SearchCursor(token: "fixture.cursor")
        )

        XCTAssertEqual(
            page.results.map(\.frameID),
            [
                highest.frameID,
                lexicalFirst.frameID,
                lexicalSecond.frameID,
                older.frameID,
            ])
        XCTAssertEqual(
            try ContractJSON.decode(SearchPage.self, from: ContractJSON.encode(page)), page)
    }

    func testTimelineSlicePreservesOrderedFramesAndTypedGaps() throws {
        let start = Date(timeIntervalSince1970: 1_777_700_000)
        let interval = DateInterval(start: start, duration: 300)
        let frame = try TimelineFrameSummary(
            frameID: XCTUnwrap(UUID(uuidString: "80000000-0000-0000-0000-000000000001")),
            capturedAt: start.addingTimeInterval(240),
            foreground: fixtureForeground(),
            thumbnailLocator: .archiveRelativePath("thumbnails/2026/05/03/timeline.heic")
        )
        let gap = try RecordingGap(
            startedAt: start.addingTimeInterval(60),
            endedAt: start.addingTimeInterval(120),
            reason: .idle,
            approvedBundleID: "com.apple.Safari"
        )
        let slice = try TimelineSlice(
            interval: interval,
            frames: [frame],
            gaps: [gap],
            applicationTransitions: [],
            transcriptMarkers: []
        )

        XCTAssertEqual(
            try ContractJSON.decode(TimelineSlice.self, from: ContractJSON.encode(slice)), slice)
        XCTAssertEqual(slice.gaps.first?.reason, .idle)
    }

    func testVerifiedDeletionTombstoneContainsAuthorityAndCountsButNoContent() throws {
        let requestedAt = Date(timeIntervalSince1970: 1_777_700_000)
        let tombstone = try DeletionTombstone(
            id: XCTUnwrap(UUID(uuidString: "90000000-0000-0000-0000-000000000001")),
            requestedInterval: nil,
            requestedFrameIDs: [
                XCTUnwrap(UUID(uuidString: "90000000-0000-0000-0000-000000000003")),
                XCTUnwrap(UUID(uuidString: "90000000-0000-0000-0000-000000000002")),
            ],
            reason: .userMoment,
            requestedAt: requestedAt,
            completedAt: requestedAt.addingTimeInterval(2),
            affectedChunkCount: 1,
            affectedArtifactCount: 4,
            replacementChunkIDs: [
                XCTUnwrap(UUID(uuidString: "90000000-0000-0000-0000-000000000004"))
            ],
            verificationHash: Data(repeating: 0x33, count: 32),
            state: .verified
        )

        let encoded = try ContractJSON.encode(tombstone)
        XCTAssertEqual(try ContractJSON.decode(DeletionTombstone.self, from: encoded), tombstone)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("deletedText"))
        XCTAssertFalse(json.contains("mediaLocator"))
    }

    func testProcessingJobRoundTripsRecoverableRetryState() throws {
        let job = try ProcessingJob(
            id: XCTUnwrap(UUID(uuidString: "a0000000-0000-0000-0000-000000000001")),
            parentID: XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001")),
            kind: .visionOCR,
            priority: 100,
            state: .retryableFailure,
            attemptCount: 2,
            nextAttemptAt: Date(timeIntervalSince1970: 1_777_700_100),
            producer: try ProducerVersion(
                name: "VisionOCR",
                semanticVersion: "1.0.0",
                modelHash: Data(repeating: 0x44, count: 32)
            ),
            lastErrorCode: "vision_temporarily_unavailable",
            leaseExpiresAt: nil
        )

        XCTAssertEqual(
            try ContractJSON.decode(ProcessingJob.self, from: ContractJSON.encode(job)), job)
    }

    func testNormalizedCoordinatesRejectPixelsOutsideTheApprovedDisplay() {
        XCTAssertThrowsError(try NormalizedRect(x: 0.8, y: 0.2, width: 0.3, height: 0.4)) { error in
            XCTAssertEqual((error as? ContractValidationError)?.violation, .outOfRange)
        }
    }

    func testEmptyAgentAllowlistsMeanNoContentRatherThanAllContent() throws {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_777_700_000), duration: 60)
        let policy = try AccessPolicy(
            id: XCTUnwrap(UUID(uuidString: "b0000000-0000-0000-0000-000000000001")),
            name: "No content",
            allowedInterval: interval,
            allowedBundleIDs: [],
            allowedHosts: [],
            maxResults: 10,
            expiresAt: interval.end.addingTimeInterval(60),
            createdByUser: true
        )

        XCTAssertThrowsError(
            try SearchRequest(
                query: "fixture",
                interval: interval,
                bundleIDs: ["com.apple.Safari"],
                hosts: [],
                mode: .textOnly,
                pageSize: 10,
                cursor: nil,
                accessPolicy: policy
            )
        ) { error in
            XCTAssertEqual((error as? ContractValidationError)?.violation, .inconsistent)
        }
    }

    func testPolicyUncertainGapCannotPersistApplicationIdentity() {
        let start = Date(timeIntervalSince1970: 1_777_700_000)
        XCTAssertThrowsError(
            try RecordingGap(
                startedAt: start,
                endedAt: start.addingTimeInterval(1),
                reason: .excluded,
                approvedBundleID: "com.secret.PasswordManager"
            )
        ) { error in
            XCTAssertEqual((error as? ContractValidationError)?.violation, .inconsistent)
        }
    }

    private func fixtureSearchResult(id: String, capturedAt: Date, score: Double) throws
        -> SearchResult
    {
        try SearchResult(
            frameID: XCTUnwrap(UUID(uuidString: id)),
            capturedAt: capturedAt,
            foreground: fixtureForeground(),
            browser: fixtureBrowser(),
            thumbnailLocator: .archiveRelativePath("thumbnails/2026/05/03/fixture.heic"),
            mediaLocator: .archiveRelativePath("media/2026/05/03/fixture.mov"),
            evidence: [
                SearchEvidence(source: .accessibility, matchedText: "fixture", score: score)
            ],
            textRank: 1,
            visualRank: nil,
            fusedScore: score
        )
    }

    private func fixtureForeground() throws -> ForegroundContext {
        try ForegroundContext(
            bundleID: "com.apple.Safari",
            applicationName: "Safari",
            processID: 123,
            windowTitle: "Fixture",
            windowBounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        )
    }

    private func fixtureBrowser() throws -> BrowserContext {
        try BrowserContext(
            family: .safari,
            origin: BrowserOrigin(scheme: "https", host: "example.com", path: "/fixture"),
            isPrivateContext: false
        )
    }
}
