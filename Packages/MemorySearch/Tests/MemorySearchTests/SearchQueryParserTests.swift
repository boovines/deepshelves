import Foundation
import XCTest

@testable import MemorySearch

final class SearchQueryParserTests: XCTestCase {
    func testTodayBecomesVisibleDayFilterAndLeavesRemainingLexicalQuery() throws {
        let context = try QueryParserContext(
            referenceDate: makeDate("2026-08-28T12:00:00Z"),
            calendar: utcCalendar(localeIdentifier: "en_US")
        )
        let parsed = SearchQueryParser(context: context).parse("lamp today")

        XCTAssertEqual(parsed.lexicalQuery, "lamp")
        XCTAssertEqual(parsed.timeBounds?.lowerBound, try makeDate("2026-08-28T00:00:00Z"))
        XCTAssertEqual(parsed.timeBounds?.upperBound, try makeDate("2026-08-29T00:00:00Z"))
        XCTAssertEqual(
            parsed.tokens,
            [SearchQueryToken(kind: .time, label: "Today", canonicalValue: "today")]
        )
    }

    func testQuotedTextAndKnownApplicationAndSiteBecomeExplicitOutputs() throws {
        let context = try QueryParserContext(
            referenceDate: makeDate("2026-08-28T12:00:00Z"),
            calendar: utcCalendar(localeIdentifier: "en_US"),
            applications: [
                SearchApplicationDescriptor(
                    bundleID: "com.google.Chrome",
                    displayName: "Google Chrome",
                    aliases: ["Chrome"]
                )
            ]
        )
        let parsed = SearchQueryParser(context: context).parse(
            "\"invoice number\" app:\"Google Chrome\" site:GitHub.com"
        )

        XCTAssertEqual(parsed.lexicalQuery, "\"invoice number\"")
        XCTAssertEqual(parsed.quotedPhrases, ["invoice number"])
        XCTAssertEqual(parsed.applicationBundleIDs, ["com.google.Chrome"])
        XCTAssertEqual(parsed.hosts, ["github.com"])
        XCTAssertEqual(
            parsed.tokens,
            [
                SearchQueryToken(
                    kind: .application,
                    label: "Google Chrome",
                    canonicalValue: "com.google.Chrome"
                ),
                SearchQueryToken(kind: .site, label: "github.com", canonicalValue: "github.com"),
            ]
        )
    }

    func testAmbiguousOrInvalidSyntaxRemainsVisibleLexicalText() throws {
        let context = try QueryParserContext(
            referenceDate: makeDate("2026-08-28T12:00:00Z"),
            calendar: utcCalendar(localeIdentifier: "en_US")
        )
        let query = "today's app:Unknown site:github app: before launch \"unfinished"
        let parsed = SearchQueryParser(context: context).parse(query)

        XCTAssertEqual(parsed.lexicalQuery, query)
        XCTAssertTrue(parsed.quotedPhrases.isEmpty)
        XCTAssertTrue(parsed.applicationBundleIDs.isEmpty)
        XCTAssertTrue(parsed.hosts.isEmpty)
        XCTAssertNil(parsed.timeBounds)
        XCTAssertTrue(parsed.tokens.isEmpty)
    }

    func testLocalizedYesterdayUsesCalendarDayBoundaries() throws {
        let context = try QueryParserContext(
            referenceDate: makeDate("2026-08-28T12:00:00Z"),
            calendar: utcCalendar(localeIdentifier: "fr_FR")
        )
        let parsed = SearchQueryParser(context: context).parse("lampe hier")

        XCTAssertEqual(parsed.lexicalQuery, "lampe")
        XCTAssertEqual(parsed.timeBounds?.lowerBound, try makeDate("2026-08-27T00:00:00Z"))
        XCTAssertEqual(parsed.timeBounds?.upperBound, try makeDate("2026-08-28T00:00:00Z"))
        XCTAssertEqual(
            parsed.tokens,
            [SearchQueryToken(kind: .time, label: "Hier", canonicalValue: "yesterday")]
        )
    }

    func testExplicitAfterAndBeforeDatesProduceVisibleHalfOpenBounds() throws {
        let context = try QueryParserContext(
            referenceDate: makeDate("2026-08-28T12:00:00Z"),
            calendar: utcCalendar(localeIdentifier: "en_US")
        )
        let parsed = SearchQueryParser(context: context).parse(
            "invoice after:2026-08-01 before:2026-09-01"
        )

        XCTAssertEqual(parsed.lexicalQuery, "invoice")
        XCTAssertEqual(parsed.timeBounds?.lowerBound, try makeDate("2026-08-01T00:00:00Z"))
        XCTAssertEqual(parsed.timeBounds?.upperBound, try makeDate("2026-09-01T00:00:00Z"))
        XCTAssertEqual(
            parsed.tokens,
            [
                SearchQueryToken(
                    kind: .time,
                    label: "After 2026-08-01",
                    canonicalValue: "after:2026-08-01"
                ),
                SearchQueryToken(
                    kind: .time,
                    label: "Before 2026-09-01",
                    canonicalValue: "before:2026-09-01"
                ),
            ]
        )
    }

    func testLastWeekUsesLocaleCalendarWeekRatherThanSevenRollingDays() throws {
        let context = try QueryParserContext(
            referenceDate: makeDate("2026-08-28T12:00:00Z"),
            calendar: utcCalendar(localeIdentifier: "en_US")
        )
        let parsed = SearchQueryParser(context: context).parse("roadmap last week")

        XCTAssertEqual(parsed.lexicalQuery, "roadmap")
        XCTAssertEqual(parsed.timeBounds?.lowerBound, try makeDate("2026-08-17T00:00:00Z"))
        XCTAssertEqual(parsed.timeBounds?.upperBound, try makeDate("2026-08-24T00:00:00Z"))
        XCTAssertEqual(
            parsed.tokens,
            [SearchQueryToken(kind: .time, label: "Last week", canonicalValue: "last-week")]
        )
    }

    func testStandaloneLocaleDateBecomesVisibleExactDayFilter() throws {
        let context = try QueryParserContext(
            referenceDate: makeDate("2026-08-28T12:00:00Z"),
            calendar: utcCalendar(localeIdentifier: "fr_FR")
        )
        let parsed = SearchQueryParser(context: context).parse("facture 27/08/2026")

        XCTAssertEqual(parsed.lexicalQuery, "facture")
        XCTAssertEqual(parsed.timeBounds?.lowerBound, try makeDate("2026-08-27T00:00:00Z"))
        XCTAssertEqual(parsed.timeBounds?.upperBound, try makeDate("2026-08-28T00:00:00Z"))
        XCTAssertEqual(
            parsed.tokens,
            [
                SearchQueryToken(
                    kind: .time,
                    label: "27/08/2026",
                    canonicalValue: "date:2026-08-27"
                )
            ]
        )
    }

    func testOneHundredGoldenQueriesAreDeterministicAndExposeEveryFilter() throws {
        let fixture = try JSONDecoder().decode(
            QueryGoldenFixture.self,
            from: Data(contentsOf: fixtureURL())
        )
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.cases.count, 100)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, 100)
        let applications = fixture.applications.map {
            SearchApplicationDescriptor(
                bundleID: $0.bundleID,
                displayName: $0.displayName,
                aliases: $0.aliases
            )
        }

        for golden in fixture.cases {
            let context = try QueryParserContext(
                referenceDate: makeDate(fixture.referenceDate),
                calendar: utcCalendar(localeIdentifier: golden.locale),
                applications: applications
            )
            let parser = SearchQueryParser(context: context)
            let parsed = parser.parse(golden.query)
            let expectedTokens = golden.tokens.map {
                SearchQueryToken(
                    kind: SearchQueryTokenKind(rawValue: $0.kind)!,
                    label: $0.label,
                    canonicalValue: $0.canonicalValue
                )
            }

            XCTAssertEqual(parsed.lexicalQuery, golden.lexicalQuery, golden.id)
            XCTAssertEqual(parsed.quotedPhrases, golden.quotedPhrases, golden.id)
            XCTAssertEqual(parsed.applicationBundleIDs, Set(golden.applicationBundleIDs), golden.id)
            XCTAssertEqual(parsed.hosts, Set(golden.hosts), golden.id)
            XCTAssertEqual(
                parsed.timeBounds?.lowerBound, try golden.lowerBound.map(makeDate), golden.id)
            XCTAssertEqual(
                parsed.timeBounds?.upperBound, try golden.upperBound.map(makeDate), golden.id)
            XCTAssertEqual(parsed.tokens, expectedTokens, golden.id)
            XCTAssertEqual(parser.parse(golden.query), parsed, "nondeterministic \(golden.id)")
            XCTAssertEqual(
                parsed.applicationBundleIDs.isEmpty,
                !parsed.tokens.contains(where: { $0.kind == .application }),
                "hidden application filter in \(golden.id)"
            )
            XCTAssertEqual(
                parsed.hosts.isEmpty,
                !parsed.tokens.contains(where: { $0.kind == .site }),
                "hidden site filter in \(golden.id)"
            )
            XCTAssertEqual(
                parsed.timeBounds == nil,
                !parsed.tokens.contains(where: { $0.kind == .time }),
                "hidden time filter in \(golden.id)"
            )
        }
    }

    private func utcCalendar(localeIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: localeIdentifier)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func makeDate(_ value: String) throws -> Date {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return try XCTUnwrap(fractional.date(from: value))
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LM036/query-parse-goldens.json")
    }
}

private struct QueryGoldenFixture: Decodable {
    let schemaVersion: Int
    let referenceDate: String
    let applications: [QueryGoldenApplication]
    let cases: [QueryGoldenCase]
}

private struct QueryGoldenApplication: Decodable {
    let bundleID: String
    let displayName: String
    let aliases: [String]
}

private struct QueryGoldenCase: Decodable {
    let id: String
    let locale: String
    let query: String
    let lexicalQuery: String
    let quotedPhrases: [String]
    let applicationBundleIDs: [String]
    let hosts: [String]
    let lowerBound: String?
    let upperBound: String?
    let tokens: [QueryGoldenToken]
}

private struct QueryGoldenToken: Decodable {
    let kind: String
    let label: String
    let canonicalValue: String
}
