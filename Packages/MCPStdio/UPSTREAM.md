# Audited official MCP Swift SDK subset

This package contains protocol model source files copied from the official Model Context Protocol Swift SDK 0.12.1 at commit `a0ae212ebf6eab5f754c3129608bc5557637e605`.

Canonical source archive SHA-256: `497caabc0cdf669fe442421b4fff13bf5ce7aa132bc747e851c9fdc63f56c0c5`.

Included upstream areas are JSON-RPC messages, IDs, values, protocol versions, progress metadata, tool/resource models, and their data helpers. HTTP client/server, OAuth, EventSource, NetworkTransport, NIO conformance targets, client runtime, and the upstream generic server runtime are deliberately excluded. DeepShelves supplies a newline-delimited, Foundation `FileHandle` stdio loop with no socket API.

`OfficialSDK/Error.swift` has one local portability adaptation: the Swift System import and errno helper were removed because the narrow stdio loop uses blocking `FileHandle` I/O and does not require Swift System. `StdioTransport.swift` preserves the official newline-delimited framing but narrows its I/O implementation to injected Foundation file handles and a bounded async message handler. No protocol encoding or error code was changed.

The copied source remains under the upstream license in `LICENSE`.
