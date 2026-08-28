import Foundation

private struct Fixture: Encodable {
    let schemaVersion = 1
    let frozenAt = "2026-08-28T21:12:00.000Z"
    let corpus: Corpus
    let frames: [Frame]
    let queries: [Query]
}

private struct Corpus: Encodable {
    let frameCount: Int
    let queryCount: Int
    let lexicalEvaluationQueryCount: Int
    let categoryCounts: [String: Int]
}

private struct Frame: Encodable {
    let id: String
    let capturedAt: String
    let bundleID: String
    let appName: String
    let windowTitle: String
    let host: String?
    let path: String?
    let accessibilityText: String
    let ocrText: String
}

private struct Query: Encodable {
    let id: String
    let category: String
    let includeInLexicalEvaluation: Bool
    let query: String
    let intervalStart: String?
    let intervalEnd: String?
    let bundleIDs: [String]
    let hosts: [String]
    let judgments: [Judgment]
    let forbiddenFrameIDs: [String]
}

private struct Judgment: Encodable {
    let assessor: String
    let relevance: [Relevance]
}

private struct Relevance: Encodable {
    let frameID: String
    let grade: Int
}

private struct Application {
    let bundleID: String
    let name: String
    let host: String?
}

private let applications = [
    Application(bundleID: "com.example.Editor", name: "Code Editor", host: nil),
    Application(bundleID: "com.google.Chrome", name: "Google Chrome", host: "docs.example.com"),
    Application(bundleID: "com.apple.Safari", name: "Safari", host: "research.example.org"),
    Application(bundleID: "com.apple.finder", name: "Finder", host: nil),
    Application(bundleID: "com.apple.mail", name: "Mail", host: nil),
    Application(bundleID: "com.apple.iCal", name: "Calendar", host: nil),
    Application(bundleID: "com.apple.Terminal", name: "Terminal", host: nil),
    Application(bundleID: "com.example.PDF", name: "PDF Viewer", host: nil),
    Application(bundleID: "com.example.Sheets", name: "Spreadsheet", host: "sheets.example.net"),
    Application(bundleID: "com.apple.systempreferences", name: "System Settings", host: nil),
]

private let formatter: ISO8601DateFormatter = {
    let value = ISO8601DateFormatter()
    value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return value
}()

private let baseDate = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!

private func frameID(_ index: Int) -> String {
    String(format: "38000000-0000-0000-0001-%012d", index)
}

private func date(_ index: Int) -> Date {
    baseDate.addingTimeInterval(Double(index) * (30 * 24 * 60 * 60 / 500))
}

private func makeFrames() -> [Frame] {
    (0..<500).map { index in
        let application = applications[index % applications.count]
        let topic = index % 15
        return Frame(
            id: frameID(index),
            capturedAt: formatter.string(from: date(index)),
            bundleID: application.bundleID,
            appName: application.name,
            windowTitle: "\(application.name) workspace \(index % 25)",
            host: application.host,
            path: application.host.map { _ in "/workspace/\(index % 20)" },
            accessibilityText:
                "identifier-\(String(format: "%03d", index)) topic-\(topic) project ledger \(index % 40)",
            ocrText: "visible panel \(index % 50) sequence \(index)"
        )
    }
}

private func judgments(_ relevance: [Relevance]) -> [Judgment] {
    ["synthetic-a", "synthetic-b", "synthetic-c"].map {
        Judgment(assessor: $0, relevance: relevance)
    }
}

private func makeQueries(frames: [Frame]) -> [Query] {
    var queries: [Query] = []
    for index in 0..<30 {
        let target = frames[index * 7]
        queries.append(
            Query(
                id: String(format: "exact-%02d", index),
                category: "exactTextTitleIdentifier",
                includeInLexicalEvaluation: true,
                query: "identifier-\(String(format: "%03d", index * 7))",
                intervalStart: nil,
                intervalEnd: nil,
                bundleIDs: [],
                hosts: [],
                judgments: judgments([Relevance(frameID: target.id, grade: 3)]),
                forbiddenFrameIDs: []
            )
        )
    }
    for index in 0..<10 {
        let application = applications[index]
        let matching =
            frames
            .filter { $0.bundleID == application.bundleID }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(5)
            .enumerated()
            .map { Relevance(frameID: $0.element.id, grade: max(1, 3 - $0.offset / 2)) }
        queries.append(
            Query(
                id: String(format: "app-%02d", index),
                category: "appSiteTimeFilter",
                includeInLexicalEvaluation: true,
                query: "",
                intervalStart: nil,
                intervalEnd: nil,
                bundleIDs: [application.bundleID],
                hosts: [],
                judgments: judgments(Array(matching)),
                forbiddenFrameIDs: []
            )
        )
    }
    let hostedApplications = applications.filter { $0.host != nil }
    for index in 0..<10 {
        let application = hostedApplications[index % hostedApplications.count]
        let lower = date(index * 10)
        let upper = lower.addingTimeInterval(10 * 24 * 60 * 60)
        let matching =
            frames
            .filter {
                let capturedAt = formatter.date(from: $0.capturedAt)!
                return $0.host == application.host
                    && capturedAt >= lower
                    && capturedAt < upper
            }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(5)
            .enumerated()
            .map { Relevance(frameID: $0.element.id, grade: max(1, 3 - $0.offset / 2)) }
        queries.append(
            Query(
                id: String(format: "site-time-%02d", index),
                category: "appSiteTimeFilter",
                includeInLexicalEvaluation: true,
                query: "",
                intervalStart: formatter.string(from: lower),
                intervalEnd: formatter.string(from: upper),
                bundleIDs: [],
                hosts: [application.host!],
                judgments: judgments(Array(matching)),
                forbiddenFrameIDs: []
            )
        )
    }
    for index in 0..<25 {
        let target = frames[250 + index]
        queries.append(
            Query(
                id: String(format: "visual-%02d", index),
                category: "visualSemantic",
                includeInLexicalEvaluation: false,
                query: "visual object \(index)",
                intervalStart: nil,
                intervalEnd: nil,
                bundleIDs: [],
                hosts: [],
                judgments: judgments([Relevance(frameID: target.id, grade: 3)]),
                forbiddenFrameIDs: []
            )
        )
    }
    for index in 0..<15 {
        let targetIndex = 300 + index
        let target = frames[targetIndex]
        let lower = date(targetIndex).addingTimeInterval(-60)
        let upper = date(targetIndex).addingTimeInterval(60)
        queries.append(
            Query(
                id: String(format: "combined-%02d", index),
                category: "combinedAmbiguous",
                includeInLexicalEvaluation: true,
                query: "topic-\(targetIndex % 15)",
                intervalStart: formatter.string(from: lower),
                intervalEnd: formatter.string(from: upper),
                bundleIDs: [target.bundleID],
                hosts: target.host.map { [$0] } ?? [],
                judgments: judgments([Relevance(frameID: target.id, grade: 3)]),
                forbiddenFrameIDs: []
            )
        )
    }
    for index in 0..<10 {
        queries.append(
            Query(
                id: String(format: "negative-%02d", index),
                category: "noResultAdversarial",
                includeInLexicalEvaluation: true,
                query: "absent-\(index) OR private*",
                intervalStart: nil,
                intervalEnd: nil,
                bundleIDs: [],
                hosts: [],
                judgments: judgments([]),
                forbiddenFrameIDs: [frames[490 + index].id]
            )
        )
    }
    return queries
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: LM038FixtureGenerator <output>\n".utf8))
    exit(64)
}
private let frames = makeFrames()
private let queries = makeQueries(frames: frames)
private let fixture = Fixture(
    corpus: Corpus(
        frameCount: frames.count,
        queryCount: queries.count,
        lexicalEvaluationQueryCount: queries.filter(\.includeInLexicalEvaluation).count,
        categoryCounts: Dictionary(grouping: queries, by: \.category).mapValues(\.count)
    ),
    frames: frames,
    queries: queries
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(fixture) + Data("\n".utf8)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
