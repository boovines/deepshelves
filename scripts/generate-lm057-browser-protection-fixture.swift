#!/usr/bin/env swift
import Foundation

private struct Fixture: Encodable {
    let schemaVersion = 1
    let seed: UInt64 = 0x4C4D_3035_37
    let cases: [Case]
}

private struct Case: Encodable {
    let id: String
    let browser: String
    let scenario: String
    let initialVersion: String
    let nextVersion: String?
    let expectedAllowed: Bool
    let expectedIssue: String?
}

private let browsers = ["safari", "chrome", "arcDia", "edge", "firefox"]
private let scenarios: [(String, Bool, String?)] = [
    ("healthy", true, nil),
    ("private", false, "privateContextExcluded"),
    ("urlUnavailable", false, "protectedURLContextUnavailable"),
    ("permissionRevoked", false, "accessibilityPermissionRevoked"),
    ("versionChanged", false, "browserVersionChanged"),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: generate-lm057-browser-protection-fixture.swift OUTPUT\n".utf8)
    )
    exit(64)
}

private var cases: [Case] = []
for browser in browsers {
    for (scenario, expectedAllowed, expectedIssue) in scenarios {
        for index in 0..<8 {
            cases.append(
                Case(
                    id: "\(browser)-\(scenario)-\(String(format: "%02d", index))",
                    browser: browser,
                    scenario: scenario,
                    initialVersion: "126.0.\(index)",
                    nextVersion: scenario == "versionChanged" ? "127.0.\(index)" : nil,
                    expectedAllowed: expectedAllowed,
                    expectedIssue: expectedIssue
                )
            )
        }
    }
}

private let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var data = try encoder.encode(Fixture(cases: cases))
data.append(0x0A)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
