import Foundation
import MemoryStore

enum ArchiveSecurityState: Equatable {
    case ready(cipherVersion: String)
    case unrecoverableKey
    case unavailable(errorCode: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
final class ArchiveSecurityViewModel: ObservableObject {
    @Published private(set) var state: ArchiveSecurityState
    @Published var typedResetConfirmation = ""
    @Published private(set) var isResetting = false
    private(set) var database: ArchiveDatabase?

    private let applicationSupportDirectory: URL?

    init(
        usesDeterministicStore: Bool,
        applicationSupportDirectory: URL? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        do {
            if usesDeterministicStore {
                let database = try ArchiveDatabase.deterministicTestStore()
                self.database = database
                state = .ready(cipherVersion: try database.cipherVersion())
            } else {
                let result = try Self.openProductionArchive(
                    applicationSupportDirectory: applicationSupportDirectory
                )
                database = result.database
                state = .ready(cipherVersion: result.cipherVersion)
            }
        } catch ArchiveKeyManagerError.keyMissingForExistingArchive,
            ArchiveDatabaseError.encryptedArchiveUnavailable
        {
            database = nil
            state = .unrecoverableKey
        } catch {
            database = nil
            state = .unavailable(errorCode: "LM-ARCHIVE-OPEN")
        }
    }

    var canReset: Bool {
        state == .unrecoverableKey
            && typedResetConfirmation == ArchiveResetCoordinator.requiredConfirmation
            && !isResetting
    }

    func resetUnrecoverableArchive() {
        guard canReset else { return }
        isResetting = true
        defer { isResetting = false }
        do {
            let paths = try ArchivePathProvider.prepare(
                applicationSupportDirectory: applicationSupportDirectory
            )
            _ = try ArchiveResetCoordinator().reset(
                paths: paths,
                typedConfirmation: typedResetConfirmation
            )
            let result = try Self.openProductionArchive(
                applicationSupportDirectory: applicationSupportDirectory
            )
            database = result.database
            state = .ready(cipherVersion: result.cipherVersion)
            typedResetConfirmation = ""
        } catch {
            database = nil
            state = .unavailable(errorCode: "LM-ARCHIVE-RESET")
        }
    }

    private static func openProductionArchive(
        applicationSupportDirectory: URL?
    ) throws -> (database: ArchiveDatabase, cipherVersion: String) {
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let key = try ArchiveKeyManager().resolve(paths: paths).key
        let database = try ArchiveDatabase(
            applicationSupportDirectory: applicationSupportDirectory,
            encryptionKey: key
        )
        return (database, try database.cipherVersion())
    }
}
