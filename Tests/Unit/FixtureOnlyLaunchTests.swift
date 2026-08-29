import Foundation
import MemoryDesignSystem
import XCTest

final class FixtureOnlyLaunchTests: XCTestCase {
    func testFixtureOnlyLaunchPolicyUsesExplicitIsolatedStateDirectory() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let policy = try XCTUnwrap(
            MemoryFixtureLaunchPolicy(arguments: [
                "Local Memory",
                "--fixture-only",
                "--fixture-state-directory",
                stateDirectory.path,
            ])
        )

        XCTAssertEqual(policy.stateDirectory, stateDirectory)
        XCTAssertEqual(
            policy.stateURL(fileName: "navigation-state.json"),
            stateDirectory.appending(path: "navigation-state.json")
        )
    }

    func testFixtureOnlyLaunchPolicyFallsBackToProcessScopedTemporaryDirectory() throws {
        let policy = try XCTUnwrap(
            MemoryFixtureLaunchPolicy(
                arguments: ["Local Memory", "--fixture-only"],
                processIdentifier: 48
            )
        )

        XCTAssertTrue(policy.stateDirectory.path.hasSuffix("LocalMemoryFixture-48"))
        XCTAssertTrue(
            policy.stateDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNil(MemoryFixtureLaunchPolicy(arguments: ["Local Memory"]))
    }
}
