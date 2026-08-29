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
        return SearchSessionModel(
            engine: engine,
            thumbnailRepository: thumbnailRepository,
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
        let loader = SearchThumbnailLoader { result in
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
            let decoded = try codec.decode(bytes)
            return try SearchThumbnailRaster(
                width: decoded.raster.width,
                height: decoded.raster.height,
                rgba8: decoded.raster.rgba8
            )
        }
        return SearchThumbnailRepository(
            capacityBytes: 64 * 1_024 * 1_024,
            loader: loader
        )
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
            diagnosticsEnabled: diagnosticsEnabled,
            pageRequestBuilder: fixtureRequest
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
