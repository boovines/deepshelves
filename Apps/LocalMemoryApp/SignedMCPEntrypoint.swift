import Darwin
import Foundation
import MemoryAgentAccess
import MemoryStore

enum SignedMCPEntrypoint {
    static func launchIfRequested(arguments: [String], database: ArchiveDatabase?) {
        guard arguments.contains("--mcp") else { return }
        Task.detached {
            do {
                try await LocalMemoryMCPServer.run(
                    backend: SignedCLIEntrypoint.makeBackend(database: database),
                    imageBackend: SignedImageResourceComposition.makeBackend(
                        database: database
                    )
                )
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                Darwin.exit(LocalMemoryCLIExitCode.unavailable.rawValue)
            }
        }
    }
}
