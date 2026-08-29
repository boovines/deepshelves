import Foundation

/// The pinned official SDK's newline-delimited stdio framing, narrowed to blocking
/// Foundation file handles so no logging, Swift System, or remote transport target enters
/// the shipping graph.
public enum StdioTransport {
    public static func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        maximumMessageBytes: Int,
        oversizedResponse: @autoclosure () -> Data?,
        handler: @escaping @Sendable (Data) async -> Data?
    ) async throws {
        var pending = Data()
        while !Task.isCancelled,
            let chunk = try input.read(upToCount: 16_384),
            !chunk.isEmpty
        {
            pending.append(chunk)
            if pending.count > maximumMessageBytes,
                !pending.contains(0x0A)
            {
                if let response = oversizedResponse() { output.write(response) }
                pending.removeAll(keepingCapacity: true)
                continue
            }
            while let newline = pending.firstIndex(of: 0x0A) {
                let message = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard !message.isEmpty else { continue }
                if let response = await handler(message) { output.write(response) }
            }
        }
    }
}
