import Foundation
import MemoryContracts

public struct SearchResultCardProjection: Codable, Equatable, Sendable {
    public let frameID: UUID
    public let title: String
    public let timeText: String
    public let applicationName: String
    public let host: String?
    public let evidenceSource: SearchEvidenceSource
    public let evidenceText: String?
    public let position: Int
    public let resultCount: Int
    public let thumbnailLocator: ContentLocator?

    public init(
        frameID: UUID,
        title: String,
        timeText: String,
        applicationName: String,
        host: String?,
        evidenceSource: SearchEvidenceSource,
        evidenceText: String?,
        position: Int,
        resultCount: Int,
        thumbnailLocator: ContentLocator?
    ) {
        self.frameID = frameID
        self.title = title
        self.timeText = timeText
        self.applicationName = applicationName
        self.host = host
        self.evidenceSource = evidenceSource
        self.evidenceText = evidenceText
        self.position = position
        self.resultCount = resultCount
        self.thumbnailLocator = thumbnailLocator
    }

    public var accessibilityLabel: String {
        let hostText = host.map { ", \($0)" } ?? ""
        return "\(timeText), \(applicationName)\(hostText), \(evidenceSource.rawValue), "
            + "result \(position) of \(resultCount)"
    }
}

public enum SearchResultGridContentState: Equatable, Sendable {
    case emptyArchive
    case emptyQuery
    case loading(query: String)
    case noResults(query: String, activeFilterLabels: [String], indexingBacklog: Int)
    case results(count: Int, indexingBacklog: Int)
    case failure(query: String, diagnosticCode: String)
}

public enum SearchResultGridProjection: Sendable {
    public static func columnCount(availableWidth: Double) -> Int {
        if availableWidth < 520 { return 1 }
        if availableWidth < 720 { return 2 }
        return 3
    }

    public static func cards(
        from results: [SearchResult],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SearchResultCardProjection] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return results.enumerated().compactMap { index, result in
            guard let evidence = result.evidence.first else { return nil }
            return SearchResultCardProjection(
                frameID: result.frameID,
                title: result.foreground.windowTitle ?? result.foreground.applicationName,
                timeText: formatter.string(from: result.capturedAt),
                applicationName: result.foreground.applicationName,
                host: result.browser?.origin.host,
                evidenceSource: evidence.source,
                evidenceText: evidence.matchedText,
                position: index + 1,
                resultCount: results.count,
                thumbnailLocator: result.thumbnailLocator
            )
        }
    }

    public static func contentState(
        phase: SearchSessionPhase,
        archiveHasSearchableContent: Bool,
        activeFilterLabels: [String],
        indexingBacklog: Int
    ) -> SearchResultGridContentState {
        let backlog = max(0, indexingBacklog)
        switch phase {
        case .idle:
            return archiveHasSearchableContent ? .emptyQuery : .emptyArchive
        case .debouncing(let query), .loading(let query):
            return .loading(query: query)
        case .results(_, let count):
            return .results(count: count, indexingBacklog: backlog)
        case .empty(let query):
            return .noResults(
                query: query,
                activeFilterLabels: activeFilterLabels,
                indexingBacklog: backlog
            )
        case .failure(let query, let diagnosticCode):
            return .failure(query: query, diagnosticCode: diagnosticCode)
        }
    }

    public static func accessibilityAnnouncement(
        previousCount: Int,
        currentCount: Int,
        indexingBacklog: Int,
        hasNextPage: Bool
    ) -> String {
        let added = max(0, currentCount - previousCount)
        var parts: [String] = []
        if previousCount > 0, added > 0 {
            parts.append("\(added) more results loaded, \(currentCount) shown.")
        } else {
            parts.append("\(currentCount) results shown.")
        }
        if indexingBacklog > 0 {
            parts.append("Still indexing \(indexingBacklog) moments.")
        }
        if hasNextPage {
            parts.append("More results available.")
        }
        return parts.joined(separator: " ")
    }
}
