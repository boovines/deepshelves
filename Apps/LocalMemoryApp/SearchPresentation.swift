import AppKit
import CryptoKit
import Foundation
import MemoryContracts
import MemoryDesignSystem
import MemoryEnrichment
import MemorySearch
import MemoryStore
import SwiftUI

enum AppSearchFixtureMode: String {
    case warm
    case slow
    case error
}

private enum AppSearchCompositionError: Error {
    case archiveUnavailable
    case fixtureFailure
}

@MainActor
enum AppSearchComposition {
    static func makeModel(
        database: ArchiveDatabase?,
        fixtureMode: AppSearchFixtureMode?,
        diagnosticsEnabled: Bool
    ) -> SearchSessionModel {
        if let fixtureMode {
            return makeFixtureModel(
                mode: fixtureMode,
                diagnosticsEnabled: diagnosticsEnabled
            )
        }
        let modelService = MobileCLIPModelService.bundled()
        let cursorSigningKey = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        guard let database,
            let lexical = try? LexicalSearchEngine(
                database: database,
                cursorSigningKey: cursorSigningKey
            ),
            let model = try? VisualEmbeddingProducerIdentity.archiveVectorModel(),
            let embedder = try? VisualQueryEmbeddingProvider(
                modelHash: model.modelHash,
                dimension: model.dimension,
                operation: { query in
                    try await modelService.embed(text: query)
                }
            ),
            let visual = try? VisualSearchEngine(
                database: database,
                model: model,
                embedder: embedder
            ),
            let hybrid = try? HybridSearchEngine(
                lexical: lexical,
                visual: visual,
                cursorSigningKey: cursorSigningKey,
                groupingProvider: groupingProvider(database: database)
            )
        else {
            return SearchSessionModel(
                engine: UnavailableAppSearchEngine(),
                diagnosticsEnabled: diagnosticsEnabled,
                requestBuilder: { (_: SearchSessionInput) in
                    throw AppSearchCompositionError.archiveUnavailable
                }
            )
        }
        let engine = LocalSearchEngine(lexical: lexical, visual: visual, hybrid: hybrid)
        let policyID = UUID()
        let thumbnailRepository = makeThumbnailRepository(database: database)
        let momentDetailRepository = makeMomentDetailRepository(database: database)
        let momentExportProvider = makeMomentExportProvider(database: database)
        let momentTimelineLoader = makeMomentTimelineLoader(database: database)
        let momentRevisitProvider = makeMomentRevisitProvider(database: database)
        let momentForgetProvider = makeMomentForgetProvider(database: database)
        return SearchSessionModel(
            engine: engine,
            thumbnailRepository: thumbnailRepository,
            momentDetailRepository: momentDetailRepository,
            momentExportProvider: momentExportProvider,
            momentTimelineLoader: momentTimelineLoader,
            momentRevisitProvider: momentRevisitProvider,
            momentForgetProvider: momentForgetProvider,
            diagnosticsEnabled: diagnosticsEnabled,
            pageRequestBuilder: { (input: SearchSessionInput, cursor: SearchCursor?) in
                let now = Date()
                let interval = DateInterval(
                    start: now.addingTimeInterval(-30 * 24 * 60 * 60),
                    end: now
                )
                let scope = try database.localSearchScope()
                let policy = try AccessPolicy(
                    id: policyID,
                    name: "Local Search UI session",
                    allowedInterval: interval,
                    allowedBundleIDs: scope.bundleIdentifiers,
                    allowedHosts: scope.hosts,
                    allowImageResources: true,
                    maxResults: 100,
                    expiresAt: now.addingTimeInterval(24 * 60 * 60),
                    createdByUser: true
                )
                return try SearchRequest(
                    query: input.query,
                    interval: input.interval,
                    bundleIDs: input.bundleIDs,
                    hosts: input.hosts,
                    mode: .hybrid,
                    pageSize: 50,
                    cursor: cursor,
                    accessPolicy: policy
                )
            }
        )
    }

    static func makeFilterModel(
        searchModel: SearchSessionModel,
        database: ArchiveDatabase?,
        fixtureMode: AppSearchFixtureMode?
    ) -> SearchFilterSessionModel {
        let applications: [SearchApplicationDescriptor]
        let hosts: [String]
        if fixtureMode != nil {
            applications = [
                SearchApplicationDescriptor(
                    bundleID: "com.apple.Calendar",
                    displayName: "Calendar"
                ),
                SearchApplicationDescriptor(
                    bundleID: "com.apple.Safari",
                    displayName: "Safari"
                ),
                SearchApplicationDescriptor(
                    bundleID: "com.apple.Notes",
                    displayName: "Notes"
                ),
            ]
            hosts = ["calendar.example.test", "example.test", "notes.example.test"]
        } else if let database, let scope = try? database.localSearchScope() {
            applications = scope.applications.map {
                SearchApplicationDescriptor(
                    bundleID: $0.bundleIdentifier,
                    displayName: $0.displayName
                )
            }
            hosts = scope.hosts.sorted()
        } else {
            applications = []
            hosts = []
        }
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = Locale.autoupdatingCurrent
        let catalog = SearchFilterCatalog(applications: applications, hosts: hosts)
        let referenceDate = Date()
        let context =
            (try? QueryParserContext(
                referenceDate: referenceDate,
                calendar: calendar,
                applications: catalog.parserApplications(locale: calendar.locale)
            ))
            ?? QueryParserContext.emptyFailClosed(
                referenceDate: referenceDate,
                calendar: calendar
            )
        return SearchFilterSessionModel(
            searchModel: searchModel,
            parserContext: context,
            catalog: catalog
        )
    }

    private static func groupingProvider(database: ArchiveDatabase)
        -> HybridGroupingMetadataProvider
    {
        let store = ArchiveHybridGroupingStore(database: database)
        return HybridGroupingMetadataProvider { frameIDs in
            Dictionary(
                uniqueKeysWithValues: try store.records(frameIDs: frameIDs).values.map { record in
                    (
                        record.frameID,
                        HybridGroupingMetadata(
                            frameID: record.frameID,
                            captureEpochID: record.captureEpochID,
                            captureReason: record.captureReason,
                            mediaSHA256: record.mediaSHA256,
                            approvedText: record.approvedText
                        )
                    )
                }
            )
        }
    }

    private static func makeThumbnailRepository(
        database: ArchiveDatabase
    ) -> SearchThumbnailRepository? {
        guard let fileStore = database.fileStore,
            let codec = try? SoftwareThumbnailHEICCodec()
        else {
            return nil
        }
        let metadata = ArchiveVisualEmbeddingStore(database: database)
        let validator = SearchThumbnailValidator { result in
            _ = try verifiedThumbnailBytes(
                result: result,
                fileStore: fileStore,
                metadata: metadata
            )
        }
        let loader = SearchThumbnailLoader { result in
            let bytes = try verifiedThumbnailBytes(
                result: result,
                fileStore: fileStore,
                metadata: metadata
            )
            let decoded = try codec.decode(bytes)
            return try SearchThumbnailRaster(
                width: decoded.raster.width,
                height: decoded.raster.height,
                rgba8: decoded.raster.rgba8
            )
        }
        return SearchThumbnailRepository(
            capacityBytes: 64 * 1_024 * 1_024,
            validator: validator,
            loader: loader
        )
    }

    nonisolated private static func verifiedThumbnailBytes(
        result: SearchResult,
        fileStore: ArchiveFileStore,
        metadata: ArchiveVisualEmbeddingStore
    ) throws -> Data {
        guard case .archiveRelativePath(let value)? = result.thumbnailLocator else {
            throw SearchThumbnailError.unavailable
        }
        let requestedPath = try ArchiveRelativePath(value)
        let record = try metadata.readyThumbnail(frameID: result.frameID)
        guard record.thumbnailPath == requestedPath else {
            throw SearchThumbnailError.unavailable
        }
        let fileURL = fileStore.url(for: requestedPath)
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SearchThumbnailError.unavailable
        }
        let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard Data(SHA256.hash(data: bytes)) == record.thumbnailHash else {
            throw SearchThumbnailError.unavailable
        }
        return bytes
    }

    private static func makeMomentDetailRepository(
        database: ArchiveDatabase
    ) -> MomentDetailRepository? {
        guard let fileStore = database.fileStore,
            let codec = try? SoftwareThumbnailHEICCodec()
        else {
            return nil
        }
        let sourceStore = ArchiveMomentSourceStore(database: database)
        let loader = MomentDetailLoader { result in
            let mediaBytes = try verifiedMomentBytes(
                result: result,
                fileStore: fileStore,
                sourceStore: sourceStore
            )
            do {
                let decoded = try codec.decode(mediaBytes)
                return try MomentDetailRaster(
                    width: decoded.raster.width,
                    height: decoded.raster.height,
                    rgba8: decoded.raster.rgba8
                )
            } catch {
                throw MomentDetailError.corruptMedia
            }
        }
        return MomentDetailRepository(
            capacityBytes: 256 * 1_024 * 1_024,
            validator: MomentDetailValidator { result in
                _ = try verifiedMomentBytes(
                    result: result,
                    fileStore: fileStore,
                    sourceStore: sourceStore
                )
            },
            loader: loader
        )
    }

    private static func makeMomentExportProvider(
        database: ArchiveDatabase
    ) -> MomentExportProvider? {
        guard let fileStore = database.fileStore,
            let maintenance = try? ArchiveMaintenanceCoordinator(database: database)
        else { return nil }
        let sourceStore = ArchiveMomentSourceStore(database: database)
        return MomentExportProvider { result in
            let bytes = try verifiedMomentBytes(
                result: result,
                fileStore: fileStore,
                sourceStore: sourceStore
            )
            let host = result.browser?.origin.host
            let scope = try ArchiveExportScope(
                selectedFrameIDs: [result.frameID],
                allowedInterval: DateInterval(
                    start: result.capturedAt,
                    end: result.capturedAt.addingTimeInterval(0.001)
                ),
                allowedBundleIdentifiers: [result.foreground.bundleID],
                allowedHosts: host.map { Set([$0]) } ?? [],
                includeOriginalEvidence: true,
                confirmedByUser: true
            )
            let receipt = try maintenance.export(scope: scope)
            return MomentExportPayload(
                frameID: result.frameID,
                suggestedFilename: "moment-\(result.frameID.uuidString.lowercased()).heic",
                heicData: bytes,
                packageRoot: receipt.root
            )
        }
    }

    private static func makeMomentTimelineLoader(
        database: ArchiveDatabase
    ) -> MomentTimelinePageLoader {
        let query = ArchiveTimelineQuery(database: database)
        let sourceStore = ArchiveMomentSourceStore(database: database)
        let calendarTimeZone = TimeZone.autoupdatingCurrent
        return MomentTimelinePageLoader { request in
            let horizon = 400.0 * 24 * 60 * 60
            let page = try query.page(
                TimelinePageRequest(
                    interval: DateInterval(
                        start: request.cursor.addingTimeInterval(-horizon),
                        end: request.cursor.addingTimeInterval(horizon)
                    ),
                    cursor: request.cursor,
                    zoom: archiveZoom(request.zoom),
                    calendarTimeZone: calendarTimeZone
                )
            )
            let results = try page.slice.frames.map { frame in
                let source = try sourceStore.readySource(frameID: frame.frameID)
                return try SearchResult(
                    frameID: frame.frameID,
                    capturedAt: frame.capturedAt,
                    foreground: frame.foreground,
                    browser: frame.browser,
                    thumbnailLocator: frame.thumbnailLocator,
                    mediaLocator: .archiveRelativePath(source.mediaPath.rawValue),
                    evidence: [
                        SearchEvidence(
                            source: .application,
                            matchedText: frame.foreground.applicationName,
                            score: 0
                        )
                    ],
                    textRank: nil,
                    visualRank: nil,
                    fusedScore: 0
                )
            }
            return MomentTimelineSourcePage(
                slice: page.slice,
                results: results,
                previousCursor: page.previousCursor?.start,
                nextCursor: page.nextCursor?.start
            )
        }
    }

    private static func makeMomentRevisitProvider(
        database: ArchiveDatabase
    ) -> MomentRevisitProvider {
        let sourceStore = ArchiveMomentSourceStore(database: database)
        return MomentRevisitProvider { result in
            _ = try sourceStore.readySource(frameID: result.frameID)
            let currentScope = try database.localSearchScope()
            let now = Date()
            let plan = try MomentRevisitPlanner.plan(
                result: result,
                scope: MomentRevisitScope(
                    allowedInterval: DateInterval(
                        start: now.addingTimeInterval(-400 * 24 * 60 * 60),
                        end: now.addingTimeInterval(1)
                    ),
                    allowedBundleIDs: currentScope.bundleIdentifiers,
                    allowedHosts: currentScope.hosts
                )
            )
            guard
                let applicationURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: plan.applicationBundleID
                )
            else {
                throw MomentRevisitError.unavailable
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.arguments = []
            configuration.environment = [:]
            if let approvedURL = plan.approvedURL {
                _ = try await NSWorkspace.shared.open(
                    [approvedURL],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                )
            } else {
                _ = try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
            }
            return plan
        }
    }

    private static func makeMomentForgetProvider(
        database: ArchiveDatabase
    ) -> MomentForgetProvider {
        let worker = try? ArchiveDeletionRewriteWorker(
            database: database,
            vectorCompactor: ArchiveDeletionVectorCompactionComposition.make(database: database)
        )
        if let worker {
            Task.detached(priority: .utility) {
                _ = try? worker.recoverPending()
            }
        }
        return MomentForgetProvider { target in
            guard let worker else {
                throw AppSearchCompositionError.archiveUnavailable
            }
            let archiveTarget: ArchiveDeletionTarget
            switch target {
            case .moment(let frameID):
                archiveTarget = .moment(frameID)
            case .range(let interval):
                archiveTarget = .range(interval)
            }
            let store = try ArchiveDeletionRequestStore(database: database)
            let operation = try store.request(
                ArchiveDeletionRequest(
                    id: UUID(),
                    target: archiveTarget,
                    requestedAt: Date(),
                    rewriteJobID: UUID(),
                    auditEventID: UUID()
                )
            )
            do {
                _ = try await Task.detached(priority: .utility) {
                    try worker.process(tombstoneID: operation.tombstone.id)
                }.value
            } catch {
                return ForgetOperation(
                    id: operation.tombstone.id,
                    affectedFrameIDs: operation.tombstone.requestedFrameIDs,
                    state: .failed,
                    completedRewriteCount: 0,
                    totalRewriteCount: operation.totalRewriteCount,
                    failureCode: "rewrite_pending_recovery"
                )
            }
            let current = try store.operation(id: operation.tombstone.id) ?? operation
            return ForgetOperation(
                id: current.tombstone.id,
                affectedFrameIDs: current.tombstone.requestedFrameIDs,
                state: forgetState(current.state),
                completedRewriteCount: current.completedRewriteCount,
                totalRewriteCount: current.totalRewriteCount,
                failureCode: current.failureCode
            )
        }
    }

    nonisolated private static func forgetState(
        _ state: ArchiveDeletionOperationState
    ) -> ForgetOperationState {
        switch state {
        case .queued: .queued
        case .rewriting: .rewriting
        case .verifying: .verifying
        case .complete: .complete
        case .failed: .failed
        }
    }

    nonisolated private static func archiveZoom(
        _ zoom: MomentTimelineZoomLevel
    ) -> TimelineZoomLevel {
        switch zoom {
        case .calendarDay: .calendarDay
        case .sixHours: .sixHours
        case .oneHour: .oneHour
        case .fifteenMinutes: .fifteenMinutes
        }
    }

    nonisolated private static func verifiedMomentBytes(
        result: SearchResult,
        fileStore: ArchiveFileStore,
        sourceStore: ArchiveMomentSourceStore
    ) throws -> Data {
        guard case .archiveRelativePath(let value) = result.mediaLocator,
            let expectedPath = try? ArchiveRelativePath(value)
        else {
            throw MomentDetailError.sourceUnavailable
        }
        let record: ArchiveMomentSourceRecord
        do {
            record = try sourceStore.readySource(
                frameID: result.frameID,
                expectedPath: expectedPath
            )
        } catch ArchiveMomentSourceError.locatorMismatch {
            throw MomentDetailError.manifestMismatch
        } catch {
            throw MomentDetailError.sourceUnavailable
        }
        let mediaBytes = try verifiedBytes(
            at: fileStore.url(for: record.mediaPath),
            expectedHash: record.mediaHash,
            expectedByteCount: record.mediaByteCount
        )
        let manifestBytes = try verifiedBytes(
            at: fileStore.url(for: record.manifestPath),
            expectedHash: record.manifestHash,
            expectedByteCount: nil
        )
        let manifest: HEICKeyframeManifest
        do {
            manifest = try ContractJSON.decode(
                HEICKeyframeManifest.self,
                from: manifestBytes
            )
        } catch {
            throw MomentDetailError.manifestMismatch
        }
        guard manifest.captureEpochID == record.captureEpochID,
            manifest.targetWindowID == record.targetWindowID,
            let entry = manifest.frames.first(where: { $0.frameID == result.frameID })
        else {
            throw MomentDetailError.manifestMismatch
        }
        let archivePath: String
        do {
            archivePath = try entry.archiveRelativePath(
                chunkManifestPath: record.manifestPath.rawValue
            )
        } catch {
            throw MomentDetailError.manifestMismatch
        }
        guard archivePath == record.mediaPath.rawValue,
            entry.sha256 == record.mediaHash,
            entry.byteCount == Int64(record.mediaByteCount)
        else {
            throw MomentDetailError.manifestMismatch
        }
        return mediaBytes
    }

    nonisolated private static func verifiedBytes(
        at fileURL: URL,
        expectedHash: Data,
        expectedByteCount: Int?
    ) throws -> Data {
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MomentDetailError.sourceUnavailable
        }
        let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard expectedByteCount.map({ $0 == bytes.count }) ?? true,
            Data(SHA256.hash(data: bytes)) == expectedHash
        else {
            throw MomentDetailError.integrityMismatch
        }
        return bytes
    }

    private static func makeFixtureModel(
        mode: AppSearchFixtureMode,
        diagnosticsEnabled: Bool
    ) -> SearchSessionModel {
        let page = try! SearchPage(results: fixtureResults, nextCursor: nil)
        return SearchSessionModel(
            engine: AppSearchFixtureEngine(mode: mode, results: page.results),
            debounceDuration: .milliseconds(150),
            initialPage: page,
            momentTimelineLoader: makeFixtureTimelineLoader(),
            momentRevisitProvider: MomentRevisitProvider { _ in
                throw MomentRevisitError.unavailable
            },
            diagnosticsEnabled: diagnosticsEnabled,
            pageRequestBuilder: fixtureRequest
        )
    }

    private static func makeFixtureTimelineLoader() -> MomentTimelinePageLoader {
        let source = try? fixtureTimelineSourcePage(results: fixtureResults)
        return MomentTimelinePageLoader { _ in
            guard let source else { throw MomentTimelineError.unavailable }
            return source
        }
    }

    nonisolated private static func fixtureTimelineSourcePage(
        results unsortedResults: [SearchResult]
    ) throws -> MomentTimelineSourcePage {
        let results = unsortedResults.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = results.first, let last = results.last else {
            throw MomentTimelineError.unavailable
        }
        let interval = DateInterval(
            start: first.capturedAt.addingTimeInterval(-60 * 60),
            end: last.capturedAt.addingTimeInterval(60 * 60)
        )
        let frames = try results.map { result in
            try TimelineFrameSummary(
                frameID: result.frameID,
                capturedAt: result.capturedAt,
                foreground: result.foreground,
                browser: result.browser,
                thumbnailLocator: result.thumbnailLocator
            )
        }
        let transitions = try zip(results, results.dropFirst()).map { previous, current in
            try ApplicationTransition(
                occurredAt: current.capturedAt,
                fromBundleID: previous.foreground.bundleID,
                toBundleID: current.foreground.bundleID
            )
        }
        let gapStart = first.capturedAt.addingTimeInterval(30 * 60)
        let gap = try RecordingGap(
            startedAt: gapStart,
            endedAt: gapStart.addingTimeInterval(10 * 60),
            reason: .excluded,
            approvedBundleID: nil
        )
        return MomentTimelineSourcePage(
            slice: try TimelineSlice(
                interval: interval,
                frames: frames,
                gaps: [gap],
                applicationTransitions: transitions,
                transcriptMarkers: []
            ),
            results: results,
            previousCursor: nil,
            nextCursor: nil
        )
    }

    nonisolated private static func fixtureRequest(
        _ input: SearchSessionInput,
        _ cursor: SearchCursor?
    ) throws -> SearchRequest {
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let interval = DateInterval(
            start: now.addingTimeInterval(-30 * 24 * 60 * 60),
            end: now
        )
        let policy = try AccessPolicy(
            id: UUID(uuidString: "39000000-0000-0000-0000-000000000039")!,
            name: "LM-039 UI fixture",
            allowedInterval: interval,
            allowedBundleIDs: [
                "com.apple.Calendar",
                "com.apple.Safari",
                "com.apple.Notes",
            ],
            allowedHosts: ["calendar.example.test", "example.test", "notes.example.test"],
            maxResults: 20,
            expiresAt: now.addingTimeInterval(24 * 60 * 60),
            createdByUser: true
        )
        return try SearchRequest(
            query: input.query,
            interval: input.interval,
            bundleIDs: input.bundleIDs,
            hosts: input.hosts,
            mode: .textOnly,
            pageSize: 20,
            cursor: cursor,
            accessPolicy: policy
        )
    }

    private static let fixtureResults: [SearchResult] = [
        fixtureResult(
            id: "00000000-0000-4000-8000-000000000101",
            title: "Morning planning",
            application: "Calendar",
            bundleID: "com.apple.Calendar",
            host: "calendar.example.test",
            hour: 9,
            minute: 12,
            score: 8
        ),
        fixtureResult(
            id: "00000000-0000-4000-8000-000000000102",
            title: "Afternoon research",
            application: "Safari",
            bundleID: "com.apple.Safari",
            host: "example.test",
            hour: 14,
            minute: 14,
            score: 7
        ),
        fixtureResult(
            id: "00000000-0000-4000-8000-000000000103",
            title: "Evening notes",
            application: "Notes",
            bundleID: "com.apple.Notes",
            host: "notes.example.test",
            hour: 17,
            minute: 42,
            score: 6
        ),
    ]

    private static func fixtureResult(
        id: String,
        title: String,
        application: String,
        bundleID: String,
        host: String,
        hour: Int,
        minute: Int,
        score: Double
    ) -> SearchResult {
        let base = Date(timeIntervalSince1970: 1_777_000_000)
        return try! SearchResult(
            frameID: UUID(uuidString: id)!,
            capturedAt: Calendar(identifier: .gregorian).date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: base
            )!,
            foreground: ForegroundContext(
                bundleID: bundleID,
                applicationName: application,
                processID: nil,
                windowTitle: title,
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: BrowserContext(
                family: .safari,
                origin: BrowserOrigin(scheme: "https", host: host, path: nil),
                isPrivateContext: false
            ),
            thumbnailLocator: nil,
            mediaLocator: .opaqueResourceID("lm039-\(id)"),
            evidence: [SearchEvidence(source: .title, matchedText: title, score: score)],
            textRank: Int(9 - score),
            visualRank: nil,
            fusedScore: score
        )
    }
}

struct SharedSearchFilterControls: View {
    @ObservedObject var filterModel: SearchFilterSessionModel

    private var suggestions: [SearchAutocompleteSuggestion] {
        filterModel.autocompleteSuggestions(for: filterModel.queryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !filterModel.tokens.isEmpty {
                FilterTokenBar(
                    tokens: filterModel.tokens.map { token in
                        FilterTokenModel(
                            id: token.id,
                            label: token.label,
                            systemImage: systemImage(for: token.kind)
                        )
                    },
                    onActivate: { filterModel.removeFilter(id: $0.id) }
                )
                .accessibilityIdentifier("search.activeFilters")
            }

            HStack(spacing: 8) {
                Menu {
                    if filterModel.catalog.applications.isEmpty {
                        Text("No approved applications indexed")
                    } else {
                        ForEach(filterModel.catalog.applications, id: \.bundleID) { application in
                            Button(application.displayName) {
                                filterModel.applySuggestion(
                                    SearchAutocompleteSuggestion(
                                        kind: .application,
                                        label: application.displayName,
                                        canonicalValue: application.bundleID
                                    )
                                )
                            }
                        }
                    }
                } label: {
                    Label("Apps", systemImage: "app")
                }
                .accessibilityIdentifier("search.appPicker")

                Menu {
                    if filterModel.catalog.hosts.isEmpty {
                        Text("No approved sites indexed")
                    } else {
                        ForEach(filterModel.catalog.hosts, id: \.self) { host in
                            Button(host) {
                                filterModel.applySuggestion(
                                    SearchAutocompleteSuggestion(
                                        kind: .site,
                                        label: host,
                                        canonicalValue: host
                                    )
                                )
                            }
                        }
                    }
                } label: {
                    Label("Sites", systemImage: "globe")
                }
                .accessibilityIdentifier("search.sitePicker")

                Menu {
                    Button("Today") { applyDay(offset: 0) }
                    Button("Yesterday") { applyDay(offset: -1) }
                    Button("Last 7 days") { applyLastSevenDays() }
                    if let timeToken = filterModel.tokens.first(where: { $0.kind == .time }) {
                        Divider()
                        Button("Clear date filter") {
                            filterModel.removeFilter(id: timeToken.id)
                        }
                    }
                } label: {
                    Label("Date", systemImage: "calendar")
                }
                .accessibilityIdentifier("search.datePicker")

                Spacer()
            }
            .controlSize(.small)

            if !suggestions.isEmpty {
                HStack(spacing: 8) {
                    Text("Suggestions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(suggestions) { suggestion in
                        Button(suggestion.label) {
                            filterModel.applySuggestion(suggestion)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Use \(suggestion.label) filter")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("search.autocomplete")
            }

            if filterModel.queryText.isEmpty, filterModel.tokens.isEmpty {
                HStack(spacing: 8) {
                    Text("Try")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(filterModel.queryExamples, id: \.self) { example in
                        Button(example) {
                            filterModel.updateQueryText(example)
                            filterModel.commitQuery()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Search example: \(example)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("search.examples")
            }
        }
    }

    private func systemImage(for kind: SearchQueryTokenKind) -> String {
        switch kind {
        case .application: "app"
        case .site: "globe"
        case .time: "calendar"
        }
    }

    private func applyDay(offset: Int) {
        let calendar = Calendar.autoupdatingCurrent
        guard let day = calendar.date(byAdding: .day, value: offset, to: Date()),
            let interval = calendar.dateInterval(of: .day, for: day)
        else {
            return
        }
        filterModel.setDateInterval(interval)
    }

    private func applyLastSevenDays() {
        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: startOfToday),
            let start = calendar.date(byAdding: .day, value: -7, to: end)
        else {
            return
        }
        filterModel.setDateInterval(DateInterval(start: start, end: end))
    }
}

private struct UnavailableAppSearchEngine: SearchEngine {
    func search(_ request: SearchRequest) async throws -> SearchPage {
        _ = request
        throw AppSearchCompositionError.archiveUnavailable
    }
}

private actor AppSearchFixtureEngine: SearchEngine {
    let mode: AppSearchFixtureMode
    let results: [SearchResult]

    init(mode: AppSearchFixtureMode, results: [SearchResult]) {
        self.mode = mode
        self.results = results
    }

    func search(_ request: SearchRequest) async throws -> SearchPage {
        switch mode {
        case .warm:
            try await Task.sleep(for: .milliseconds(10))
        case .slow:
            try await Task.sleep(for: .milliseconds(650))
        case .error:
            try await Task.sleep(for: .milliseconds(40))
            throw AppSearchCompositionError.fixtureFailure
        }
        let query = request.query.lowercased()
        let matches = results.filter {
            ($0.foreground.windowTitle ?? "").lowercased().contains(query)
                || $0.foreground.applicationName.lowercased().contains(query)
                || ($0.browser?.origin.host ?? "").lowercased().contains(query)
        }
        return try SearchPage(results: matches, nextCursor: nil)
    }
}

enum SearchResultSurface: Equatable {
    case main
    case panel

    func accessibilityIdentifier(for result: SearchResult) -> String {
        let identifier = result.frameID.uuidString.lowercased()
        guard self == .main else { return "search.result.\(identifier)" }
        switch identifier {
        case "00000000-0000-4000-8000-000000000101": return "moment.morning-planning"
        case "00000000-0000-4000-8000-000000000102": return "moment.afternoon-research"
        case "00000000-0000-4000-8000-000000000103": return "moment.evening-notes"
        default: return "main.search.result.\(identifier)"
        }
    }
}
