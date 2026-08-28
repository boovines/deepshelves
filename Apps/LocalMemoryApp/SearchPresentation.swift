import Foundation
import MemoryContracts
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
        fixtureMode: AppSearchFixtureMode?
    ) -> SearchSessionModel {
        if let fixtureMode {
            return makeFixtureModel(mode: fixtureMode)
        }
        let modelService = MobileCLIPModelService.bundled()
        guard let database,
            let lexical = try? LexicalSearchEngine(
                database: database,
                cursorSigningKey: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
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
            )
        else {
            return SearchSessionModel(
                engine: UnavailableAppSearchEngine(),
                requestBuilder: { _ in throw AppSearchCompositionError.archiveUnavailable }
            )
        }
        let engine = LocalSearchEngine(lexical: lexical, visual: visual)
        let policyID = UUID()
        return SearchSessionModel(engine: engine) { query in
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
                query: query,
                interval: nil,
                bundleIDs: [],
                hosts: [],
                mode: .textOnly,
                pageSize: 50,
                cursor: nil,
                accessPolicy: policy
            )
        }
    }

    private static func makeFixtureModel(mode: AppSearchFixtureMode) -> SearchSessionModel {
        let page = try! SearchPage(results: fixtureResults, nextCursor: nil)
        return SearchSessionModel(
            engine: AppSearchFixtureEngine(mode: mode, results: page.results),
            debounceDuration: .milliseconds(150),
            initialPage: page,
            requestBuilder: fixtureRequest
        )
    }

    nonisolated private static func fixtureRequest(_ query: String) throws -> SearchRequest {
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
            query: query,
            interval: nil,
            bundleIDs: [],
            hosts: [],
            mode: .textOnly,
            pageSize: 20,
            cursor: nil,
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

struct SharedSearchResultsView: View {
    @ObservedObject var searchModel: SearchSessionModel
    @ObservedObject var navigationModel: MainNavigationViewModel
    let surface: SearchResultSurface
    @FocusState private var focusedResultID: UUID?

    var body: some View {
        Group {
            switch searchModel.phase {
            case .idle:
                ContentUnavailableView(
                    "Search your local memory",
                    systemImage: "magnifyingglass",
                    description: Text("Enter text from the foreground window you remember.")
                )
            case .debouncing(let query), .loading(let query):
                ProgressView("Searching for “\(query)” locally…")
                    .accessibilityIdentifier("search.loading")
            case .results:
                List(Array(searchModel.results.enumerated()), id: \.element.frameID) {
                    index, result in
                    Button {
                        focusedResultID = result.frameID
                        navigationModel.select(section: .search)
                        navigationModel.select(momentID: result.frameID)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.and.text.magnifyingglass")
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    result.foreground.windowTitle
                                        ?? result.foreground.applicationName
                                )
                                .font(.headline)
                                Text(resultSubtitle(result))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if navigationModel.snapshot.selectedMomentID == result.frameID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Selected")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedResultID, equals: result.frameID)
                    .accessibilityLabel(accessibilityLabel(result, index: index))
                    .accessibilityHint("Open moment detail")
                    .accessibilityIdentifier(surface.accessibilityIdentifier(for: result))
                }
                .listStyle(.inset)
            case .empty(let query):
                ContentUnavailableView.search(text: query)
                    .accessibilityIdentifier("search.empty")
            case .failure(_, let diagnosticCode):
                VStack(spacing: 8) {
                    ContentUnavailableView(
                        "Search unavailable",
                        systemImage: "exclamationmark.magnifyingglass",
                        description: Text("Your archive was not changed.")
                    )
                    Text("Diagnostic code: \(diagnosticCode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("search.errorCode")
                }
                .accessibilityIdentifier("search.error")
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .shellRestoreSelectedMomentFocus)
        ) { _ in
            let selected = navigationModel.snapshot.selectedMomentID
            focusedResultID = nil
            Task { @MainActor in
                await Task.yield()
                focusedResultID = selected
            }
        }
    }

    private func resultSubtitle(_ result: SearchResult) -> String {
        let time = result.capturedAt.formatted(date: .omitted, time: .shortened)
        let host = result.browser.map { " · \($0.origin.host)" } ?? ""
        return "\(result.foreground.applicationName) · \(time)\(host)"
    }

    private func accessibilityLabel(_ result: SearchResult, index: Int) -> String {
        let source = result.evidence.first?.source.rawValue ?? "source evidence"
        return "\(resultSubtitle(result)), \(source), \(index + 1) of \(searchModel.results.count)"
    }
}
