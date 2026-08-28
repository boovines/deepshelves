#!/usr/bin/env swift
import Foundation

struct Fixture: Codable {
    let schemaVersion: Int
    let referenceDate: String
    let applications: [Application]
    let cases: [Case]
}

struct Application: Codable {
    let bundleID: String
    let displayName: String
    let aliases: [String]
}

struct Case: Codable {
    let id: String
    let locale: String
    let query: String
    let lexicalQuery: String
    let quotedPhrases: [String]
    let applicationBundleIDs: [String]
    let hosts: [String]
    let lowerBound: String?
    let upperBound: String?
    let tokens: [Token]
}

struct Token: Codable {
    let kind: String
    let label: String
    let canonicalValue: String
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-lm036-query-fixtures.swift OUTPUT\n".utf8))
    exit(64)
}

let applications = [
    Application(bundleID: "com.google.Chrome", displayName: "Google Chrome", aliases: ["Chrome"]),
    Application(bundleID: "com.apple.Safari", displayName: "Safari", aliases: []),
    Application(bundleID: "com.apple.finder", displayName: "Finder", aliases: []),
    Application(bundleID: "com.apple.Terminal", displayName: "Terminal", aliases: []),
    Application(bundleID: "com.anthropic.claudefordesktop", displayName: "Claude", aliases: []),
]
var cases: [Case] = []

func add(
    category: String,
    locale: String = "en_US",
    query: String,
    lexicalQuery: String,
    quotedPhrases: [String] = [],
    applicationBundleIDs: [String] = [],
    hosts: [String] = [],
    lowerBound: String? = nil,
    upperBound: String? = nil,
    tokens: [Token] = []
) {
    cases.append(
        Case(
            id: String(format: "%@-%03d", category, cases.count + 1),
            locale: locale,
            query: query,
            lexicalQuery: lexicalQuery,
            quotedPhrases: quotedPhrases,
            applicationBundleIDs: applicationBundleIDs,
            hosts: hosts,
            lowerBound: lowerBound,
            upperBound: upperBound,
            tokens: tokens
        )
    )
}

let lexicalQueries = [
    ("lamp", "lamp"),
    ("invoice number", "invoice number"),
    ("  project   deadline  ", "project deadline"),
    ("Café résumé", "Café résumé"),
    ("before launch", "before launch"),
    ("mail from Alex", "mail from Alex"),
    ("Q3 roadmap", "Q3 roadmap"),
    ("github pull request", "github pull request"),
    ("error 409", "error 409"),
    ("yellow lamp todayish", "yellow lamp todayish"),
]
for item in lexicalQueries {
    add(category: "lexical", query: item.0, lexicalQuery: item.1)
}

let phrases = [
    "invoice number", "project deadline", "yellow lamp", "exact error", "meeting notes",
    "pull request", "budget draft", "customer name", "release checklist", "search phrase",
]
for phrase in phrases {
    add(
        category: "quote",
        query: "\"\(phrase)\" evidence",
        lexicalQuery: "\"\(phrase)\" evidence",
        quotedPhrases: [phrase]
    )
}

let relativeLocales = [
    ("en_US", "today", "Today"),
    ("fr_FR", "aujourd’hui", "Aujourd’hui"),
    ("de_DE", "heute", "Heute"),
    ("es_ES", "hoy", "Hoy"),
]
for index in 0..<10 {
    let item = relativeLocales[index % relativeLocales.count]
    add(
        category: "today",
        locale: item.0,
        query: "moment\(index) \(item.1)",
        lexicalQuery: "moment\(index)",
        lowerBound: "2026-08-28T00:00:00.000Z",
        upperBound: "2026-08-29T00:00:00.000Z",
        tokens: [Token(kind: "time", label: item.2, canonicalValue: "today")]
    )
}

let yesterdayLocales = [
    ("en_US", "yesterday", "Yesterday"),
    ("fr_FR", "hier", "Hier"),
    ("de_DE", "gestern", "Gestern"),
    ("es_ES", "ayer", "Ayer"),
]
for index in 0..<10 {
    let item = yesterdayLocales[index % yesterdayLocales.count]
    add(
        category: "yesterday",
        locale: item.0,
        query: "moment\(index) \(item.1)",
        lexicalQuery: "moment\(index)",
        lowerBound: "2026-08-27T00:00:00.000Z",
        upperBound: "2026-08-28T00:00:00.000Z",
        tokens: [Token(kind: "time", label: item.2, canonicalValue: "yesterday")]
    )
}

let weekLocales = [
    ("en_US", "last week", "Last week"),
    ("fr_FR", "semaine dernière", "Semaine dernière"),
    ("de_DE", "letzte woche", "Letzte Woche"),
    ("es_ES", "semana pasada", "Semana pasada"),
]
for index in 0..<10 {
    let item = weekLocales[index % weekLocales.count]
    add(
        category: "week",
        locale: item.0,
        query: "roadmap\(index) \(item.1)",
        lexicalQuery: "roadmap\(index)",
        lowerBound: "2026-08-17T00:00:00.000Z",
        upperBound: "2026-08-24T00:00:00.000Z",
        tokens: [Token(kind: "time", label: item.2, canonicalValue: "last-week")]
    )
}

let applicationInputs = [
    ("Chrome", applications[0]), ("Google Chrome", applications[0]),
    ("Safari", applications[1]), ("Finder", applications[2]),
    ("Terminal", applications[3]), ("Claude", applications[4]),
    ("chrome", applications[0]), ("SAFARI", applications[1]),
    ("finder", applications[2]), ("terminal", applications[3]),
]
for (index, item) in applicationInputs.enumerated() {
    add(
        category: "app",
        query: "item\(index) app:\"\(item.0)\"",
        lexicalQuery: "item\(index)",
        applicationBundleIDs: [item.1.bundleID],
        tokens: [
            Token(kind: "application", label: item.1.displayName, canonicalValue: item.1.bundleID)
        ]
    )
}

let sites = [
    "github.com", "linear.app", "docs.swift.org", "example.co.uk", "openai.com",
    "apple.com", "support.apple.com", "developer.apple.com", "anthropic.com", "example.org",
]
for (index, host) in sites.enumerated() {
    let source = index.isMultiple(of: 2) ? host.uppercased() : host
    add(
        category: "site",
        query: "page\(index) site:\(source)",
        lexicalQuery: "page\(index)",
        hosts: [host],
        tokens: [Token(kind: "site", label: host, canonicalValue: host)]
    )
}

for index in 0..<10 {
    if index.isMultiple(of: 2) {
        add(
            category: "bound",
            query: "record\(index) after:2026-08-01",
            lexicalQuery: "record\(index)",
            lowerBound: "2026-08-01T00:00:00.000Z",
            tokens: [
                Token(kind: "time", label: "After 2026-08-01", canonicalValue: "after:2026-08-01")
            ]
        )
    } else {
        add(
            category: "bound",
            query: "record\(index) before:2026-09-01",
            lexicalQuery: "record\(index)",
            upperBound: "2026-09-01T00:00:00.000Z",
            tokens: [
                Token(kind: "time", label: "Before 2026-09-01", canonicalValue: "before:2026-09-01")
            ]
        )
    }
}

let localeDates = [
    ("en_US", "8/27/2026"),
    ("fr_FR", "27/08/2026"),
    ("de_DE", "27.08.2026"),
    ("es_ES", "27/8/2026"),
]
for index in 0..<10 {
    let item = localeDates[index % localeDates.count]
    add(
        category: "date",
        locale: item.0,
        query: "document\(index) \(item.1)",
        lexicalQuery: "document\(index)",
        lowerBound: "2026-08-27T00:00:00.000Z",
        upperBound: "2026-08-28T00:00:00.000Z",
        tokens: [Token(kind: "time", label: item.1, canonicalValue: "date:2026-08-27")]
    )
}

let ambiguous = [
    "today's notes", "app:Unknown item", "site:github issue", "app: missing",
    "before launch", "after lunch", "\"unfinished phrase", "site:user@example.com secret",
    "after:2026-02-30 invalid", "site:https://github.com path",
]
for query in ambiguous {
    add(category: "ambiguous", query: query, lexicalQuery: query)
}

precondition(cases.count == 100)
let fixture = Fixture(
    schemaVersion: 1,
    referenceDate: "2026-08-28T12:00:00.000Z",
    applications: applications,
    cases: cases
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(fixture) + Data([0x0A])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
