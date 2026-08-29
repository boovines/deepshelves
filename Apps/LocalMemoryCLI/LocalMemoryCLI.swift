import Darwin
import Foundation
import MemoryAgentAccess

@main
enum LocalMemoryCLI {
    static func main() {
        do {
            let route = try SignedApplicationCLIRoute.resolve(
                launcherURL: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: Array(CommandLine.arguments.dropFirst())
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
                Data("{\"error\":\"unavailable\",\"schemaVersion\":1}\n".utf8)
            )
            Darwin.exit(LocalMemoryCLIExitCode.unavailable.rawValue)
        }
    }
}
