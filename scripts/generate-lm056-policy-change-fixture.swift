#!/usr/bin/env swift
import Foundation

private struct Fixture: Encodable {
    let schemaVersion = 1
    let seed: UInt64 = 0x4C4D_3035_36
    let cases: [Case]
}

private struct Case: Encodable {
    let id: String
    let bundleIdentifier: String
    let ruleID: String
    let effectiveNanoseconds: UInt64
    let expectedPolicyGeneration: UInt64 = 2
    let expectedDenialReason = "userRule"
    let expectedGapReason = "excluded"
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: generate-lm056-policy-change-fixture.swift OUTPUT\n".utf8)
    )
    exit(64)
}

private let cases = (0..<100).map { index in
    let suffix = String(format: "%03d", index)
    return Case(
        id: "change-\(suffix)",
        bundleIdentifier: "com.example.lm056.private\(suffix)",
        ruleID: "exclude-change-\(suffix)",
        effectiveNanoseconds: 5_600_000_000 + UInt64(index * 100)
    )
}

private let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var data = try encoder.encode(Fixture(cases: cases))
data.append(0x0A)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
