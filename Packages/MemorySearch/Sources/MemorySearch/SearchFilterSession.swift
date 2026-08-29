import Combine
import Foundation

public struct SearchFilterCatalog: Equatable, Sendable {
    public let applications: [SearchApplicationDescriptor]
    public let hosts: [String]

    public init(
        applications: [SearchApplicationDescriptor],
        hosts: [String]
    ) {
        self.applications = applications.sorted {
            ($0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending)
                || ($0.displayName == $1.displayName && $0.bundleID < $1.bundleID)
        }
        self.hosts = Array(Set(hosts.map(Self.normalizedHost))).filter { !$0.isEmpty }.sorted()
    }

    public func parserApplications(locale: Locale?) -> [SearchApplicationDescriptor] {
        let validApplications = applications.filter { application in
            !application.bundleID.isEmpty
                && application.bundleID.contains(".")
                && !application.displayName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                && application.aliases.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }
        let normalizedNames = validApplications.flatMap { application in
            ([application.displayName] + application.aliases).map {
                Self.normalizedApplicationName($0, locale: locale)
            }
        }
        let nameCounts = Dictionary(grouping: normalizedNames, by: { $0 }).mapValues(\.count)
        return validApplications.filter { application in
            ([application.displayName] + application.aliases).allSatisfy {
                nameCounts[Self.normalizedApplicationName($0, locale: locale)] == 1
            }
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedApplicationName(_ name: String, locale: Locale?) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        )
    }
}

extension SearchQueryToken: Identifiable {
    public var id: String { "\(kind.rawValue):\(canonicalValue)" }
}

public struct SearchAutocompleteSuggestion: Identifiable, Equatable, Sendable {
    public let kind: SearchQueryTokenKind
    public let label: String
    public let canonicalValue: String

    public init(kind: SearchQueryTokenKind, label: String, canonicalValue: String) {
        self.kind = kind
        self.label = label
        self.canonicalValue = canonicalValue
    }

    public var id: String { "\(kind.rawValue):\(canonicalValue)" }
}

public struct SearchFilterSnapshot: Codable, Equatable, Sendable {
    public let queryText: String
    public let tokens: [SearchQueryToken]
    public let applicationBundleIDs: [String]
    public let hosts: [String]
    public let interval: DateInterval?

    public init(
        queryText: String,
        tokens: [SearchQueryToken],
        applicationBundleIDs: [String],
        hosts: [String],
        interval: DateInterval?
    ) {
        self.queryText = queryText
        self.tokens = tokens
        self.applicationBundleIDs = applicationBundleIDs.sorted()
        self.hosts = hosts.sorted()
        self.interval = interval
    }
}

@MainActor
public final class SearchFilterSessionModel: ObservableObject {
    @Published public private(set) var queryText = ""
    @Published public private(set) var tokens: [SearchQueryToken] = []
    @Published public private(set) var applicationBundleIDs: Set<String> = []
    @Published public private(set) var hosts: Set<String> = []
    @Published public private(set) var interval: DateInterval?

    public let catalog: SearchFilterCatalog

    public var snapshot: SearchFilterSnapshot {
        SearchFilterSnapshot(
            queryText: queryText,
            tokens: tokens,
            applicationBundleIDs: Array(applicationBundleIDs),
            hosts: Array(hosts),
            interval: interval
        )
    }

    public var queryExamples: [String] {
        var examples = ["yellow lamp yesterday"]
        if let application = catalog.applications.first {
            examples.append("invoice app:\(application.displayName)")
        }
        if let host = catalog.hosts.first {
            examples.append("roadmap site:\(host)")
        }
        return examples
    }

    private let searchModel: SearchSessionModel
    private let parser: SearchQueryParser
    private let calendar: Calendar

    public init(
        searchModel: SearchSessionModel,
        parserContext: QueryParserContext,
        catalog: SearchFilterCatalog
    ) {
        self.searchModel = searchModel
        parser = SearchQueryParser(context: parserContext)
        calendar = parserContext.calendar
        self.catalog = catalog
    }

    public func updateQueryText(_ value: String) {
        guard queryText != value else { return }
        queryText = value
        publish()
    }

    public func commitQuery() {
        let parsed = parser.parse(queryText)
        queryText = parsed.lexicalQuery
        tokens = parsed.tokens
        applicationBundleIDs = parsed.applicationBundleIDs
        hosts = parsed.hosts
        interval = parsed.timeBounds.flatMap { bounds in
            guard let start = bounds.lowerBound, let end = bounds.upperBound, start < end else {
                return nil
            }
            return DateInterval(start: start, end: end)
        }
        publish()
    }

    public func removeFilter(id: SearchQueryToken.ID) {
        guard let token = tokens.first(where: { $0.id == id }) else { return }
        switch token.kind {
        case .application:
            applicationBundleIDs.remove(token.canonicalValue)
        case .site:
            hosts.remove(token.canonicalValue)
        case .time:
            interval = nil
        }
        tokens.removeAll {
            $0.id == id || (token.kind == .time && $0.kind == .time)
        }
        publish()
    }

    public func autocompleteSuggestions(for text: String) -> [SearchAutocompleteSuggestion] {
        guard let fragment = text.split(whereSeparator: { $0.isWhitespace }).last else {
            return []
        }
        let rawFragment = String(fragment)
        if rawFragment.lowercased().hasPrefix("app:") {
            let prefix = String(rawFragment.dropFirst(4)).trimmingCharacters(
                in: CharacterSet(
                    charactersIn: "\"'"
                ))
            return catalog.applications.compactMap { application in
                let names = [application.displayName] + application.aliases
                guard applicationBundleIDs.contains(application.bundleID) == false,
                    names.contains(where: {
                        $0.localizedCaseInsensitiveContains(prefix)
                    })
                else {
                    return nil
                }
                return SearchAutocompleteSuggestion(
                    kind: .application,
                    label: application.displayName,
                    canonicalValue: application.bundleID
                )
            }.prefix(8).map { $0 }
        }
        if rawFragment.lowercased().hasPrefix("site:") {
            let prefix = String(rawFragment.dropFirst(5)).lowercased()
            return catalog.hosts.compactMap { host in
                guard hosts.contains(host) == false, host.contains(prefix) else { return nil }
                return SearchAutocompleteSuggestion(
                    kind: .site,
                    label: host,
                    canonicalValue: host
                )
            }.prefix(8).map { $0 }
        }
        return []
    }

    public func applySuggestion(_ suggestion: SearchAutocompleteSuggestion) {
        let token: SearchQueryToken
        switch suggestion.kind {
        case .application:
            guard
                let application = catalog.applications.first(where: {
                    $0.bundleID == suggestion.canonicalValue
                })
            else {
                return
            }
            applicationBundleIDs.insert(application.bundleID)
            token = SearchQueryToken(
                kind: .application,
                label: application.displayName,
                canonicalValue: application.bundleID
            )
            removeTrailingDirective("app:")
        case .site:
            guard catalog.hosts.contains(suggestion.canonicalValue) else { return }
            hosts.insert(suggestion.canonicalValue)
            token = SearchQueryToken(
                kind: .site,
                label: suggestion.canonicalValue,
                canonicalValue: suggestion.canonicalValue
            )
            removeTrailingDirective("site:")
        case .time:
            return
        }
        tokens.removeAll { $0.id == token.id }
        tokens.append(token)
        publish()
    }

    public func setDateInterval(_ value: DateInterval) {
        guard value.start < value.end else { return }
        interval = value
        tokens.removeAll { $0.kind == .time }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let start = formatter.string(from: value.start)
        let inclusiveEnd = calendar.date(byAdding: .second, value: -1, to: value.end) ?? value.end
        let end = formatter.string(from: inclusiveEnd)
        let startMilliseconds = Int64(value.start.timeIntervalSince1970 * 1_000)
        let endMilliseconds = Int64(value.end.timeIntervalSince1970 * 1_000)
        tokens.append(
            SearchQueryToken(
                kind: .time,
                label: start == end ? start : "\(start) – \(end)",
                canonicalValue: "interval:\(startMilliseconds)/\(endMilliseconds)"
            )
        )
        publish()
    }

    @discardableResult
    public func restore(_ snapshot: SearchFilterSnapshot) -> Bool {
        let approvedApplicationIDs = Set(catalog.applications.map(\.bundleID))
        let approvedHosts = Set(catalog.hosts)
        let applicationIDs = Set(snapshot.applicationBundleIDs)
        let restoredHosts = Set(snapshot.hosts)
        guard applicationIDs.isSubset(of: approvedApplicationIDs),
            restoredHosts.isSubset(of: approvedHosts),
            snapshot.tokens.map(\.id).count == Set(snapshot.tokens.map(\.id)).count,
            Set(
                snapshot.tokens
                    .filter { $0.kind == .application }
                    .map(\.canonicalValue)
            ) == applicationIDs,
            Set(
                snapshot.tokens
                    .filter { $0.kind == .site }
                    .map(\.canonicalValue)
            ) == restoredHosts,
            timeTokensAreConsistent(snapshot.tokens, interval: snapshot.interval)
        else {
            return false
        }

        queryText = snapshot.queryText
        tokens = snapshot.tokens
        applicationBundleIDs = applicationIDs
        hosts = restoredHosts
        interval = snapshot.interval
        publish()
        return true
    }

    private func removeTrailingDirective(_ directive: String) {
        var components = queryText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if components.last?.lowercased().hasPrefix(directive) == true {
            components.removeLast()
            queryText = components.joined(separator: " ")
        }
    }

    private func timeTokensAreConsistent(
        _ tokens: [SearchQueryToken],
        interval: DateInterval?
    ) -> Bool {
        let timeTokens = tokens.filter { $0.kind == .time }
        guard let interval else { return timeTokens.isEmpty }
        guard interval.start < interval.end, timeTokens.count == 1 else { return false }
        let startMilliseconds = Int64(interval.start.timeIntervalSince1970 * 1_000)
        let endMilliseconds = Int64(interval.end.timeIntervalSince1970 * 1_000)
        return timeTokens[0].canonicalValue == "interval:\(startMilliseconds)/\(endMilliseconds)"
    }

    private func publish() {
        searchModel.updateInput(
            SearchSessionInput(
                query: queryText,
                interval: interval,
                bundleIDs: applicationBundleIDs,
                hosts: hosts
            )
        )
    }
}
