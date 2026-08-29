import Combine
import Foundation
import MemoryContracts

public protocol SearchEngine: Sendable {
    func search(_ request: SearchRequest) async throws -> SearchPage
}

extension LexicalSearchEngine: SearchEngine {}

public struct SearchSessionInput: Equatable, Sendable {
    public let query: String
    public let interval: DateInterval?
    public let bundleIDs: Set<String>
    public let hosts: Set<String>

    public init(
        query: String,
        interval: DateInterval? = nil,
        bundleIDs: Set<String> = [],
        hosts: Set<String> = []
    ) {
        self.query = query
        self.interval = interval
        self.bundleIDs = bundleIDs
        self.hosts = hosts
    }

    public var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && interval == nil
            && bundleIDs.isEmpty
            && hosts.isEmpty
    }
}

public enum SearchSessionPhase: Equatable, Sendable {
    case idle
    case debouncing(query: String)
    case loading(query: String)
    case results(query: String, count: Int)
    case empty(query: String)
    case failure(query: String, diagnosticCode: String)

    public var isSettled: Bool {
        switch self {
        case .results, .empty, .failure: true
        case .idle, .debouncing, .loading: false
        }
    }
}

@MainActor
public final class SearchSessionModel: ObservableObject {
    public typealias RequestBuilder = @Sendable (SearchSessionInput) throws -> SearchRequest
    public typealias PageRequestBuilder =
        @Sendable (SearchSessionInput, SearchCursor?) throws
        -> SearchRequest

    @Published public private(set) var query: String
    @Published public private(set) var input: SearchSessionInput
    @Published public private(set) var phase: SearchSessionPhase
    @Published public private(set) var results: [SearchResult]
    @Published public private(set) var nextCursor: SearchCursor?
    @Published public private(set) var settledQuery: String?
    @Published public private(set) var settlementCount = 0
    @Published public private(set) var isLoadingNextPage = false
    @Published public private(set) var paginationFailureDiagnosticCode: String?

    public let thumbnailRepository: SearchThumbnailRepository?

    private let engine: any SearchEngine
    private let requestBuilder: RequestBuilder
    private let pageRequestBuilder: PageRequestBuilder?
    private let debounceDuration: Duration
    private let initialPage: SearchPage?
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    public init(
        engine: any SearchEngine,
        debounceDuration: Duration = .milliseconds(150),
        initialPage: SearchPage? = nil,
        thumbnailRepository: SearchThumbnailRepository? = nil,
        requestBuilder: @escaping RequestBuilder
    ) {
        self.engine = engine
        self.debounceDuration = debounceDuration
        self.initialPage = initialPage
        self.thumbnailRepository = thumbnailRepository
        self.requestBuilder = requestBuilder
        pageRequestBuilder = nil
        input = SearchSessionInput(query: "")
        query = ""
        results = initialPage?.results ?? []
        nextCursor = initialPage?.nextCursor
        phase = initialPage.map { .results(query: "", count: $0.results.count) } ?? .idle
    }

    public init(
        engine: any SearchEngine,
        debounceDuration: Duration = .milliseconds(150),
        initialPage: SearchPage? = nil,
        thumbnailRepository: SearchThumbnailRepository? = nil,
        pageRequestBuilder: @escaping PageRequestBuilder
    ) {
        self.engine = engine
        self.debounceDuration = debounceDuration
        self.initialPage = initialPage
        self.thumbnailRepository = thumbnailRepository
        requestBuilder = { input in try pageRequestBuilder(input, nil) }
        self.pageRequestBuilder = pageRequestBuilder
        input = SearchSessionInput(query: "")
        query = ""
        results = initialPage?.results ?? []
        nextCursor = initialPage?.nextCursor
        phase = initialPage.map { .results(query: "", count: $0.results.count) } ?? .idle
    }

    public convenience init(
        engine: any SearchEngine,
        debounceDuration: Duration = .milliseconds(150),
        initialPage: SearchPage? = nil,
        thumbnailRepository: SearchThumbnailRepository? = nil,
        requestBuilder: @escaping @Sendable (String) throws -> SearchRequest
    ) {
        self.init(
            engine: engine,
            debounceDuration: debounceDuration,
            initialPage: initialPage,
            thumbnailRepository: thumbnailRepository,
            requestBuilder: { input in try requestBuilder(input.query) }
        )
    }

    public func updateQuery(_ value: String) {
        updateInput(
            SearchSessionInput(
                query: value,
                interval: input.interval,
                bundleIDs: input.bundleIDs,
                hosts: input.hosts
            )
        )
    }

    public func updateInput(_ value: SearchSessionInput) {
        guard input != value else { return }
        input = value
        query = value.query
        generation += 1
        searchTask?.cancel()
        isLoadingNextPage = false
        paginationFailureDiagnosticCode = nil
        let normalized = value.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            results = initialPage?.results ?? []
            nextCursor = initialPage?.nextCursor
            settledQuery = nil
            phase = initialPage.map { .results(query: "", count: $0.results.count) } ?? .idle
            return
        }

        let requestGeneration = generation
        results = []
        nextCursor = nil
        settledQuery = nil
        phase = .debouncing(query: normalized)
        let debounceDuration = debounceDuration
        let engine = engine
        let requestBuilder = requestBuilder
        let requestInput = SearchSessionInput(
            query: normalized,
            interval: value.interval,
            bundleIDs: value.bundleIDs,
            hosts: value.hosts
        )
        searchTask = Task { [weak self] in
            do {
                if debounceDuration > .zero {
                    try await Task.sleep(for: debounceDuration)
                }
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration else { return }
                self.phase = .loading(query: normalized)
                let request = try requestBuilder(requestInput)
                let page = try await engine.search(request)
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }
                self.settle(page: page, query: normalized, generation: requestGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == requestGeneration else { return }
                self.settleFailure(query: normalized, generation: requestGeneration)
            }
        }
    }

    public func waitForCurrentSearch() async {
        await searchTask?.value
    }

    public func loadNextPage() async {
        guard !isLoadingNextPage,
            let cursor = nextCursor,
            let pageRequestBuilder,
            settledQuery != nil
        else {
            return
        }
        let pageGeneration = generation
        let pageInput = input
        isLoadingNextPage = true
        paginationFailureDiagnosticCode = nil
        defer {
            if generation == pageGeneration {
                isLoadingNextPage = false
            }
        }
        do {
            let request = try pageRequestBuilder(pageInput, cursor)
            let page = try await engine.search(request)
            try Task.checkCancellation()
            guard generation == pageGeneration else { return }
            var seen = Set(results.map(\.frameID))
            results.append(contentsOf: page.results.filter { seen.insert($0.frameID).inserted })
            nextCursor = page.nextCursor
            phase = .results(query: settledQuery ?? pageInput.query, count: results.count)
        } catch is CancellationError {
            return
        } catch {
            guard generation == pageGeneration else { return }
            paginationFailureDiagnosticCode = "LM-SEARCH-PAGE"
        }
    }

    private func settle(page: SearchPage, query: String, generation: Int) {
        guard self.generation == generation, settledQuery == nil else { return }
        results = page.results
        nextCursor = page.nextCursor
        settledQuery = query
        settlementCount += 1
        phase =
            page.results.isEmpty
            ? .empty(query: query)
            : .results(query: query, count: page.results.count)
    }

    private func settleFailure(query: String, generation: Int) {
        guard self.generation == generation, settledQuery == nil else { return }
        results = []
        nextCursor = nil
        settledQuery = query
        settlementCount += 1
        phase = .failure(query: query, diagnosticCode: "LM-SEARCH-QUERY")
    }
}
