import XCTest

@testable import MemoryStore

final class ArchiveSearchFilterMetadataTests: XCTestCase {
    func testAutocompleteMetadataIncludesOnlyApprovedSearchableFrames() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        _ = try archive.insertSearchFrameFixtureForTesting(
            suffix: 401,
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            host: "example.com"
        )
        let excluded = try archive.insertSearchFrameFixtureForTesting(
            suffix: 402,
            bundleIdentifier: "com.secret.Manager",
            appName: "Secret Manager",
            host: "secret.example.com"
        )
        try archive.setSearchFrameVisibilityForTesting(
            frameID: excluded,
            visualState: "suppressed",
            mergedTextState: "suppressed"
        )

        let scope = try archive.localSearchScope()

        XCTAssertEqual(
            scope.applications,
            [
                ArchiveSearchApplication(
                    bundleIdentifier: "com.apple.Safari",
                    displayName: "Safari"
                )
            ]
        )
        XCTAssertEqual(scope.hosts, ["example.com"])
    }
}
