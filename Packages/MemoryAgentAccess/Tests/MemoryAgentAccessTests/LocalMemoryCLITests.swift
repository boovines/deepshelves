import Foundation
import MemoryContracts
import XCTest

@testable import MemoryAgentAccess

final class LocalMemoryCLITests: XCTestCase {
    func testGoldenStatusAndSearchPaginationJSONV1() async throws {
        let fixture = try CLIFixture()
        let backend = fixture.backend()

        let status = await LocalMemoryCLIExecutor.execute(
            arguments: ["status", "--json"],
            backend: backend
        )
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertEqual(status.standardError, Data())
        XCTAssertEqual(status.standardOutput, fixture.statusGolden)

        let search = await LocalMemoryCLIExecutor.execute(
            arguments: [
                "search", "fixture", "--policy", fixture.policy.id.uuidString,
                "--limit", "1", "--cursor", "fixture.cursor.v2", "--json",
            ],
            backend: backend
        )
        XCTAssertEqual(search.exitCode, 0)
        XCTAssertEqual(search.standardOutput, fixture.searchGolden)
        let request = await fixture.recorder.lastSearch()
        XCTAssertEqual(request?.query, "fixture")
        XCTAssertEqual(request?.limit, 1)
        XCTAssertEqual(request?.cursor, "fixture.cursor.v2")
    }

    func testEveryContentCommandRequiresPolicyAndParsesStableSurface() async throws {
        let fixture = try CLIFixture()
        let backend = fixture.backend()
        let commands = [
            ["search", "fixture", "--json"],
            ["timeline", "--from", fixture.from, "--to", fixture.to, "--json"],
            ["get-moment", fixture.frameID.uuidString, "--json"],
            ["image-resource", "opaque-1", "--json"],
        ]
        for command in commands {
            let result = await LocalMemoryCLIExecutor.execute(
                arguments: command,
                backend: backend
            )
            XCTAssertEqual(result.exitCode, LocalMemoryCLIExitCode.policyRequired.rawValue)
            XCTAssertEqual(try errorCode(result.standardError), "policy_required")
            XCTAssertTrue(result.standardOutput.isEmpty)
        }
    }

    func testPolicyDenialCancellationAndMalformedInputHaveStableErrors() async throws {
        let fixture = try CLIFixture()
        let denied = await LocalMemoryCLIExecutor.execute(
            arguments: [
                "get-moment", fixture.frameID.uuidString,
                "--policy", fixture.policy.id.uuidString,
            ],
            backend: fixture.backend(failure: .policyDenied)
        )
        XCTAssertEqual(denied.exitCode, LocalMemoryCLIExitCode.policyDenied.rawValue)
        XCTAssertEqual(try errorCode(denied.standardError), "policy_denied")

        let cancelled = await LocalMemoryCLIExecutor.execute(
            arguments: ["status"],
            backend: fixture.backend(failure: .cancelled)
        )
        XCTAssertEqual(cancelled.exitCode, LocalMemoryCLIExitCode.cancelled.rawValue)
        XCTAssertEqual(try errorCode(cancelled.standardError), "cancelled")

        for malformed in [
            ["unknown"],
            ["search", "--policy", fixture.policy.id.uuidString],
            [
                "timeline", "--from", "not-a-date", "--to", fixture.to,
                "--policy", fixture.policy.id.uuidString,
            ],
            ["get-moment", "not-a-uuid", "--policy", fixture.policy.id.uuidString],
            ["search", "fixture", "--policy", fixture.policy.id.uuidString, "--limit", "0"],
        ] {
            let result = await LocalMemoryCLIExecutor.execute(
                arguments: malformed,
                backend: fixture.backend()
            )
            XCTAssertEqual(result.exitCode, LocalMemoryCLIExitCode.usage.rawValue)
            XCTAssertEqual(try errorCode(result.standardError), "invalid_arguments")
        }
    }

    func testStandaloneLauncherRoutesOnlyToSignedApplicationCLI() throws {
        let launcher = URL(
            fileURLWithPath:
                "/Applications/Local Memory.app/Contents/Helpers/local-memory"
        )
        let route = try SignedApplicationCLIRoute.resolve(
            launcherURL: launcher,
            arguments: ["search", "fixture", "--policy", UUID().uuidString],
            isExecutable: {
                $0.path == "/Applications/Local Memory.app/Contents/MacOS/Local Memory"
            }
        )

        XCTAssertEqual(
            route.executableURL.path,
            "/Applications/Local Memory.app/Contents/MacOS/Local Memory"
        )
        XCTAssertEqual(route.arguments.prefix(2), [route.executableURL.path, "--cli"])
        XCTAssertEqual(route.arguments.dropFirst(2).prefix(2), ["search", "fixture"])
        XCTAssertFalse(route.arguments.contains("--mcp"))
    }

    func testStandaloneLauncherFailsClosedWhenSignedApplicationIsUnavailable() {
        XCTAssertThrowsError(
            try SignedApplicationCLIRoute.resolve(
                launcherURL: URL(fileURLWithPath: "/tmp/local-memory"),
                arguments: ["status"],
                standardApplicationsDirectories: [],
                isExecutable: { _ in false }
            )
        ) { error in
            XCTAssertEqual(error as? LocalMemoryCLIError, .unavailable)
        }
    }
}

private actor CLIRequestRecorder {
    private var search: CLISearchInput?

    func record(_ input: CLISearchInput) { search = input }
    func lastSearch() -> CLISearchInput? { search }
}

private struct CLIFixture {
    let policy: AccessPolicy
    let frameID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
    let from = "2026-05-02T05:33:20.000Z"
    let to = "2026-05-02T05:38:20.000Z"
    let recorder = CLIRequestRecorder()
    let statusGolden: Data
    let searchGolden: Data

    init(file: StaticString = #filePath) throws {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        policy = try ContractJSON.decode(
            AccessPolicy.self,
            from: Data(
                contentsOf: root.appending(path: "Fixtures/Contracts/v1/access-policy.json")
            )
        )
        statusGolden = try Data(
            contentsOf: root.appending(path: "Fixtures/LM067/status.json")
        )
        searchGolden = try Data(
            contentsOf: root.appending(path: "Fixtures/LM067/search-page.json")
        )
    }

    func backend(failure: LocalMemoryCLIError? = nil) -> LocalMemoryCLIBackend {
        LocalMemoryCLIBackend(
            status: {
                if let failure { throw failure }
                return CLIStatusProjection(
                    recordingState: "paused",
                    archiveReadable: true,
                    policyCount: 1
                )
            },
            search: { input in
                if let failure { throw failure }
                await recorder.record(input)
                return CLISearchProjection(
                    results: [
                        CLIResultProjection(
                            frameID: frameID,
                            capturedAt: try canonicalDate(from),
                            application: "Safari",
                            bundleID: "com.apple.Safari",
                            host: "example.com",
                            excerpt: "Synthetic fixture text",
                            evidenceSource: "accessibility"
                        )
                    ],
                    nextCursor: "fixture.cursor.v3"
                )
            },
            timeline: { _ in
                if let failure { throw failure }
                return CLITimelineProjection(frames: [], gaps: [])
            },
            moment: { _ in
                if let failure { throw failure }
                return CLIMomentProjection(
                    result: CLIResultProjection(
                        frameID: frameID,
                        capturedAt: try canonicalDate(from),
                        application: "Safari",
                        bundleID: "com.apple.Safari",
                        host: "example.com",
                        excerpt: "Synthetic fixture text",
                        evidenceSource: "accessibility"
                    )
                )
            },
            imageResource: { _ in
                if let failure { throw failure }
                return CLIImageResourceProjection(
                    resourceID: "opaque-1",
                    mediaType: "image/heic",
                    byteCount: 128
                )
            }
        )
    }
}

private func canonicalDate(_ value: String) throws -> Date {
    try Date(
        value,
        strategy: Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        )
    )
}

private func errorCode(_ data: Data) throws -> String {
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    return try XCTUnwrap(object["error"] as? String)
}
