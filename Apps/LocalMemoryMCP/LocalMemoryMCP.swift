import Foundation
import MemoryContracts

@main
enum LocalMemoryMCP {
    static func main() throws {
        let payload = BootstrapStatus(
            component: "local-memory-mcp",
            schemaVersion: BootstrapContract.schemaVersion,
            state: "not-configured"
        )
        let data = try JSONEncoder().encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

