import Foundation
import GRDB

public enum SQLCipherSpikeError: Error, Equatable, Sendable {
    case invalidKeyLength
    case missingCipherVersion
    case unexpectedJournalMode(String)
}

public struct S5ConcurrentWorkloadResult: Codable, Equatable, Sendable {
    public let roleCount: Int
    public let successfulOperationCount: Int
    public let failedOperationCount: Int
    public let integrityCheckPassed: Bool
}

public final class SQLCipherSpikeDatabase: @unchecked Sendable {
    private let pool: DatabasePool

    public convenience init(path: URL, key: Data) throws {
        try self.init(path: path, encryptionKey: key)
    }

    public static func plaintextBaseline(path: URL) throws -> SQLCipherSpikeDatabase {
        try SQLCipherSpikeDatabase(path: path, encryptionKey: nil)
    }

    private init(path: URL, encryptionKey: Data?) throws {
        if let encryptionKey,
           encryptionKey.count != LM008StoreDefaults.keyByteCount
        {
            throw SQLCipherSpikeError.invalidKeyLength
        }

        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(
            TimeInterval(LM008StoreDefaults.busyTimeoutMilliseconds) / 1_000
        )
        configuration.maximumReaderCount = LM008StoreDefaults.maximumReaderCount
        configuration.prepareDatabase { database in
            if let encryptionKey {
                try database.usePassphrase(encryptionKey)
            }
            try database.execute(sql: "PRAGMA cipher_memory_security = ON")
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            try database.execute(sql: "PRAGMA secure_delete = ON")
            try database.execute(sql: "PRAGMA temp_store = FILE")
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }

        pool = try DatabasePool(path: path.path, configuration: configuration)
        try pool.write { database in
            let cipherVersion = try String.fetchOne(database, sql: "PRAGMA cipher_version")
            guard let cipherVersion, !cipherVersion.isEmpty else {
                throw SQLCipherSpikeError.missingCipherVersion
            }
            let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
            guard journalMode.uppercased() == LM008StoreDefaults.journalMode else {
                throw SQLCipherSpikeError.unexpectedJournalMode(journalMode)
            }
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS spike_records (
                    id INTEGER PRIMARY KEY,
                    text TEXT NOT NULL
                )
                """)
        }
    }

    public func insert(id: Int64, text: String) throws {
        try pool.write { database in
            try database.execute(
                sql: "INSERT OR REPLACE INTO spike_records(id, text) VALUES (?, ?)",
                arguments: [id, text]
            )
        }
    }

    public func text(id: Int64) throws -> String? {
        try pool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT text FROM spike_records WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func delete(id: Int64) throws {
        try pool.write { database in
            try database.execute(
                sql: "DELETE FROM spike_records WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func cipherVersion() throws -> String {
        try pool.read { database in
            guard let value = try String.fetchOne(database, sql: "PRAGMA cipher_version"),
                  !value.isEmpty
            else {
                throw SQLCipherSpikeError.missingCipherVersion
            }
            return value
        }
    }

    public func checkpoint() throws {
        _ = try pool.writeWithoutTransaction { database in
            try database.checkpoint(.truncate)
        }
    }

    public func vacuum() throws {
        try pool.vacuum()
    }

    public func runConcurrentRepresentativeWorkload(
        iterationsPerRole: Int
    ) async throws -> S5ConcurrentWorkloadResult {
        guard iterationsPerRole > 0 else {
            return S5ConcurrentWorkloadResult(
                roleCount: 5,
                successfulOperationCount: 0,
                failedOperationCount: 0,
                integrityCheckPassed: try integrityCheck()
            )
        }

        try await pool.write { database in
            for index in 0..<200 {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO spike_records(id, text) VALUES (?, ?)",
                    arguments: [index, "seed-\(index)"]
                )
            }
        }

        let successful = try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { [self] in
                for index in 0..<iterationsPerRole {
                    try insert(id: Int64(10_000 + index), text: "capture-\(index)")
                }
                return iterationsPerRole
            }
            group.addTask { [self] in
                for index in 0..<iterationsPerRole {
                    try updateText(id: Int64(index % 200), text: "enriched-\(index)")
                }
                return iterationsPerRole
            }
            group.addTask { [self] in
                for index in 0..<iterationsPerRole {
                    _ = try search(prefix: index.isMultiple(of: 2) ? "seed" : "enriched")
                }
                return iterationsPerRole
            }
            group.addTask { [self] in
                for index in 0..<iterationsPerRole {
                    try delete(id: Int64(50_000 + index))
                }
                return iterationsPerRole
            }
            group.addTask { [self] in
                for _ in 0..<iterationsPerRole {
                    _ = try helperProjection(limit: 25)
                }
                return iterationsPerRole
            }

            var completed = 0
            for try await count in group {
                completed += count
            }
            return completed
        }

        return S5ConcurrentWorkloadResult(
            roleCount: 5,
            successfulOperationCount: successful,
            failedOperationCount: 0,
            integrityCheckPassed: try integrityCheck()
        )
    }

    public func representativeOperation(seed: Int) throws -> Int {
        try pool.write { database in
            let identifier = 100_000 + seed
            try database.execute(
                sql: "INSERT OR REPLACE INTO spike_records(id, text) VALUES (?, ?)",
                arguments: [identifier, "representative-\(seed)"]
            )
            try database.execute(
                sql: "UPDATE spike_records SET text = text || '-updated' WHERE id = ?",
                arguments: [seed % 10_000]
            )
            try database.execute(
                sql: "DELETE FROM spike_records WHERE id = ?",
                arguments: [900_000 + seed]
            )
            var projectedBytes = 0
            for queryIndex in 0..<8 {
                let matchCount = try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM spike_records
                        WHERE text LIKE ? OR text LIKE '%warm%'
                        """,
                    arguments: ["%representative-\(seed - queryIndex)%"]
                ) ?? 0
                let projection = try String.fetchAll(
                    database,
                    sql: """
                        SELECT text FROM spike_records
                        ORDER BY id DESC
                        LIMIT 250 OFFSET ?
                        """,
                    arguments: [queryIndex * 25]
                )
                projectedBytes += matchCount
                projectedBytes += projection.reduce(0) { $0 + $1.utf8.count }
            }
            return projectedBytes
        }
    }

    public func allTexts() throws -> [String] {
        try pool.read { database in
            try String.fetchAll(database, sql: "SELECT text FROM spike_records ORDER BY id")
        }
    }

    public func seed(count: Int, prefix: String) throws {
        try pool.write { database in
            for index in 0..<count {
                try database.execute(
                    sql: "INSERT OR REPLACE INTO spike_records(id, text) VALUES (?, ?)",
                    arguments: [index, "\(prefix)-\(index)"]
                )
            }
        }
    }

    public func delete(ids: Range<Int>) throws {
        try pool.write { database in
            for identifier in ids {
                try database.execute(
                    sql: "DELETE FROM spike_records WHERE id = ?",
                    arguments: [identifier]
                )
            }
        }
    }

    private func updateText(id: Int64, text: String) throws {
        try pool.write { database in
            try database.execute(
                sql: "UPDATE spike_records SET text = ? WHERE id = ?",
                arguments: [text, id]
            )
        }
    }

    private func search(prefix: String) throws -> Int {
        try pool.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM spike_records WHERE text LIKE ?",
                arguments: ["\(prefix)%"]
            ) ?? 0
        }
    }

    private func helperProjection(limit: Int) throws -> [String] {
        try pool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT text FROM spike_records ORDER BY id DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    private func integrityCheck() throws -> Bool {
        try pool.read { database in
            try String.fetchOne(database, sql: "PRAGMA integrity_check") == "ok"
        }
    }
}
