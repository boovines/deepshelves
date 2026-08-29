import Darwin
import Foundation
import MemoryAgentAccess

@main
enum LocalMemoryMCP {
    static func main() {
        do {
            let route = try SignedApplicationMCPRoute.resolve(
                launcherURL: URL(fileURLWithPath: CommandLine.arguments[0])
            )
            let process = Process()
            process.executableURL = route.executableURL
            process.arguments = Array(route.arguments.dropFirst())
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            Darwin.exit(process.terminationStatus)
        } catch {
            FileHandle.standardError.write(
                Data("local-memory-mcp: signed application unavailable\n".utf8)
            )
            Darwin.exit(LocalMemoryCLIExitCode.unavailable.rawValue)
        }
    }
}
