import Foundation

public enum QueryParserError: Error, Equatable, Sendable {
    case unresolvedReferenceDay
    case invalidApplicationDescriptor
    case duplicateApplicationAlias
}

public struct SearchApplicationDescriptor: Codable, Equatable, Sendable {
    public let bundleID: String
    public let displayName: String
    public let aliases: [String]

    public init(bundleID: String, displayName: String, aliases: [String] = []) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.aliases = aliases
    }
}

public struct QueryParserContext: Sendable {
    public let referenceDate: Date
    public let calendar: Calendar
    public let applications: [SearchApplicationDescriptor]

    public init(
        referenceDate: Date,
        calendar: Calendar,
        applications: [SearchApplicationDescriptor] = []
    ) throws {
        guard calendar.dateInterval(of: .day, for: referenceDate) != nil else {
            throw QueryParserError.unresolvedReferenceDay
        }
        var normalizedAliases: Set<String> = []
        for application in applications {
            let names = [application.displayName] + application.aliases
            guard !application.bundleID.isEmpty,
                application.bundleID.contains("."),
                !application.displayName.isEmpty,
                names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                throw QueryParserError.invalidApplicationDescriptor
            }
            for name in names {
                let normalized = Self.normalized(name, locale: calendar.locale)
                guard normalizedAliases.insert(normalized).inserted else {
                    throw QueryParserError.duplicateApplicationAlias
                }
            }
        }
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.applications = applications
    }

    fileprivate static func normalized(_ value: String, locale: Locale?) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: locale
        )
    }
}

public enum SearchQueryTokenKind: String, Codable, Equatable, Sendable {
    case application
    case site
    case time
}

public struct SearchQueryToken: Codable, Equatable, Sendable {
    public let kind: SearchQueryTokenKind
    public let label: String
    public let canonicalValue: String

    public init(kind: SearchQueryTokenKind, label: String, canonicalValue: String) {
        self.kind = kind
        self.label = label
        self.canonicalValue = canonicalValue
    }
}

public struct SearchTimeBounds: Codable, Equatable, Sendable {
    public let lowerBound: Date?
    public let upperBound: Date?

    public init(lowerBound: Date?, upperBound: Date?) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct ParsedSearchQuery: Codable, Equatable, Sendable {
    public let lexicalQuery: String
    public let quotedPhrases: [String]
    public let applicationBundleIDs: Set<String>
    public let hosts: Set<String>
    public let timeBounds: SearchTimeBounds?
    public let tokens: [SearchQueryToken]

    public init(
        lexicalQuery: String,
        quotedPhrases: [String] = [],
        applicationBundleIDs: Set<String> = [],
        hosts: Set<String> = [],
        timeBounds: SearchTimeBounds? = nil,
        tokens: [SearchQueryToken] = []
    ) {
        self.lexicalQuery = lexicalQuery
        self.quotedPhrases = quotedPhrases
        self.applicationBundleIDs = applicationBundleIDs
        self.hosts = hosts
        self.timeBounds = timeBounds
        self.tokens = tokens
    }
}

public struct SearchQueryParser: Sendable {
    private let context: QueryParserContext

    public init(context: QueryParserContext) {
        self.context = context
    }

    public func parse(_ query: String) -> ParsedSearchQuery {
        let lexemes = Self.lexemes(in: query)
        var lexicalComponents: [String] = []
        var quotedPhrases: [String] = []
        var bundleIDs: Set<String> = []
        var hosts: Set<String> = []
        var timeBounds: SearchTimeBounds?
        var tokens: [SearchQueryToken] = []

        var index = 0
        while index < lexemes.count {
            let lexeme = lexemes[index]
            index += 1
            if let relativeWeek = relativeWeek(startingAt: index - 1, in: lexemes),
                timeBounds == nil
            {
                index += relativeWeek.additionalLexemeCount
                timeBounds = relativeWeek.bounds
                tokens.append(relativeWeek.token)
                continue
            }
            if let operand = lexeme.operand(for: "app"),
                let application = application(named: operand)
            {
                bundleIDs.insert(application.bundleID)
                tokens.append(
                    SearchQueryToken(
                        kind: .application,
                        label: application.displayName,
                        canonicalValue: application.bundleID
                    )
                )
                continue
            }
            if let operand = lexeme.operand(for: "site"),
                let host = Self.normalizedHost(operand)
            {
                hosts.insert(host)
                tokens.append(
                    SearchQueryToken(kind: .site, label: host, canonicalValue: host)
                )
                continue
            }
            if let operand = lexeme.operand(for: "after"),
                let day = parsedDay(operand),
                Self.validBounds(lower: day.date, upper: timeBounds?.upperBound)
            {
                timeBounds = SearchTimeBounds(
                    lowerBound: day.date,
                    upperBound: timeBounds?.upperBound
                )
                tokens.append(
                    SearchQueryToken(
                        kind: .time,
                        label: "After \(day.canonical)",
                        canonicalValue: "after:\(day.canonical)"
                    )
                )
                continue
            }
            if let operand = lexeme.operand(for: "before"),
                let day = parsedDay(operand),
                Self.validBounds(lower: timeBounds?.lowerBound, upper: day.date)
            {
                timeBounds = SearchTimeBounds(
                    lowerBound: timeBounds?.lowerBound,
                    upperBound: day.date
                )
                tokens.append(
                    SearchQueryToken(
                        kind: .time,
                        label: "Before \(day.canonical)",
                        canonicalValue: "before:\(day.canonical)"
                    )
                )
                continue
            }
            if let day = parsedDay(lexeme.raw),
                timeBounds == nil,
                let end = context.calendar.date(byAdding: .day, value: 1, to: day.date)
            {
                timeBounds = SearchTimeBounds(lowerBound: day.date, upperBound: end)
                tokens.append(
                    SearchQueryToken(
                        kind: .time,
                        label: lexeme.raw,
                        canonicalValue: "date:\(day.canonical)"
                    )
                )
                continue
            }
            if let relativeDay = relativeDay(for: lexeme.raw),
                timeBounds == nil,
                let targetDate = context.calendar.date(
                    byAdding: .day,
                    value: relativeDay.dayOffset,
                    to: context.referenceDate
                ),
                let interval = context.calendar.dateInterval(
                    of: .day,
                    for: targetDate
                )
            {
                timeBounds = SearchTimeBounds(
                    lowerBound: interval.start,
                    upperBound: interval.end
                )
                tokens.append(
                    SearchQueryToken(
                        kind: .time,
                        label: relativeDay.label,
                        canonicalValue: relativeDay.canonicalValue
                    )
                )
                continue
            }
            lexicalComponents.append(lexeme.raw)
            if let phrase = lexeme.quotedValue {
                quotedPhrases.append(phrase)
            }
        }

        return ParsedSearchQuery(
            lexicalQuery: lexicalComponents.joined(separator: " "),
            quotedPhrases: quotedPhrases,
            applicationBundleIDs: bundleIDs,
            hosts: hosts,
            timeBounds: timeBounds,
            tokens: tokens
        )
    }

    private func relativeWeek(
        startingAt index: Int,
        in lexemes: [QueryLexeme]
    ) -> (bounds: SearchTimeBounds, token: SearchQueryToken, additionalLexemeCount: Int)? {
        guard index + 1 < lexemes.count,
            let currentWeek = context.calendar.dateInterval(
                of: .weekOfYear,
                for: context.referenceDate
            ),
            let previousStart = context.calendar.date(
                byAdding: .weekOfYear,
                value: -1,
                to: currentWeek.start
            )
        else {
            return nil
        }
        let language = context.calendar.locale?.language.languageCode?.identifier ?? "en"
        let phrase: (first: String, second: String, label: String)
        switch language {
        case "fr":
            phrase = ("semaine", "dernière", "Semaine dernière")
        case "de":
            phrase = ("letzte", "woche", "Letzte Woche")
        case "es":
            phrase = ("semana", "pasada", "Semana pasada")
        default:
            phrase = ("last", "week", "Last week")
        }
        let first = QueryParserContext.normalized(
            lexemes[index].raw,
            locale: context.calendar.locale
        )
        let second = QueryParserContext.normalized(
            lexemes[index + 1].raw,
            locale: context.calendar.locale
        )
        guard
            first
                == QueryParserContext.normalized(
                    phrase.first,
                    locale: context.calendar.locale
                ),
            second
                == QueryParserContext.normalized(
                    phrase.second,
                    locale: context.calendar.locale
                )
        else {
            return nil
        }
        return (
            SearchTimeBounds(lowerBound: previousStart, upperBound: currentWeek.start),
            SearchQueryToken(kind: .time, label: phrase.label, canonicalValue: "last-week"),
            1
        )
    }

    private func application(named value: String) -> SearchApplicationDescriptor? {
        let requested = QueryParserContext.normalized(value, locale: context.calendar.locale)
        return context.applications.first { application in
            ([application.displayName] + application.aliases).contains { name in
                QueryParserContext.normalized(name, locale: context.calendar.locale) == requested
            }
        }
    }

    private func relativeDay(for value: String) -> RelativeDay? {
        let language = context.calendar.locale?.language.languageCode?.identifier ?? "en"
        let entries: [RelativeDay]
        switch language {
        case "fr":
            entries = [
                RelativeDay(
                    values: ["aujourd'hui", "aujourd’hui"], label: "Aujourd’hui", dayOffset: 0),
                RelativeDay(values: ["hier"], label: "Hier", dayOffset: -1),
            ]
        case "de":
            entries = [
                RelativeDay(values: ["heute"], label: "Heute", dayOffset: 0),
                RelativeDay(values: ["gestern"], label: "Gestern", dayOffset: -1),
            ]
        case "es":
            entries = [
                RelativeDay(values: ["hoy"], label: "Hoy", dayOffset: 0),
                RelativeDay(values: ["ayer"], label: "Ayer", dayOffset: -1),
            ]
        default:
            entries = [
                RelativeDay(values: ["today"], label: "Today", dayOffset: 0),
                RelativeDay(values: ["yesterday"], label: "Yesterday", dayOffset: -1),
            ]
        }
        let normalized = QueryParserContext.normalized(value, locale: context.calendar.locale)
        return entries.first { entry in
            entry.values.contains {
                QueryParserContext.normalized($0, locale: context.calendar.locale) == normalized
            }
        }
    }

    private func parsedDay(_ value: String) -> (date: Date, canonical: String)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3,
            parts[0].count == 4,
            parts[1].count == 2,
            parts[2].count == 2,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        {
            return resolvedDay(year: year, month: month, day: day)
        }
        let formatter = DateFormatter()
        formatter.calendar = context.calendar
        formatter.locale = context.calendar.locale
        formatter.timeZone = context.calendar.timeZone
        formatter.isLenient = false
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "yMd",
            options: 0,
            locale: context.calendar.locale
        )
        guard let date = formatter.date(from: value) else {
            return nil
        }
        let components = context.calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }
        return resolvedDay(year: year, month: month, day: day)
    }

    private func resolvedDay(
        year: Int,
        month: Int,
        day: Int
    ) -> (date: Date, canonical: String)? {
        var components = DateComponents()
        components.calendar = context.calendar
        components.timeZone = context.calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = context.calendar.date(from: components) else {
            return nil
        }
        let resolved = context.calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            return nil
        }
        return (date, String(format: "%04d-%02d-%02d", year, month, day))
    }

    private static func validBounds(lower: Date?, upper: Date?) -> Bool {
        guard let lower, let upper else {
            return true
        }
        return lower < upper
    }

    private static func normalizedHost(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while candidate.hasSuffix(".") {
            candidate.removeLast()
        }
        guard !candidate.isEmpty,
            !candidate.contains(where: { "@/:?#".contains($0) }),
            candidate.utf8.count <= 253
        else {
            return nil
        }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
            labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-"
                    && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            })
        else {
            return nil
        }
        return candidate
    }

    private static func lexemes(in query: String) -> [QueryLexeme] {
        var result: [QueryLexeme] = []
        var buffer = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                quoted.toggle()
                buffer.append(character)
            } else if character.isWhitespace && !quoted {
                if !buffer.isEmpty {
                    result.append(QueryLexeme(raw: buffer))
                    buffer = ""
                }
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty {
            result.append(QueryLexeme(raw: buffer))
        }
        return result
    }
}

private struct RelativeDay {
    let values: [String]
    let label: String
    let dayOffset: Int

    var canonicalValue: String {
        dayOffset == 0 ? "today" : "yesterday"
    }
}

private struct QueryLexeme {
    let raw: String

    var quotedValue: String? {
        Self.unquoted(raw)
    }

    func operand(for expectedOperator: String) -> String? {
        guard let colon = raw.firstIndex(of: ":") else {
            return nil
        }
        let operation = String(raw[..<colon])
        guard operation.compare(expectedOperator, options: .caseInsensitive) == .orderedSame else {
            return nil
        }
        let value = String(raw[raw.index(after: colon)...])
        guard !value.isEmpty else {
            return nil
        }
        return Self.unquoted(value) ?? (value.contains("\"") ? nil : value)
    }

    private static func unquoted(_ value: String) -> String? {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return nil
        }
        let inner = value.dropFirst().dropLast()
        guard !inner.isEmpty, !inner.contains("\"") else {
            return nil
        }
        return String(inner)
    }
}
