import Foundation
import XCTest

@testable import MemoryAgentAccess

final class LocalMemoryMCPServerTests: XCTestCase {
    func testNewlineStdioLoopProcessesInspectorTranscriptWithoutListener() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appending(path: "input.jsonl")
        let outputURL = directory.appending(path: "output.jsonl")
        let transcript = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"inspector","version":"1"}}}
            {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}

            """
        try Data(transcript.utf8).write(to: inputURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        try await LocalMemoryMCPServer.run(
            input: input,
            output: output,
            backend: MCPFixture.backend()
        )
        try input.close()
        try output.close()

        let lines = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("protocolVersion"))
        XCTAssertTrue(lines[1].contains("search_memory"))
    }

    func testStandaloneLauncherRoutesOnlyToSignedApplicationMCP() throws {
        let route = try SignedApplicationMCPRoute.resolve(
            launcherURL: URL(
                fileURLWithPath:
                    "/Applications/Local Memory.app/Contents/Helpers/local-memory-mcp"
            ),
            isExecutable: {
                $0.path == "/Applications/Local Memory.app/Contents/MacOS/Local Memory"
            }
        )
        XCTAssertEqual(route.arguments, [route.executableURL.path, "--mcp"])
    }

    func testProtocolInspectorNegotiatesAndListsOnlyFourReadOnlyTools() async throws {
        let backend = MCPFixture.backend()
        let initialize = try await response(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"inspector","version":"1"}}}"#,
            backend: backend
        )
        XCTAssertEqual(initialize["jsonrpc"] as? String, "2.0")
        let initializeResult = try object(initialize["result"])
        XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-06-18")

        let list = try await response(
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{}}"#,
            backend: backend
        )
        let tools = try array(try object(list["result"])["tools"])
        XCTAssertEqual(
            Set(tools.compactMap { try? object($0)["name"] as? String }),
            ["memory_status", "search_memory", "get_timeline", "get_moment"]
        )
        for tool in tools {
            let annotations = try object(try object(tool)["annotations"])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
            XCTAssertEqual(annotations["openWorldHint"] as? Bool, false)
        }
        let encoded = String(
            data: try JSONSerialization.data(withJSONObject: list), encoding: .utf8)!
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("sql"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("delete"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("pause"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("export"))
    }

    func testTwoIndependentClientShapesReceiveSameBoundedProjection() async throws {
        let policyID = UUID(uuidString: "5c479df3-6590-4c86-b0cc-5c41fd8f98e1")!
        let codex = try await callTool(
            id: 2,
            name: "search_memory",
            arguments: [
                "query": "fixture",
                "policy": policyID.uuidString,
                "limit": 1,
            ]
        )
        let secondClient = try await callTool(
            id: "client-b",
            name: "search_memory",
            arguments: [
                "policy": policyID.uuidString,
                "limit": 1,
                "query": "fixture",
            ]
        )
        let firstResult = try object(codex["result"])
        let secondResult = try object(secondClient["result"])
        XCTAssertEqual(
            try canonical(firstResult["structuredContent"]),
            try canonical(secondResult["structuredContent"])
        )
        XCTAssertEqual(firstResult["isError"] as? Bool, false)
        XCTAssertEqual(secondResult["isError"] as? Bool, false)
    }

    func testMissingPolicyUnknownToolAndMutationMethodFailClosed() async throws {
        let missingPolicy = try await callTool(
            id: 3,
            name: "search_memory",
            arguments: ["query": "fixture"]
        )
        XCTAssertEqual(try object(missingPolicy["result"])["isError"] as? Bool, true)

        let unknown = try await callTool(id: 4, name: "run_sql", arguments: [:])
        XCTAssertEqual(try object(unknown["error"])["code"] as? Int, -32601)

        let mutation = try await response(
            #"{"jsonrpc":"2.0","id":5,"method":"memory/delete","params":{}}"#,
            backend: MCPFixture.backend()
        )
        XCTAssertEqual(try object(mutation["error"])["code"] as? Int, -32601)
    }

    func testImageToolIssuesOpaqueURIAndResourceReadReturnsBoundedBytes() async throws {
        let image = LocalMemoryMCPImageBackend(
            issue: { _, _ in
                MCPImageResourceIssue(
                    resourceID: "opaque_token_1",
                    expiresAt: Date(timeIntervalSince1970: 1_777_700_300)
                )
            },
            read: { resourceID in
                XCTAssertEqual(resourceID, "opaque_token_1")
                return BoundedImageResource(
                    data: Data([1, 2, 3, 4]),
                    width: 1,
                    height: 1
                )
            }
        )
        let frame = UUID(uuidString: "69000000-0000-4000-8000-000000000001")!
        let policy = UUID(uuidString: "69000000-0000-4000-8000-000000000002")!
        let issueRequest: [String: Any] = [
            "jsonrpc": "2.0", "id": 8, "method": "tools/call",
            "params": [
                "name": "get_moment_image",
                "arguments": ["id": frame.uuidString, "policy": policy.uuidString],
            ],
        ]
        let issued = try await response(
            String(
                decoding: JSONSerialization.data(withJSONObject: issueRequest),
                as: UTF8.self
            ),
            backend: MCPFixture.backend(),
            imageBackend: image
        )
        let issuedResult = try object(issued["result"])
        XCTAssertEqual(issuedResult["isError"] as? Bool, false)
        XCTAssertFalse(
            String(data: try canonical(issuedResult), encoding: .utf8)!.contains(frame.uuidString)
        )

        let resourceRequest =
            #"{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"memory-image://opaque_token_1"}}"#
        let resource = try await response(
            resourceRequest,
            backend: MCPFixture.backend(),
            imageBackend: image
        )
        let contents = try array(try object(resource["result"])["contents"])
        XCTAssertEqual(
            try object(contents[0])["blob"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
        XCTAssertEqual(try object(contents[0])["mimeType"] as? String, "image/heic")
    }

    func testDeletedImageResourceFailsWithoutTokenOrPathDisclosure() async throws {
        let image = LocalMemoryMCPImageBackend(
            issue: { _, _ in throw ImageResourceError.policyDenied },
            read: { _ in throw ImageResourceError.notFound }
        )
        let response = try await response(
            #"{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"memory-image://opaque_deleted_token"}}"#,
            backend: MCPFixture.backend(),
            imageBackend: image
        )
        let encoded = String(
            decoding: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
            as: UTF8.self
        )
        XCTAssertTrue(encoded.contains("not_found"))
        XCTAssertFalse(encoded.contains("opaque_deleted_token"))
        XCTAssertFalse(encoded.contains("/Users/"))
        XCTAssertFalse(encoded.contains("media/"))
    }

    private func callTool(
        id: Any,
        name: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        return try await response(
            String(decoding: data, as: UTF8.self), backend: MCPFixture.backend())
    }

    private func response(
        _ request: String,
        backend: LocalMemoryCLIBackend,
        imageBackend: LocalMemoryMCPImageBackend? = nil
    ) async throws -> [String: Any] {
        let processed = await LocalMemoryMCPServer.process(
            message: Data(request.utf8),
            backend: backend,
            imageBackend: imageBackend
        )
        let data = try XCTUnwrap(processed)
        XCTAssertEqual(data.last, 0x0A)
        return try object(JSONSerialization.jsonObject(with: data))
    }

    private func object(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func array(_ value: Any?) throws -> [Any] {
        try XCTUnwrap(value as? [Any])
    }

    private func canonical(_ value: Any?) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(value),
            options: [.sortedKeys]
        )
    }
}

private enum MCPFixture {
    static func backend() -> LocalMemoryCLIBackend {
        LocalMemoryCLIBackend(
            status: {
                CLIStatusProjection(
                    recordingState: "inactive",
                    archiveReadable: true,
                    policyCount: 1
                )
            },
            search: { _ in
                CLISearchProjection(
                    results: [
                        CLIResultProjection(
                            frameID: UUID(
                                uuidString: "31000000-0000-0000-0000-000000000001"
                            )!,
                            capturedAt: Date(timeIntervalSince1970: 1_777_700_000),
                            application: "Safari",
                            bundleID: "com.apple.Safari",
                            host: "example.com",
                            excerpt: "Synthetic fixture text",
                            evidenceSource: "accessibility"
                        )
                    ],
                    nextCursor: nil
                )
            },
            timeline: { _ in CLITimelineProjection(frames: [], gaps: []) },
            moment: { _ in throw LocalMemoryCLIError.notFound },
            imageResource: { _ in throw LocalMemoryCLIError.policyDenied }
        )
    }
}
