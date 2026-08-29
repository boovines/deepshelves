import Foundation

public struct MemoryFixtureLaunchPolicy: Equatable, Sendable {
    public let stateDirectory: URL

    public init?(arguments: [String], processIdentifier: Int32? = nil) {
        guard arguments.contains("--fixture-only") else { return nil }
        if let index = arguments.firstIndex(of: "--fixture-state-directory"),
            arguments.indices.contains(index + 1)
        {
            stateDirectory = URL(
                fileURLWithPath: arguments[index + 1],
                isDirectory: true
            )
        } else {
            stateDirectory = FileManager.default.temporaryDirectory
                .appending(
                    path:
                        "LocalMemoryFixture-\(processIdentifier ?? ProcessInfo.processInfo.processIdentifier)",
                    directoryHint: .isDirectory
                )
        }
    }

    public func stateURL(fileName: String) -> URL {
        stateDirectory.appending(path: fileName)
    }
}
