import Combine
import Foundation
import MemoryContracts

public protocol SearchEngine: Sendable {
    func search(_ request: SearchRequest) async throws -> SearchPage
}

extension LexicalSearchEngine: SearchEngine {}

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
    public typealias RequestBuilder = @Sendable (String) throws -> SearchRequest

    @Published public private(set) var query: String
    @Published public private(set) var phase: SearchSessionPhase
    @Published public private(set) var results: [SearchResult]
    @Published public private(set) var nextCursor: SearchCursor?
    @Published public private(set) var settledQuery: String?
    @Published public private(set) var settlementCount = 0

    private let engine: any SearchEngine
    private let requestBuilder: RequestBuilder
    private let debounceDuration: Duration
    private let initialPage: SearchPage?
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    public init(
        engine: any SearchEngine,
        debounceDuration: Duration = .milliseconds(150),
        initialPage: SearchPage? = nil,
        requestBuilder: @escaping RequestBuilder
    ) {
        self.engine = engine
        self.debounceDuration = debounceDuration
        self.initialPage = initialPage
        self.requestBuilder = requestBuilder
        query = ""
        results = initialPage?.results ?? []
        nextCursor = initialPage?.nextCursor
        phase = initialPage.map { .results(query: "", count: $0.results.count) } ?? .idle
    }

    public func updateQuery(_ value: String) {
        guard query != value else { return }
        query = value
        generation += 1
        searchTask?.cancel()
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
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
        searchTask = Task { [weak self] in
            do {
                if debounceDuration > .zero {
                    try await Task.sleep(for: debounceDuration)
                }
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration else { return }
                self.phase = .loading(query: normalized)
                let request = try requestBuilder(normalized)
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
