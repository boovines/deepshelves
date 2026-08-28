import Foundation

@main
struct ContractFixtureGenerator {
    static let baseDate = Date(timeIntervalSince1970: 1_777_700_000)

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw GeneratorError.usage
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let v2Output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v2Output, withIntermediateDirectories: true)

        let foreground = try makeForeground()
        let browser = try makeBrowser()
        let policy = try makePolicy()

        try write(
            CaptureEnvelope(
                id: id("10000000-0000-0000-0000-000000000001"),
                capturedAt: baseDate.addingTimeInterval(0.125),
                continuousTimeNanoseconds: 9_876_543_210,
                displayID: 1,
                captureEpochID: id("10000000-0000-0000-0000-000000000002"),
                targetWindowID: 42,
                surfaceKind: .foregroundWindow,
                pixelSize: PixelSize(width: 1440, height: 900),
                foreground: foreground,
                browser: browser,
                activity: .active,
                reason: .contextChange,
                policyDecisionID: id("10000000-0000-0000-0000-000000000003")
            ),
            named: "capture-envelope.json",
            into: output
        )
        try write(
            MediaChunk(
                id: id("20000000-0000-0000-0000-000000000001"),
                captureEpochID: id("10000000-0000-0000-0000-000000000002"),
                targetWindowID: 42,
                relativePath: "media/2026/05/02/20000000-0000-0000-0000-000000000001.mov",
                startedAt: baseDate,
                endedAt: baseDate.addingTimeInterval(30),
                codec: .hevcMain,
                container: .quickTimeMovie,
                width: 1440,
                height: 900,
                frameCount: 15,
                byteCount: 4096,
                sha256: digest(0x20),
                state: .ready
            ),
            named: "media-chunk.json",
            into: output
        )
        try write(
            SearchableFrame(
                id: id("30000000-0000-0000-0000-000000000001"),
                captureEpochID: id("10000000-0000-0000-0000-000000000002"),
                targetWindowID: 42,
                capturedAt: baseDate.addingTimeInterval(15.5),
                chunkID: id("20000000-0000-0000-0000-000000000001"),
                presentationTimeMS: 15_500,
                thumbnailPath: "thumbnails/2026/05/02/30000000-0000-0000-0000-000000000001.heic",
                foreground: foreground,
                browser: browser,
                textState: .ready,
                visualState: .pending,
                isTransition: true,
                schemaVersion: 1
            ),
            named: "searchable-frame.json",
            into: output
        )
        try write(
            TextSpan(
                id: id("40000000-0000-0000-0000-000000000001"),
                frameID: id("30000000-0000-0000-0000-000000000001"),
                source: .visionOCR,
                text: "Synthetic fixture text",
                bounds: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1),
                confidence: 0.95,
                languageCode: "en-US",
                sensitivity: .normal
            ),
            named: "text-span.json",
            into: output
        )
        try write(
            EnrichmentArtifact(
                id: id("50000000-0000-0000-0000-000000000001"),
                frameID: id("30000000-0000-0000-0000-000000000001"),
                kind: .visualVector,
                producer: producer("MobileCLIP-S0", hashByte: 0x50),
                createdAt: baseDate.addingTimeInterval(20),
                payloadLocator: .relativeFileOffset(
                    path: "vectors/mobileclip-s0/fixture.f16",
                    byteOffset: 512,
                    byteLength: 1024
                ),
                contentHash: digest(0x51),
                state: .ready
            ),
            named: "enrichment-artifact.json",
            into: output
        )
        try write(policy, named: "access-policy.json", into: output)
        try write(
            SearchRequest(
                query: "fixture",
                interval: policy.allowedInterval,
                bundleIDs: ["com.apple.Safari"],
                hosts: ["example.com"],
                mode: .hybrid,
                pageSize: 25,
                cursor: nil,
                accessPolicy: policy
            ),
            named: "search-request.json",
            into: output
        )
        let result = try SearchResult(
            frameID: id("30000000-0000-0000-0000-000000000001"),
            capturedAt: baseDate.addingTimeInterval(15.5),
            foreground: foreground,
            browser: browser,
            thumbnailLocator: .archiveRelativePath(
                "thumbnails/2026/05/02/30000000-0000-0000-0000-000000000001.heic"
            ),
            mediaLocator: .archiveRelativePath(
                "media/2026/05/02/20000000-0000-0000-0000-000000000001.mov"
            ),
            evidence: [
                SearchEvidence(
                    source: .accessibility, matchedText: "Synthetic fixture text", score: 1)
            ],
            textRank: 1,
            visualRank: 2,
            fusedScore: 0.0325
        )
        try write(
            SearchPage(results: [result], nextCursor: SearchCursor(token: "fixture.cursor.v1")),
            named: "search-page.json",
            into: output
        )
        try write(
            TimelineSlice(
                interval: DateInterval(start: baseDate, duration: 300),
                frames: [
                    TimelineFrameSummary(
                        frameID: result.frameID,
                        capturedAt: result.capturedAt,
                        foreground: foreground,
                        browser: browser,
                        thumbnailLocator: result.thumbnailLocator
                    )
                ],
                gaps: [
                    RecordingGap(
                        startedAt: baseDate.addingTimeInterval(60),
                        endedAt: baseDate.addingTimeInterval(120),
                        reason: .idle,
                        approvedBundleID: "com.apple.Safari"
                    )
                ],
                applicationTransitions: [
                    ApplicationTransition(
                        occurredAt: baseDate.addingTimeInterval(1),
                        fromBundleID: nil,
                        toBundleID: "com.apple.Safari"
                    )
                ],
                transcriptMarkers: []
            ),
            named: "timeline-slice.json",
            into: output
        )
        try write(
            DeletionTombstone(
                id: id("90000000-0000-0000-0000-000000000001"),
                requestedInterval: nil,
                requestedFrameIDs: [result.frameID],
                reason: .userMoment,
                requestedAt: baseDate.addingTimeInterval(400),
                completedAt: baseDate.addingTimeInterval(402),
                affectedChunkCount: 1,
                affectedArtifactCount: 4,
                replacementChunkIDs: [id("90000000-0000-0000-0000-000000000002")],
                verificationHash: digest(0x90),
                state: .verified
            ),
            named: "deletion-tombstone.json",
            into: output
        )
        try write(
            ProcessingJob(
                id: id("a0000000-0000-0000-0000-000000000001"),
                parentID: result.frameID,
                kind: .visionOCR,
                priority: 100,
                state: .retryableFailure,
                attemptCount: 2,
                nextAttemptAt: baseDate.addingTimeInterval(500),
                producer: producer("VisionOCR", hashByte: 0xA0),
                lastErrorCode: "vision_temporarily_unavailable",
                leaseExpiresAt: nil
            ),
            named: "processing-job.json",
            into: output
        )
        try writeV2MediaFixtures(
            foreground: foreground,
            browser: browser,
            into: v2Output
        )
    }

    static func writeV2MediaFixtures(
        foreground: ForegroundContext,
        browser: BrowserContext,
        into output: URL
    ) throws {
        let chunkID = id("21000000-0000-0000-0000-000000000001")
        let epochID = id("11000000-0000-0000-0000-000000000002")
        let frameID = id("31000000-0000-0000-0000-000000000001")
        let manifestPath =
            "media/2026/05/02/21000000-0000-0000-0000-000000000001/manifest.json"
        let framePath =
            "media/2026/05/02/21000000-0000-0000-0000-000000000001/frames/31000000-0000-0000-0000-000000000001.heic"
        let entry = try HEICKeyframeEntry(
            frameID: frameID,
            presentationTimeMS: 0,
            relativePath: "frames/31000000-0000-0000-0000-000000000001.heic",
            byteCount: 1_024,
            sha256: digest(0x31)
        )
        try write(
            HEICKeyframeManifest(
                chunkID: chunkID,
                captureEpochID: epochID,
                targetWindowID: 42,
                width: 1_440,
                height: 900,
                frames: [entry]
            ),
            named: "heic-keyframe-manifest.json",
            into: output
        )
        try write(
            MediaChunk(
                id: chunkID,
                captureEpochID: epochID,
                targetWindowID: 42,
                relativePath: manifestPath,
                startedAt: baseDate,
                endedAt: baseDate.addingTimeInterval(0.001),
                codec: .heicKeyframes,
                container: .heicKeyframeDirectory,
                width: 1_440,
                height: 900,
                frameCount: 1,
                byteCount: 1_536,
                sha256: digest(0x21),
                state: .ready
            ),
            named: "media-chunk.json",
            into: output
        )
        try write(
            SearchableFrame(
                id: frameID,
                captureEpochID: epochID,
                targetWindowID: 42,
                capturedAt: baseDate.addingTimeInterval(0.001),
                chunkID: chunkID,
                presentationTimeMS: 0,
                mediaPath: framePath,
                thumbnailPath:
                    "thumbnails/2026/05/02/31000000-0000-0000-0000-000000000001.heic",
                foreground: foreground,
                browser: browser,
                textState: .ready,
                visualState: .pending,
                isTransition: true,
                schemaVersion: 2
            ),
            named: "searchable-frame.json",
            into: output
        )
        let result = try SearchResult(
            frameID: frameID,
            capturedAt: baseDate.addingTimeInterval(0.001),
            foreground: foreground,
            browser: browser,
            thumbnailLocator: .archiveRelativePath(
                "thumbnails/2026/05/02/31000000-0000-0000-0000-000000000001.heic"
            ),
            mediaLocator: .archiveRelativePath(framePath),
            evidence: [
                SearchEvidence(
                    source: .accessibility,
                    matchedText: "Synthetic fixture text",
                    score: 1
                )
            ],
            textRank: 1,
            visualRank: 2,
            fusedScore: 0.0325
        )
        try write(
            SearchPage(
                results: [result],
                nextCursor: SearchCursor(token: "fixture.cursor.v2")
            ),
            named: "search-page.json",
            into: output
        )
    }

    static func makeForeground() throws -> ForegroundContext {
        try ForegroundContext(
            bundleID: "com.apple.Safari",
            applicationName: "Safari",
            processID: 123,
            windowTitle: "Synthetic Fixture",
            windowBounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        )
    }

    static func makeBrowser() throws -> BrowserContext {
        try BrowserContext(
            family: .safari,
            origin: BrowserOrigin(scheme: "https", host: "example.com", path: "/fixture"),
            isPrivateContext: false
        )
    }

    static func makePolicy() throws -> AccessPolicy {
        let interval = DateInterval(start: baseDate, duration: 86_400)
        return try AccessPolicy(
            id: id("60000000-0000-0000-0000-000000000001"),
            name: "Synthetic fixture agent",
            allowedInterval: interval,
            allowedBundleIDs: ["com.apple.Safari"],
            allowedHosts: ["example.com"],
            allowImageResources: false,
            maxResults: 25,
            expiresAt: interval.end.addingTimeInterval(3_600),
            createdByUser: true
        )
    }

    static func producer(_ name: String, hashByte: UInt8) throws -> ProducerVersion {
        try ProducerVersion(name: name, semanticVersion: "1.0.0", modelHash: digest(hashByte))
    }

    static func write<Value>(_ value: Value, named name: String, into directory: URL) throws
    where Value: Encodable & ContractValidatable {
        try ContractJSON.encode(value).write(
            to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func id(_ value: String) -> UUID {
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("invalid fixture UUID")
        }
        return identifier
    }

    static func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    enum GeneratorError: Error {
        case usage
    }
}
