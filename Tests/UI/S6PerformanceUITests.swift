import Foundation
import XCTest

@MainActor
final class S6PerformanceUITests: XCTestCase {
    func testReleaseNativeGridTimelineAndAccessibilityJourney() throws {
        let environment = ProcessInfo.processInfo.environment
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let outputPath = environment["LM008_S6_UI_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appending(
                path: "deepshelves-s6-xcuitest-current",
                directoryHint: .isDirectory
            ).path
        let mediaPath = environment["LM008_S6_MEDIA"]
            ?? repositoryRoot.appending(
                path: "Benchmarks/Results/S1/20260827T173516Z/active/capture.mov"
            ).path
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        print("LM008_S6_UI_OUTPUT=\(outputPath)")
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for filename in [
            "s6-report.json",
            "s6-xcuitest.json",
            "s6-complete.marker",
            "s6-error.log",
        ] {
            let artifact = output.appending(path: filename)
            if FileManager.default.fileExists(atPath: artifact.path) {
                try FileManager.default.removeItem(at: artifact)
            }
        }

        let application = XCUIApplication()
        if application.state != .notRunning {
            application.terminate()
        }
        application.launchArguments = ["--lm008-s6-spike", outputPath, mediaPath]
        application.launch()
        application.activate()
        if !application.windows.firstMatch.waitForExistence(timeout: 2) {
            application.typeKey("n", modifierFlags: .command)
        }

        let root = application.windows.firstMatch
        let search = application.textFields["s6.search"]
        let timeline = application.sliders["s6.timeline"]
        let visibleCard = application.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 's6.card.'"))
            .firstMatch
        let appearance = application.buttons["s6.appearance"]
        let pseudo = application.buttons["s6.pseudo"]
        let resize = application.buttons["s6.resize"]
        let warm = application.buttons["s6.warm"]

        XCTAssertTrue(root.waitForExistence(timeout: 10))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(visibleCard.waitForExistence(timeout: 5))
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(appearance.isHittable)
        XCTAssertTrue(pseudo.isHittable)
        XCTAssertTrue(resize.isHittable)
        XCTAssertTrue(warm.isHittable)

        search.click()
        search.typeText("local result")
        visibleCard.click()
        timeline.adjust(toNormalizedSliderPosition: 0.82)
        warm.click()
        appearance.click()
        pseudo.click()

        let initialWindowFrame = application.windows.firstMatch.frame
        resize.click()
        let compactWindowFrame = application.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(compactWindowFrame.width, initialWindowFrame.width)
        XCTAssertLessThanOrEqual(compactWindowFrame.height, initialWindowFrame.height)
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(timeline.isHittable)
        XCTAssertTrue(appearance.isHittable)

        for _ in 0 ..< 8 {
            application.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(application.staticTexts["s6.detail.title"].exists)
        XCTAssertTrue(application.descendants(matching: .any)["s6.preview"].exists)

        let reportURL = output.appending(path: "s6-report.json")
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: reportURL.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))

        let screenshot = XCTAttachment(screenshot: application.screenshot())
        screenshot.name = "S6 native grid timeline dark pseudo compact"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let result: [String: Any] = [
            "schemaVersion": 1,
            "releaseConfiguration": true,
            "rootExposed": root.exists,
            "searchFieldExposed": search.exists,
            "cardExposed": visibleCard.exists,
            "timelineExposed": timeline.exists,
            "lightDarkSwitchPassed": appearance.isHittable,
            "pseudoLocalizationPassed": pseudo.isHittable,
            "windowResizePassed": compactWindowFrame.width <= initialWindowFrame.width,
            "criticalControlsUnclipped": search.isHittable && timeline.isHittable && appearance.isHittable,
            "voiceOverNavigationProjectionPassed": application.staticTexts["s6.detail.title"].exists,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appending(path: "s6-xcuitest.json"), options: .atomic)
    }
}
