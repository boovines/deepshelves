import Foundation
import MemoryContracts

@main
enum LocalMemoryCLI {
    static func main() throws {
        let payload = BootstrapStatus(
            component: "local-memory",
            schemaVersion: BootstrapContract.schemaVersion,
            state: "bootstrap"
        )
        let data = try JSONEncoder().encode(payload)
        guard let output = String(data: data, encoding: .utf8) else {
            throw BootstrapError.encodingFailed
        }
        print(output)
    }
}

private enum BootstrapError: Error {
    case encodingFailed
}

