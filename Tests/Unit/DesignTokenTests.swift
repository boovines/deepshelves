import AppKit
import MemoryDesignSystem
import XCTest

final class DesignTokenTests: XCTestCase {
    func testSemanticColorCatalogMatchesUXSpecification() {
        XCTAssertEqual(
            MemoryColorToken.catalog.map { "\($0.name)|\($0.semanticSource)|\($0.use)" },
            [
                "surface.window|windowBackgroundColor|Window/root",
                "surface.sidebar|underPageBackgroundColor|Sidebar",
                "surface.control|controlBackgroundColor|Cards, fields",
                "surface.selected|selectedContentBackgroundColor|Selection",
                "text.primary|labelColor|Main labels",
                "text.secondary|secondaryLabelColor|Metadata",
                "text.tertiary|tertiaryLabelColor|Hints",
                "border.default|separatorColor|Hairlines",
                "accent|systemIndigo|Focus, active selection, primary action",
                "status.recording|systemRed|Recording dot only",
                "status.paused|systemOrange|Paused state",
                "status.success|systemGreen|Verified completion",
            ]
        )
        XCTAssertTrue(MemoryColorToken.catalog.allSatisfy(\.usesSystemSemanticSource))
    }

    func testColorsResolveThroughDynamicAppKitSources() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let window = MemoryColorToken.surfaceWindow
        var lightColor: NSColor?
        var darkColor: NSColor?

        light.performAsCurrentDrawingAppearance {
            lightColor = window.nsColor.usingColorSpace(.deviceRGB)
        }
        dark.performAsCurrentDrawingAppearance {
            darkColor = window.nsColor.usingColorSpace(.deviceRGB)
        }

        XCTAssertNotEqual(try XCTUnwrap(lightColor), try XCTUnwrap(darkColor))
    }

    func testSpacingShapeControlHeightAndTypographyCatalogsMatchPlanEleven() {
        XCTAssertEqual(MemorySpacing.all, [4, 8, 12, 16, 24, 32])
        XCTAssertEqual(MemoryRadius.control, 6)
        XCTAssertEqual(MemoryRadius.card, 10)
        XCTAssertEqual(MemoryRadius.floatingPanel, 14)
        XCTAssertEqual(MemoryControlHeight.compact, 28)
        XCTAssertEqual(MemoryControlHeight.standard, 32)
        XCTAssertEqual(MemoryControlHeight.searchField, 36)
        XCTAssertEqual(MemoryHairline.width(displayScale: 1), 1)
        XCTAssertEqual(MemoryHairline.width(displayScale: 2), 0.5)
        XCTAssertEqual(MemoryHairline.width(displayScale: 0), 1)
        XCTAssertEqual(
            MemoryTypeToken.catalog.map(\.name),
            ["caption", "footnote", "callout", "body", "headline", "title2", "timecode"]
        )
        XCTAssertTrue(MemoryTypeToken.timecode.usesMonospacedDigits)
        XCTAssertFalse(MemoryTypeToken.body.usesMonospacedDigits)
    }

    func testMotionCatalogAndReduceMotionBehaviorMatchPlanEleven() {
        XCTAssertEqual(MemoryMotionToken.focusHover.duration, 0.100)
        XCTAssertEqual(MemoryMotionToken.selectionLayout.duration, 0.180)
        XCTAssertEqual(MemoryMotionToken.panelPresentation.duration, 0.260)

        let standard = MemoryMotionPolicy(reduceMotion: false)
        XCTAssertEqual(standard.presentation(for: .selectionLayout), .movement)
        XCTAssertEqual(standard.effectiveDuration(for: .selectionLayout), 0.180)

        let reduced = MemoryMotionPolicy(reduceMotion: true)
        XCTAssertEqual(reduced.presentation(for: .selectionLayout), .opacity)
        XCTAssertEqual(reduced.effectiveDuration(for: .selectionLayout), 0.180)
    }

    func testIncreasedContrastStrengthensSelectionAndHairlines() {
        let standard = MemoryContrastPolicy(increasedContrast: false)
        let increased = MemoryContrastPolicy(increasedContrast: true)

        XCTAssertEqual(standard.selectedSurfaceOpacity, 0.16)
        XCTAssertEqual(increased.selectedSurfaceOpacity, 0.28)
        XCTAssertEqual(standard.hairlinePhysicalPixels, 1)
        XCTAssertEqual(increased.hairlinePhysicalPixels, 2)
        XCTAssertEqual(standard.hairlineWidth(displayScale: 2), 0.5)
        XCTAssertEqual(increased.hairlineWidth(displayScale: 2), 1)
    }

    func testAccessibilityEnvironmentCombinesSystemPoliciesAndDisplayScale() {
        let standard = MemoryTokenEnvironment(
            reduceMotion: false,
            increasedContrast: false,
            displayScale: 2
        )
        XCTAssertEqual(standard.motion.presentation(for: .panelPresentation), .movement)
        XCTAssertEqual(standard.hairlineWidth, 0.5)

        let accessible = MemoryTokenEnvironment(
            reduceMotion: true,
            increasedContrast: true,
            displayScale: 2
        )
        XCTAssertEqual(accessible.motion.presentation(for: .panelPresentation), .opacity)
        XCTAssertEqual(accessible.hairlineWidth, 1)
    }

    func testCanonicalSnapshotContainsNoLiteralRGBOrLightOnlyColor() throws {
        let data = try MemoryDesignTokenSnapshot.canonicalJSON()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let committedData = try Data(
            contentsOf: repositoryRoot.appending(path: "Results/LM-011/tokens.json")
        )
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(MemoryDesignTokenSnapshot.self, from: data)

        XCTAssertEqual(committedData, data)
        XCTAssertEqual(decoded, .current)
        XCTAssertFalse(string.contains("#"))
        XCTAssertFalse(string.localizedCaseInsensitiveContains("rgb"))
        XCTAssertFalse(string.localizedCaseInsensitiveContains("lightOnly"))
        XCTAssertTrue(string.contains("underPageBackgroundColor"))
        XCTAssertTrue(string.contains("replace movement with opacity"))
    }
}
