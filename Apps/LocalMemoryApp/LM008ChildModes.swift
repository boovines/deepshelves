import CryptoKit
import Darwin
import Foundation
import MemoryStore

enum LM008ChildModes {
    static func launchIfRequested(arguments: [String]) {
        if let index = arguments.firstIndex(of: "--lm008-s7-child"),
           arguments.indices.contains(index + 1)
        {
            S7OfflineSpikeRunner.writeChildProjection(role: arguments[index + 1])
        }
        if let index = arguments.firstIndex(of: "--lm008-keychain-probe"),
           arguments.indices.contains(index + 4)
        {
            keychainProbe(
                role: arguments[index + 1],
                outputPath: arguments[index + 2],
                account: arguments[index + 3],
                expectedHash: arguments[index + 4]
            )
        }
        if let index = arguments.firstIndex(of: "--lm008-crash-child"),
           arguments.indices.contains(index + 3),
           let boundary = Int(arguments[index + 2])
        {
            crashChild(
                rootPath: arguments[index + 1],
                boundary: boundary,
                account: arguments[index + 3]
            )
        }
    }

    private static func keychainProbe(
        role: String,
        outputPath: String,
        account: String,
        expectedHash: String
    ) -> Never {
        let output = URL(fileURLWithPath: outputPath)
        let report: LM008KeychainProbeResult
        do {
            let key = try SharedKeychainKeyStore.fetch(account: account)
            let hash = SHA256.hash(data: key)
                .map { String(format: "%02x", $0) }
                .joined()
            report = LM008KeychainProbeResult(
                role: role,
                status: 0,
                keyHashMatched: hash == expectedHash
            )
        } catch let SharedKeychainError.keychain(status) {
            report = LM008KeychainProbeResult(
                role: role,
                status: status,
                keyHashMatched: false
            )
        } catch {
            report = LM008KeychainProbeResult(
                role: role,
                status: -1,
                keyHashMatched: false
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: output, options: .atomic)
        Darwin.exit(report.status == 0 && report.keyHashMatched ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func crashChild(
        rootPath: String,
        boundary: Int,
        account: String
    ) -> Never {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        do {
            let key = try SharedKeychainKeyStore.fetch(account: account)
            let database = try SQLCipherSpikeDatabase(
                path: root.appending(path: "crash.sqlite3"),
                key: key
            )
            let partial = root.appending(path: "candidate.mov.partial")
            let candidate = root.appending(path: "candidate.mov")
            let old = root.appending(path: "old.mov")
            try Data("candidate-ready".utf8).write(to: partial, options: .atomic)
            if boundary == 0 { Darwin._exit(90) }
            try FileManager.default.moveItem(at: partial, to: candidate)
            if boundary == 1 { Darwin._exit(91) }
            try database.insert(id: -1, text: "candidate.mov")
            if boundary == 2 { Darwin._exit(92) }
            try FileManager.default.removeItem(at: old)
            Darwin._exit(93)
        } catch {
            Darwin._exit(120)
        }
    }
}
