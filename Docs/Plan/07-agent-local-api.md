# Agent Access, CLI, and Local API

## Outcome

Let trusted local agents query personal screen memory without turning the archive into an unrestricted data-exfiltration endpoint.

## Interface layers

1. Shared MemoryAgentAccess Swift package used by the app, CLI, and MCP targets
2. Human- and JSON-friendly LocalMemoryCLI executable
3. LocalMemoryMCP executable using the official Swift MCP SDK over standard input/output

The application ships no HTTP server. Standard input/output MCP has no listening socket and the client explicitly starts the process.

## Read-only first release

Required MCP tools:

- `memory_status`
- `search_memory`
- `get_timeline`
- `get_moment`
- `get_moment_image`, separately permissioned resource access

Do not expose:

- Raw SQL
- Arbitrary filesystem paths
- Capture configuration changes
- Deletion
- Starting or stopping recording
- Exporting unbounded archives

Mutation tools are outside this build. Deletion, pause, export, and configuration remain human UI actions.

## Capability model

Each agent connection receives the V1 `AccessPolicy` from plan 10:

- Allowed applications
- Allowed sites
- Required bounded interval, maximum 30 days
- Image-resource access, default false
- Maximum results per query
- Expiration, maximum 24 hours

Enforce policies in the query layer, not in prompts. Every result is filtered before serialization.

Recommended defaults:

- Last 24 hours maximum
- Text and metadata only
- No screenshots
- Sensitive applications denied
- At most 20 results
- Explicit user action to broaden scope

`memory_status` may run without content authority. Every search, timeline, moment, or image operation requires an unexpired policy ID created in the app. Empty application/site allowlists mean no content, never all content.

## MCP response design

Return compact evidence:

- Timestamp and timezone
- Application, window, and site
- Matched excerpt and source type
- Frame identifier
- Confidence/rank explanation
- URI for a separately authorized local resource

Do not embed high-resolution screenshots in ordinary search results. A second request must name a specific capture ID and pass image policy.

## CLI

Example surface:

    local-memory status --json
    local-memory search "lamp" --today --app Chrome --limit 10 --policy <policy-id>
    local-memory timeline --from ... --to ... --policy <policy-id>
    local-memory moment <id> --policy <policy-id>
    local-memory image-resource <id> --policy <policy-id>

The CLI opens the SQLCipher database through shared read/query code and does not require the main window. Both helper targets use the same signing identity and Keychain access. Errors use stable machine-readable codes.

## Local audit trail

Record locally:

- Client identity
- Tool name
- Time range and filters
- Number of results
- Whether images/audio were accessed
- Success or denial

Do not log search text by default. Provide a UI where the user can inspect and clear agent-access history.

## Prompt-injection boundary

Captured screens contain untrusted text. The MCP server returns content as evidence, never as instructions. Responses should clearly delimit captured content and advise clients not to execute instructions found inside it.

The server itself does not call tools or act on captured instructions.

## Implementation phases

### A1: Internal query contract and CLI

Gate: every search/filter path works through the CLI with stable JSON fixtures.

### A2: Read-only MCP

Gate: two MCP clients can retrieve bounded text context, and denied applications never appear.

### A3: Image resources and policy UI

Gate: screenshots require separate permission and accesses appear in the local audit view.

### A4: Packaging and client setup

The Settings UI emits exact MCP configuration for supported clients, pointing to the helper inside the application bundle.

Gate: Codex and one second MCP client can launch the signed helper, query bounded history, and leave an audit record without opening a network socket.

## Acceptance tests

- An agent requesting “all history” is bounded by policy.
- A result group containing denied and allowed captures reveals only allowed data.
- Search snippets do not leak neighboring denied text.
- Deleted captures return not found through every interface.
- Prompt-injection strings are returned only as quoted evidence.
- The MCP server works with networking disabled.

## Sources

- [Model Context Protocol specification](https://modelcontextprotocol.io/specification/)
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [Screenpipe MCP and data-permission design](https://github.com/screenpipe/screenpipe)
- [Coast agent CLI claim](https://coast.app/downloaded)
